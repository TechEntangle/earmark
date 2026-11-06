// The app's brain: pendant + recording on the phone + sync with the Mac.
//
//  pendant frames ──► ChunkStore (on the phone, crash-safe) ──► uploader ──► Mac /api/app/audio
//  button taps   ──► pause / earmark (with vibrations) ──────► Mac /api/app/event
//  every 30 s    ──► heartbeat: "I have the pendant", battery, state ◄── Mac settings + pause
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'pendant/pendant_service.dart';
import 'pendant/protocol.dart';
import 'recorder/chunk_store.dart';
import 'notes/conversations.dart';
import 'transcribe/heard.dart';

/// The on-device speech engine (swappable in tests).
class LocalAsr {
  bool get supported => EarmarkAsr.supported;
  Future<AsrStatus> status() => EarmarkAsr.status();
  Future<void> prepare() => EarmarkAsr.prepare();
  Future<AsrResult> transcribe(String path, {String? prev}) => EarmarkAsr.transcribe(path, prev: prev);
  Future<void> deleteModels() => EarmarkAsr.deleteModels();
  Future<void> prepareLanguages() => EarmarkAsr.prepareLanguages();
  Future<String> notesAvailability() => EarmarkNotes.availability();
  Future<Map<String, dynamic>> notes(List<String> lines, {String header = ''}) => EarmarkNotes.notes(lines, header: header);
}

const appVersion = '0.1.0';

enum Link { unknown, online, offline, unpaired }

class EarmarkController extends ChangeNotifier {
  final ConfigStore config;
  final PendantService pendant;
  final LocalAsr asrEngine;
  EarmarkController({ConfigStore? config, PendantService? pendant, LocalAsr? asr})
      : config = config ?? ConfigStore(),
        pendant = pendant ?? PendantService(),
        asrEngine = asr ?? LocalAsr();

  // ---- transcription on this phone (the primary transcript; the Mac is the backup)
  /// The user's choice (Settings): transcribe here.
  bool transcribeHere = true;
  AsrStatus asr = const AsrStatus('idle');
  Heard? heard;
  Timer? _asrPoll;
  bool _transcribing = false;
  String? asrError;

  bool get asrOn => transcribeHere && asrEngine.supported;

  // ---- conversations, notes and tasks made on this phone
  Conversations? convs;
  /// Apple's on-device model: available | notEligible | notEnabled | notReady | unsupported | unknown
  String notesState = 'unknown';
  bool _writingNotes = false;
  final List<double> earmarks = []; // epoch seconds, kept with what was heard
  File? _earmarksFile;
  bool get notesOn => asrOn && notesState == 'available';

  Pairing? pairing;
  Api? api;
  ChunkStore? store;
  bool paused = false;
  bool holding = true; // the phone keeps the pendant (off = let the Mac have it)
  Link link = Link.unknown;
  String? linkError;
  DateTime? lastUpload;
  DateTime? lastEarmark;
  Map<String, dynamic> macSettings = {};
  Map<String, dynamic>? macStatus;
  bool ready = false;
  bool macHasPendant = false;
  DateTime? _lastHeld; // when this phone last had the pendant connected
  DateTime? _takeoverAsked; // the user asked to take the pendant from the Mac
  Timer? _takeoverBeat;
  /// "Use this phone" was pressed and the pendant hasn't arrived yet.
  bool get takingOver => _takeoverBeat != null;
  /// The last take-over didn't reach the pendant (shown until the next attempt).
  bool takeoverFailed = false;
  DateTime? pausedSince; // when recording was paused (unknown after an app restart)
  DateTime? _statusAt; // when [macStatus] was fetched

  // ---- what the Mac reports (from /api/status), for when the Mac has the pendant
  bool get macPaused => macStatus?['paused'] == true;
  int? get macBattery {
    final p = macStatus?['pendant'];
    if (p is Map && p['battery'] is int) return p['battery'] as int;
    final b = macStatus?['battery'];
    return b is Map && b['pct'] is int ? b['pct'] as int : null;
  }

  /// The Mac's current stretch of recording, counted on from when it last told us.
  double get macOpenSeconds {
    final s = (macStatus?['open_seconds'] as num?)?.toDouble() ?? 0;
    if (s <= 0 || macPaused || _statusAt == null) return s;
    return s + DateTime.now().difference(_statusAt!).inMilliseconds / 1000;
  }

  int get openTasks => ((macStatus?['tasks'] as Map?)?['open'] as num?)?.toInt() ?? 0;

  /// Conversations the Mac hasn't finished turning into text yet.
  int get transcribing {
    final c = macStatus?['counts'];
    if (c is! Map) return 0;
    return c.entries.where((e) => e.key != 'done' && e.key != 'error').fold(0, (n, e) => n + ((e.value as num?)?.toInt() ?? 0));
  }

  /// The pendant's battery, whoever holds it.
  int? get battery => pendant.connected ? pendant.battery : (macHasPendant ? macBattery : pendant.battery);

  /// Stop "Use this iPhone" (the Mac keeps the pendant).
  void cancelTakeover() {
    _takeoverBeat?.cancel();
    _takeoverBeat = null;
    _takeoverAsked = null;
    takeoverFailed = false;
    notifyListeners();
    unawaited(heartbeat());
  }

  Future<void> refreshStatus() async {
    final a = api;
    if (a == null) return;
    try {
      macStatus = await a.status();
      _statusAt = DateTime.now();
      notifyListeners();
    } catch (_) {}
  }

  /// Ask the Mac to step back. Only when this phone had the pendant moments ago, or the user
  /// asked: a phone without the pendant nearby (or an emulator) must not stop the Mac recording.
  bool get _wantsPendant {
    if (!holding || pendant.connected) return false;
    final now = DateTime.now();
    if (_lastHeld != null && now.difference(_lastHeld!) < const Duration(minutes: 2)) return true;
    return _takeoverAsked != null && now.difference(_takeoverAsked!) < const Duration(minutes: 2);
  }

  /// "Use this phone": tell the Mac to let go (it checks every second), then go straight for
  /// the pendant instead of waiting out the retry back-off. Quick heartbeats until it arrives;
  /// after a minute, give up and say so (the Mac takes it back once our claim lapses).
  Future<void> takeFromMac() async {
    if (takingOver) return;
    _takeoverAsked = DateTime.now();
    takeoverFailed = false;
    if (!holding) await startHolding();
    var ticks = 0;
    _takeoverBeat = Timer.periodic(const Duration(seconds: 3), (t) {
      ticks++;
      if (pendant.connected || ticks >= 20) {
        t.cancel();
        _takeoverBeat = null;
        if (!pendant.connected) {
          takeoverFailed = true;
          _takeoverAsked = null;
        }
        notifyListeners();
        unawaited(heartbeat());
        return;
      }
      unawaited(heartbeat());
      if (!macHasPendant && pendant.state != PendantState.connected && ticks % 4 == 1) pendant.reconnectNow();
    });
    notifyListeners();
    await heartbeat();
    pendant.reconnectNow();
  }

  /// The app came to the screen or left it.
  void setForeground(bool on) {
    pendant.foreground = on;
    if (on && notesState != 'available') unawaited(_checkNotes());
    if (on && holding && !pendant.connected) {
      pendant.reconnectNow();
      unawaited(heartbeat());
    }
  }

  late final TapInterpreter _taps = TapInterpreter(
    onSingle: _earmark,
    onDouble: togglePause,
    schedule: (d, f) => Timer(d, f),
    cancel: (t) => (t as Timer?)?.cancel(),
  );
  final List<Map<String, dynamic>> _events = []; // earmarks / pauses waiting for the Mac
  StreamSubscription? _frameSub, _btnSub;
  Timer? _beat, _pump;
  bool _uploading = false;
  File? _eventsFile;
  Directory? _ringDir;

  // ------------------------------------------------------------ lifecycle
  Future<void> init() async {
    final docs = await getApplicationSupportDirectory();
    store = ChunkStore(Directory('${docs.path}/recordings'));
    _eventsFile = File('${docs.path}/pending_events.json');
    _ringDir = Directory('${docs.path}/from_pendant_memory')..createSync(recursive: true);
    if (_eventsFile!.existsSync()) {
      try {
        _events.addAll((jsonDecode(_eventsFile!.readAsStringSync()) as List).cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    paused = await config.paused();
    _lastHeld = await config.lastHeld();
    heard = Heard(Directory('${docs.path}/heard'));
    convs = Conversations(File('${docs.path}/conversations.json'));
    _earmarksFile = File('${docs.path}/heard/earmarks.json');
    try {
      earmarks.addAll([for (final x in jsonDecode(_earmarksFile!.readAsStringSync()) as List) (x as num).toDouble()]);
    } catch (_) {}
    transcribeHere = await config.transcribeHere();
    pairing = await config.pairing();
    if (pairing != null) api = Api(pairing!.server, pairing!.token);
    pendant.onPaired = (id) => config.savePendantId(id);
    pendant.catchUp = _catchUp;
    pendant.addListener(_onPendant);
    _frameSub = pendant.frames.listen(_onFrame);
    _btnSub = pendant.buttons.listen(_taps.handle);
    ready = true;
    notifyListeners();
    if (pairing != null) await startHolding();
    _beat = Timer.periodic(const Duration(seconds: 30), (_) => heartbeat());
    _pump = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (asrOn && asr.ready && (asr.languages?.busy ?? false)) await _refreshAsr(); // Whisper downloading
      await transcribePending();
      await processConversations();
      await pumpUploads();
    });
    unawaited(_checkNotes());
    unawaited(heartbeat());
    if (asrOn) unawaited(prepareAsr());
  }

  // ------------------------------------------------------------ on-device transcription
  /// Turn transcription on this phone on or off (Settings).
  Future<void> setTranscribeHere(bool on) async {
    transcribeHere = on;
    await config.saveTranscribeHere(on);
    notifyListeners();
    if (asrOn) unawaited(prepareAsr());
  }

  /// Get the speech model ready: downloaded once (~480 MB), then loaded on each start.
  Future<void> prepareAsr() async {
    if (!asrOn || asr.ready || asr.busy) return;
    asrError = null;
    asr = AsrStatus('downloading', onDisk: asr.onDisk);
    notifyListeners();
    _asrPoll?.cancel();
    _asrPoll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshAsr());
    try {
      await asrEngine.prepare();
    } catch (e) {
      asrError = e is PlatformException ? (e.message ?? '$e') : '$e';
    } finally {
      _asrPoll?.cancel();
      _asrPoll = null;
      await _refreshAsr();
    }
  }

  /// Try Whisper (Hindi, Marathi, Urdu and the rest) again after it failed.
  Future<void> retryLanguages() async {
    asr = AsrStatus(asr.state, progress: asr.progress, onDisk: asr.onDisk, error: asr.error,
        languages: const AsrStatus('downloading'));
    notifyListeners();
    try {
      await asrEngine.prepareLanguages();
    } catch (_) {}
    await _refreshAsr();
  }

  Future<void> _refreshAsr() async {
    try {
      asr = await asrEngine.status();
    } catch (_) {}
    notifyListeners();
  }

  /// Transcribe finished chunks that have no text yet, oldest first. Runs whether or not the Mac
  /// is reachable: this phone's transcript is the primary one.
  Future<void> transcribePending() async {
    final s = store, h = heard;
    if (!asrOn || !asr.ready || s == null || h == null || _transcribing) return;
    _transcribing = true;
    try {
      for (final c in s.pending()) {
        if (h.has(c.seq)) continue;
        final prev = _asrPrev(c);
        try {
          final r = await asrEngine.transcribe(c.file.path, prev: prev?.path);
          h.add(HeardChunk(c.seq, c.startSeconds, r.seconds, r.text, [for (final w in r.words) w.toJson()],
              lang: r.language, checked: r.checked));
          _keepAsPrev(c);
          notifyListeners();
        } catch (e) {
          // a chunk the engine can't read must not hold up the rest: record it as empty
          asrError = '$e';
          h.add(HeardChunk(c.seq, c.startSeconds, 0, '', const []));
        }
      }
    } finally {
      _transcribing = false;
    }
  }

  // The chunk just before (copied aside before it is uploaded and deleted), so a word cut at the
  // 30-second boundary is heard whole.
  File get _prevFile => File('${store!.dir.path}/asr_prev.bin');
  File get _prevMeta => File('${store!.dir.path}/asr_prev.meta');

  File? _asrPrev(Chunk c) {
    try {
      final m = _prevMeta.readAsStringSync().split(' ');
      final seq = int.parse(m[0]), start = int.parse(m[1]);
      if (seq == c.seq - 1 && c.startMicros - start < 32000000 && _prevFile.existsSync()) return _prevFile;
    } catch (_) {}
    return null;
  }

  void _keepAsPrev(Chunk c) {
    try {
      c.file.copySync(_prevFile.path);
      _prevMeta.writeAsStringSync('${c.seq} ${c.startMicros}');
    } catch (_) {}
  }

  Future<void> _checkNotes() async {
    try {
      notesState = await asrEngine.notesAvailability();
    } catch (_) {
      notesState = 'unsupported';
    }
    notifyListeners();
  }

  /// Group what was heard into conversations and write notes for the ones that have ended,
  /// one at a time, while the app is on screen (the on-device model is for the foreground).
  Future<void> processConversations({DateTime? now}) async {
    final cs = convs, h = heard;
    if (cs == null || h == null || !asrOn) return;
    final gap = (macSettings['session_gap_seconds'] as num?)?.toDouble() ?? 90;
    if (cs.sync(h, gap: gap, now: (now ?? DateTime.now()).millisecondsSinceEpoch / 1000)) {
      cs.save();
      notifyListeners();
    }
    if (!notesOn || _writingNotes || !pendant.foreground) return;
    final next = cs.all.reversed.where((c) => c.status == 'pending').firstOrNull; // oldest first
    if (next == null) return;
    _writingNotes = true;
    try {
      final when = next.startTime;
      final header = 'The recording started ${_weekday(when)} ${when.day}/${when.month}/${when.year} at '
          '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}.';
      final n = await asrEngine.notes(Conversations.promptLines(next, h, earmarks), header: header);
      Conversations.applyNotes(next, n);
    } on NotesError catch (e) {
      if (!e.retryLater) {
        next.attempts++;
        next.error = e.message;
        if (e.code == 'guardrail' || e.code == 'language' || next.attempts >= 2) next.status = 'failed';
      }
    } catch (e) {
      next.attempts++;
      next.error = '$e';
      if (next.attempts >= 2) next.status = 'failed';
    } finally {
      _writingNotes = false;
      cs.save();
      notifyListeners();
    }
  }

  static String _weekday(DateTime t) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][t.weekday - 1];

  /// Tick a phone task done or not done.
  void setTaskDone(ConvTask t, bool done) {
    t.done = done;
    convs?.save();
    notifyListeners();
  }

  /// Write a conversation's notes again (e.g. after it failed).
  void retryNotes(Conversation c) {
    c
      ..status = 'pending'
      ..attempts = 0
      ..error = null;
    convs?.save();
    notifyListeners();
    unawaited(processConversations());
  }

  /// Whether a chunk must wait for its transcript before being sent (and deleted).
  bool _awaitsText(Chunk c) {
    if (!asrOn || heard == null || heard!.has(c.seq)) return false;
    return asr.ready || (asr.busy && asr.onDisk); // ready, or only loading from disk
  }

  @override
  void dispose() {
    _beat?.cancel();
    _pump?.cancel();
    _takeoverBeat?.cancel();
    _asrPoll?.cancel();
    _frameSub?.cancel();
    _btnSub?.cancel();
    pendant.removeListener(_onPendant);
    super.dispose();
  }

  // ------------------------------------------------------------ pairing
  Future<void> pair(String address, String code, String deviceName) async {
    final base = Api.normalise(address);
    final token = await Api(base, null).pair(code.trim(), deviceName, Platform.isIOS ? 'iOS' : 'Android');
    pairing = Pairing(base, token);
    await config.savePairing(pairing!);
    api = Api(base, token);
    link = Link.online;
    linkError = null;
    notifyListeners();
    await heartbeat();
    await startHolding();
  }

  Future<void> unpair() async {
    await config.forget();
    pairing = null;
    api = null;
    link = Link.unpaired;
    notifyListeners();
  }

  // ------------------------------------------------------------ pendant
  Future<void> startHolding() async {
    holding = true;
    notifyListeners();
    await pendant.start(rememberedId: await config.pendantId());
  }

  /// Hand the pendant back to the Mac (for example when leaving the phone at home).
  Future<void> letMacHaveIt() async {
    holding = false;
    store?.close();
    await pendant.stop();
    notifyListeners();
    await heartbeat();
  }

  Future<void> forgetPendant() async {
    await config.savePendantId(null);
    await pendant.forget();
  }

  void _onPendant() {
    if (pendant.connected) _markHeld();
    if (!pendant.connected) store?.close();
    notifyListeners();
    if (pendant.connected) {
      _applySettings();
      unawaited(heartbeat());
    }
  }

  void _markHeld() {
    _lastHeld = DateTime.now();
    if (takeoverFailed) takeoverFailed = false;
    unawaited(config.saveLastHeld(_lastHeld!));
  }

  void _onFrame(Uint8List f) {
    if (paused) return;
    store?.add(f);
  }

  Future<void> togglePause() async {
    paused = !paused;
    pausedSince = paused ? DateTime.now() : null;
    await config.savePaused(paused);
    if (paused) store?.close();
    notifyListeners();
    unawaited(pendant.buzz(paused ? Buzz.paused : Buzz.recording));
    if (paused) {
      unawaited(pendant.setLed(0));
    } else {
      _applySettings();
    }
    _queueEvent(paused ? 'pause' : 'resume', DateTime.now());
  }

  void _earmark(DateTime at) {
    if (paused) {
      unawaited(pendant.buzz(Buzz.paused)); // reminder: nothing is being recorded
      return;
    }
    lastEarmark = at;
    earmarks.add(at.millisecondsSinceEpoch / 1000);
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch / 1000;
    earmarks.removeWhere((m) => m < cutoff);
    try {
      _earmarksFile?.writeAsStringSync(jsonEncode(earmarks));
    } catch (_) {}
    notifyListeners();
    unawaited(pendant.buzz(Buzz.earmark));
    _queueEvent('earmark', at);
  }

  /// Earmark from the app's own button (same as a single tap on the pendant).
  void earmarkNow() => _earmark(DateTime.now());

  void _applySettings() {
    final led = macSettings['led_brightness'];
    final mic = macSettings['mic_gain'];
    if (led is int) unawaited(pendant.setLed(paused ? 0 : led));
    if (mic is int && mic >= 0) unawaited(pendant.setMicGain(mic));
  }

  // ------------------------------------------------------------ Mac sync
  void _queueEvent(String type, DateTime at) {
    // a pause/resume replaces an unsent opposite one
    if (type != 'earmark') _events.removeWhere((e) => e['type'] == 'pause' || e['type'] == 'resume');
    _events.add({'type': type, 'at': at.millisecondsSinceEpoch});
    _saveEvents();
    unawaited(_sendEvents());
  }

  void _saveEvents() {
    try {
      _eventsFile?.writeAsStringSync(jsonEncode(_events));
    } catch (_) {}
  }

  Future<void> _sendEvents() async {
    final a = api;
    if (a == null) return;
    while (_events.isNotEmpty) {
      final e = _events.first;
      try {
        await a.event(e['type'] as String, at: DateTime.fromMillisecondsSinceEpoch(e['at'] as int));
        _events.removeAt(0);
        _saveEvents();
      } catch (err) {
        _onApiError(err);
        return;
      }
    }
  }

  Future<void> heartbeat() async {
    final a = api;
    if (a == null) {
      link = Link.unpaired;
      notifyListeners();
      return;
    }
    try {
      final r = await a.heartbeat({
        'holds_pendant': holding && pendant.connected,
        'wants_pendant': _wantsPendant,
        'pendant_connected': pendant.connected,
        'battery': pendant.battery,
        'state': paused ? 'paused' : switch (pendant.state) {
          PendantState.connected => 'recording',
          PendantState.connecting => 'connecting',
          PendantState.searching => 'searching',
          _ => 'idle',
        },
        'session_seconds': store?.openSeconds ?? 0,
        'queued_seconds': store?.pendingSeconds() ?? 0,
        'app_version': appVersion,
        'pendant_error': pendant.connected || !_wantsPendant ? null : pendant.lastError,
      });
      link = Link.online;
      linkError = null;
      macSettings = Map<String, dynamic>.from(r['settings'] as Map? ?? {});
      macHasPendant = r['mac_has_pendant'] == true;
      if (pendant.connected) _markHeld();
      final last = r['last_seq'];
      if (last is int) store?.ensureSeqAbove(last);
      // the Mac's Pause button wins when nothing from the phone is waiting to be sent
      final macPaused = r['paused'] == true;
      if (macPaused != paused && !_events.any((e) => e['type'] == 'pause' || e['type'] == 'resume')) {
        paused = macPaused;
        pausedSince = paused ? DateTime.now() : null;
        await config.savePaused(paused);
        if (paused) store?.close();
        unawaited(pendant.buzz(paused ? Buzz.paused : Buzz.recording));
      }
      if (pendant.connected) _applySettings();
      notifyListeners();
      unawaited(_sendEvents());
      unawaited(pumpUploads());
      if (_statusAt == null || DateTime.now().difference(_statusAt!) > const Duration(seconds: 10)) unawaited(refreshStatus());
    } catch (e) {
      _onApiError(e);
    }
  }

  // ------------------------------------------------------------ the pendant's own memory
  int? _ringCursor() {
    final f = File('${_ringDir!.path}/cursor');
    return f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) : null;
  }

  /// Copy what the pendant recorded while away. Each batch is on disk before the pendant is
  /// told it may reuse that memory; the Mac turns it into conversations later.
  Future<void> _catchUp() async {
    final info = await pendant.ringInfo();
    var seq = info.readSeq;
    final end = info.writeSeq;
    final local = _ringCursor();
    if (local != null && local > seq && local <= end) seq = local;
    if (seq >= end) return;
    final total = end - seq;
    while (seq < end) {
      pendant.catchUpProgress = 1 - (end - seq) / total;
      notifyListeners();
      final (raw, next) = await pendant.ringRead(seq, (end - seq).clamp(1, 256));
      final keep = raw.length - raw.length % Ring.record;
      if (keep > 0) {
        final f = File('${_ringDir!.path}/${seq}_$next.ring');
        final h = f.openSync(mode: FileMode.writeOnly);
        h.writeFromSync(raw, 0, keep);
        h.flushSync();
        h.closeSync();
      }
      await pendant.ringAdvance(next);
      File('${_ringDir!.path}/cursor').writeAsStringSync('$next');
      if (next <= seq) break; // nothing more could be read
      seq = next;
    }
    unawaited(pumpUploads());
  }

  /// Send finished chunks to the Mac, oldest first; delete each only once the Mac has it.
  Future<void> pumpUploads() async {
    final a = api, s = store;
    if (a == null || s == null || _uploading) return;
    _uploading = true;
    try {
      for (final f in (_ringDir?.listSync() ?? []).whereType<File>().where((f) => f.path.endsWith('.ring')).toList()
        ..sort((x, y) => x.path.compareTo(y.path))) {
        final parts = f.uri.pathSegments.last.split('.').first.split('_');
        try {
          await a.uploadRing(f.readAsBytesSync(), start: int.parse(parts[0]), next: int.parse(parts[1]));
        } on ApiError catch (e) {
          if (e.status == 400 || e.status == 413) {
            f.renameSync('${f.path}.rejected');
            continue;
          }
          rethrow;
        }
        f.deleteSync();
        lastUpload = DateTime.now();
      }
      for (final c in s.pending()) {
        if (_awaitsText(c)) break; // keep order: send once this chunk has its text
        final text = heard?.bySeq(c.seq);
        if (text != null && text.seconds > 0 && !_textSent.contains(c.seq)) {
          try {
            await a.uploadTranscript(seq: c.seq, start: c.startSeconds, seconds: text.seconds, text: text.text, words: text.words,
                language: text.lang, checked: text.checked);
          } on ApiError catch (e) {
            if (e.status != 404) rethrow; // an older Mac without this endpoint transcribes by itself
          }
          _textSent.add(c.seq);
        }
        final body = await c.file.readAsBytes();
        if (body.isEmpty) {
          s.markUploaded(c);
          continue;
        }
        try {
          await a.uploadChunk(body, start: c.startSeconds, seq: c.seq, codec: pendant.codec ?? 21);
        } on ApiError catch (e) {
          // the Mac refused this chunk as invalid: set it aside so it can't block the queue
          if (e.status == 400 || e.status == 413 || e.status == 415) {
            c.file.renameSync('${c.file.path}.rejected');
            continue;
          }
          rethrow;
        }
        s.markUploaded(c);
        lastUpload = DateTime.now();
        link = Link.online;
        notifyListeners();
      }
    } catch (e) {
      _onApiError(e);
    } finally {
      _uploading = false;
    }
  }

  void _onApiError(Object e) {
    if (e is ApiError && e.unauthorized) {
      link = Link.unpaired;
      linkError = 'This phone was removed on the Mac. Pair it again.';
    } else {
      link = Link.offline;
      linkError = '$e';
    }
    notifyListeners();
  }

  final Set<int> _textSent = {};

  double get queuedSeconds => store?.pendingSeconds() ?? 0;
}
