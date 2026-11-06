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
import 'pendant/prefs.dart';
import 'pendant/protocol.dart';
import 'recorder/chunk_store.dart';
import 'ask/ask_index.dart';
import 'notes/cloud.dart';
import 'notes/conversations.dart';
import 'notes/due.dart';
import 'notes/voices.dart';
import 'transcribe/heard.dart';

class AskAnswer {
  final String question;
  /// The answer (null when Apple Intelligence isn't available: then only the passages)
  final String? text;
  final List<(Passage, double)> hits;
  /// Passages the answer cites (numbers from 1, as in [hits])
  final List<int> used;
  final String? error;
  const AskAnswer(this.question, this.text, this.hits, this.used, {this.error});
}

/// The on-device speech engine (swappable in tests).
class LocalAsr {
  bool get supported => EarmarkAsr.supported;
  Future<AsrStatus> status() => EarmarkAsr.status();
  Future<void> prepare() => EarmarkAsr.prepare();
  Future<AsrResult> transcribe(String path, {String? prev}) => EarmarkAsr.transcribe(path, prev: prev);
  Future<void> deleteModels() => EarmarkAsr.deleteModels();
  Future<void> prepareLanguages() => EarmarkAsr.prepareLanguages();
  bool get speakersSupported => EarmarkSpeakers.supported;
  Future<Diarization> diarize(List<String> paths, List<double> offsets) => EarmarkSpeakers.diarize(paths, offsets);
  Future<String> notesAvailability() => EarmarkNotes.availability();
  Future<bool> remindersAccess() => EarmarkReminders.access();
  Future<List<String>> remindersSync(List<Map<String, Object?>> items) => EarmarkReminders.sync(items);
  Future<List<List<double>>> embed(List<String> texts) => EarmarkNotes.embed(texts);
  Future<(String, List<int>)> answer(String q, List<String> excerpts, {String today = ''}) =>
      EarmarkNotes.answer(q, excerpts, today: today);
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
  VoiceBook? voiceBook;
  AskIndex? askIndex;
  /// Send my tasks to Apple Reminders.
  bool remindersOn = false;
  String? remindersError;
  DateTime? _remindersAt;
  bool _indexing = false;
  /// Apple's on-device model: available | notEligible | notEnabled | notReady | unsupported | unknown
  String notesState = 'unknown';
  bool _writingNotes = false;
  final List<double> earmarks = []; // epoch seconds, kept with what was heard
  File? _earmarksFile;
  bool get notesOn => asrOn && (ai.cloud ? (aiKeys[ai.name] ?? '').isNotEmpty : notesState == 'available');

  /// Who writes notes and answers Ask: Apple's on-device model, or your own OpenAI / Anthropic key.
  AiProvider ai = AiProvider.apple;
  final Map<String, String> aiKeys = {}, aiModels = {};
  /// your own silence length for a new conversation (seconds); null = your Mac's
  int? gapOverride;
  double get gapSeconds => (gapOverride ?? (macSettings['session_gap_seconds'] as num?) ?? 90).toDouble();

  CloudModel? get cloud => ai.cloud && (aiKeys[ai.name] ?? '').isNotEmpty
      ? CloudModel(ai, aiKeys[ai.name]!, model: aiModels[ai.name])
      : null;

  Future<void> setAi(AiProvider p) async {
    ai = p;
    notifyListeners();
    try {
      await config.saveAiProvider(p.name);
    } catch (_) {}
    _retryFailedNotes();
  }

  /// Conversations whose notes failed (no model, a bad key) get another go.
  void _retryFailedNotes() {
    for (final v in convs?.all ?? const <Conversation>[]) {
      if (v.status == 'failed') {
        v.status = 'pending';
        v.attempts = 0;
        v.error = null;
      }
    }
    convs?.save();
  }

  Future<void> setAiKey(AiProvider p, String key, {String? model}) async {
    aiKeys[p.name] = key.trim();
    if (model != null) aiModels[p.name] = model.trim();
    notifyListeners();
    try {
      await config.saveAiKey(p.name, key.trim());
      if (model != null) await config.saveAiModel(p.name, model.trim());
    } catch (_) {}
    if (p == ai) _retryFailedNotes();
  }

  Future<void> setGap(int? seconds) async {
    gapOverride = seconds;
    notifyListeners();
    try {
      await config.saveGapSeconds(seconds);
    } catch (_) {}
  }

  int get keepDays => store?.keepDays ?? 30;
  Future<void> setKeepDays(int d) async {
    store?.keepDays = d;
    store?.pruneKept();
    notifyListeners();
    try {
      await config.saveKeepDays(d);
    } catch (_) {}
  }

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
  /// The pendant's light, microphone, button and vibration settings (kept in step with the Mac).
  PendantPrefs prefs = const PendantPrefs();
  bool _prefsDirty = false; // changed on this phone, not yet on the Mac
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
    onSingle: (at) => _gesture(prefs.tap, at),
    onDouble: () => _gesture(prefs.doubleTap, DateTime.now()),
    onHold: () => _gesture(prefs.hold, DateTime.now()),
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
    store = ChunkStore(Directory('${docs.path}/recordings'), keepDays: await config.keepDays());
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
    voiceBook = VoiceBook(File('${docs.path}/voices.json'));
    askIndex = AskIndex(Directory('${docs.path}/ask'));
    _earmarksFile = File('${docs.path}/heard/earmarks.json');
    try {
      earmarks.addAll([for (final x in jsonDecode(_earmarksFile!.readAsStringSync()) as List) (x as num).toDouble()]);
    } catch (_) {}
    transcribeHere = await config.transcribeHere();
    remindersOn = await config.reminders();
    ai = AiProvider.parse(await config.aiProvider());
    for (final p in AiProvider.values.where((p) => p.cloud)) {
      aiKeys[p.name] = await config.aiKey(p.name);
      aiModels[p.name] = await config.aiModel(p.name);
    }
    gapOverride = await config.gapSeconds();
    final (savedPrefs, prefsDirty) = await config.pendantPrefs();
    prefs = savedPrefs;
    _prefsDirty = prefsDirty;
    pairing = await config.pairing();
    if (pairing != null) api = Api(pairing!.server, pairing!.token);
    pendant.onPaired = (id) => config.savePendantId(id);
    pendant.catchUp = _catchUp;
    pendant.addListener(_onPendant);
    _frameSub = pendant.frames.listen(_onFrame);
    _btnSub = pendant.buttons.listen(button);
    ready = true;
    notifyListeners();
    if (pairing != null) await startHolding();
    _beat = Timer.periodic(const Duration(seconds: 30), (_) => heartbeat());
    _pump = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (asrOn && asr.ready && (asr.languages?.busy ?? false)) await _refreshAsr(); // Whisper downloading
      await transcribePending();
      await processConversations();
      await pumpUploads();
      await fillFromMac();
      await updateAskIndex();
      await syncReminders();
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
    final gap = gapSeconds;
    if (cs.sync(h, gap: gap, now: (now ?? DateTime.now()).millisecondsSinceEpoch / 1000)) {
      cs.save();
      notifyListeners();
    }
    if (_writingNotes || !pendant.foreground) return;
    // who spoke when, before the notes (so tasks get the right owner)
    final unheard = cs.all.reversed
        .where((c) => c.status == 'pending' && c.spk == null && !Conversations.awaitingMac(c, h))
        .firstOrNull;
    if (unheard != null && (!asrEngine.speakersSupported || audioFor(unheard).$1.isEmpty)) {
      unheard.spk = 'none'; // nothing to listen to: straight on to the notes
    } else if (unheard != null) {
      _writingNotes = true;
      try {
        await identifySpeakers(unheard);
      } finally {
        _writingNotes = false;
        cs.save();
        notifyListeners();
      }
      return;
    }
    if (!notesOn) return;
    final nowS = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
    // oldest first; a conversation with another language waits (up to 6 hours) for your Mac's translation
    final next = cs.all.reversed
        .where((c) => c.status == 'pending' && !(Conversations.awaitingMac(c, h) && nowS - c.end < 6 * 3600))
        .firstOrNull;
    if (next == null) return;
    _writingNotes = true;
    try {
      final when = next.startTime;
      final header = 'The recording started ${_weekday(when)} ${when.day}/${when.month}/${when.year} at '
          '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}.';
      final lines = Conversations.promptLines(next, h, earmarks);
      final model = cloud;
      final n = model != null ? await model.notes(lines, header: header) : await asrEngine.notes(lines, header: header);
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

  /// The conversation's audio files on this phone and where each starts (seconds from its start).
  (List<String>, List<double>) audioFor(Conversation v) {
    final h = heard, s = store;
    final paths = <String>[], offsets = <double>[];
    if (h == null || s == null) return (paths, offsets);
    for (final seq in v.seqs) {
      final ch = h.bySeq(seq);
      if (ch == null) continue;
      final f = s.fileFor(seq, (ch.start * 1e6).round());
      if (f == null) continue;
      paths.add(f.path);
      offsets.add(ch.start - v.start);
    }
    return (paths, offsets);
  }

  /// Find who spoke when in a conversation and put names to the voices this phone knows.
  Future<void> identifySpeakers(Conversation v) async {
    if (!asrEngine.speakersSupported) {
      v.spk = 'none';
      return;
    }
    final (paths, offsets) = audioFor(v);
    if (paths.isEmpty) {
      v.spk = 'none';
      return;
    }
    try {
      final d = await asrEngine.diarize(paths, offsets);
      v.turns = [for (final t in d.turns) [t.$1, t.$2, t.$3]];
      v.voices = {
        for (final e in d.speakers.entries)
          e.key: {'seconds': e.value.seconds, 'energy': e.value.energy, 'embedding': e.value.embedding},
      };
      _nameVoices(v);
      v.spk = v.turns.isEmpty ? 'none' : 'done';
    } catch (e) {
      v.spk = 'failed';
      v.error = 'Speakers: $e';
    }
  }

  /// Names for a conversation's voices: known voices by similarity; "Me?" for the wearer (the
  /// loudest voice) until your own voice is saved.
  void _nameVoices(Conversation v) {
    final book = voiceBook;
    if (book == null) return;
    final taken = <String, (String, double)>{}; // name → (speaker id, similarity)
    for (final e in v.voices.entries) {
      e.value.remove('guess');
      if ((e.value['name'] as String?)?.isNotEmpty ?? false) continue;
      final emb = [for (final x in (e.value['embedding'] as List? ?? [])) (x as num).toDouble()];
      final best = book.closest(emb);
      if (best == null) continue;
      e.value['sim'] = best.$2;
      if (best.$2 >= VoiceBook.auto) {
        final prev = taken[best.$1.name];
        if (prev == null || best.$2 > prev.$2) {
          if (prev != null) {
            v.voices[prev.$1]!['guess'] = v.voices[prev.$1]!.remove('name');
          }
          e.value['name'] = best.$1.name;
          taken[best.$1.name] = (e.key, best.$2);
        } else {
          e.value['guess'] = best.$1.name;
        }
      } else if (best.$2 >= VoiceBook.suggest) {
        e.value['guess'] = best.$1.name;
      }
    }
    final hasMe = v.voices.values.any((x) => x['name'] == 'Me');
    if (!hasMe && book.byName('Me') == null && v.voices.isNotEmpty) {
      final total = v.voices.values.fold<double>(0, (a, x) => a + ((x['seconds'] as num?)?.toDouble() ?? 0));
      final loud = v.voices.entries
          .where((e) => ((e.value['seconds'] as num?)?.toDouble() ?? 0) >= total * 0.1 && e.value['name'] == null)
          .fold<MapEntry<String, Map<String, dynamic>>?>(null, (b, e) =>
              b == null || ((e.value['energy'] as num?) ?? 0) > ((b.value['energy'] as num?) ?? 0) ? e : b);
      if (loud != null && loud.value['guess'] == null) loud.value['guess'] = 'Me';
    }
  }

  /// "This voice is [name]": names it here, learns the voice, names it in other conversations where
  /// it is now recognised, and rewrites this conversation's notes with the right names.
  void nameSpeaker(Conversation v, String id, String name) {
    final x = v.voices[id];
    if (x == null) return;
    name = name.trim();
    if (name.isEmpty) return;
    if (name.toLowerCase() == 'me') name = 'Me';
    for (final other in v.voices.entries) {
      if (other.key != id && other.value['name'] == name) other.value.remove('name'); // one voice per name
    }
    x['name'] = name;
    x.remove('guess');
    final emb = [for (final e in (x['embedding'] as List? ?? [])) (e as num).toDouble()];
    voiceBook?.learn(name, emb, (x['seconds'] as num?)?.toDouble() ?? 1);
    for (final c in convs?.all ?? const <Conversation>[]) {
      if (c.voices.isNotEmpty) _nameVoices(c);
    }
    if (v.status == 'ready' || v.status == 'failed') v.status = 'pending';
    convs?.save();
    notifyListeners();
    unawaited(processConversations());
  }

  // ---- Apple Reminders
  Future<void> setReminders(bool on) async {
    if (on && !await asrEngine.remindersAccess()) {
      remindersError = 'Allow Reminders for Earmark in Settings → Earmark.';
      remindersOn = false;
      notifyListeners();
      return;
    }
    remindersOn = on;
    remindersError = null;
    await config.saveReminders(on);
    notifyListeners();
    if (on) await syncReminders(force: true);
  }

  /// My tasks into the "Earmark" list in Reminders (with due dates), and ticks back from it.
  Future<void> syncReminders({bool force = false, DateTime? now}) async {
    final cs = convs;
    if (!remindersOn || cs == null || !pendant.foreground) return;
    final t = now ?? DateTime.now();
    if (!force && _remindersAt != null && t.difference(_remindersAt!) < const Duration(seconds: 60)) return;
    _remindersAt = t;
    final items = <Map<String, Object?>>[];
    final byId = <String, ConvTask>{};
    for (final v in cs.all) {
      for (final k in v.tasks) {
        if (!k.mine) continue;
        final due = k.due.isEmpty ? null : parseDue(k.due, v.startTime);
        byId[k.id] = k;
        items.add({
          'id': k.id,
          'title': k.text,
          'notes': 'From "${convTitleText(v)}" (${_stamp(v.start)})${k.due.isNotEmpty ? '\nSaid: ${k.due}' : ''}',
          if (due != null) 'due': due.at.millisecondsSinceEpoch / 1000,
          'timed': due?.timed ?? false,
          'done': k.done,
        });
      }
    }
    try {
      final done = await asrEngine.remindersSync(items);
      var changed = false;
      for (final id in done) {
        final k = byId[id];
        if (k != null && !k.done) {
          k.done = true;
          changed = true;
        }
      }
      remindersError = null;
      if (changed) {
        cs.save();
      }
      notifyListeners();
    } catch (e) {
      remindersError = '$e';
      notifyListeners();
    }
  }

  // ---- editing conversations
  void renameConversation(Conversation v, String title) {
    final t = title.trim();
    v.userTitle = t.isEmpty ? null : t;
    convs?.save();
    notifyListeners();
  }

  void toggleStar(Conversation v) {
    v.starred = !v.starred;
    convs?.save();
    notifyListeners();
  }

  /// Fix a transcript line: its words and/or who said it.
  void editLine(Conversation v, double at, {String? text, String? speaker}) {
    final k = Conversations.editKey(at);
    final e = v.edits[k] ?? {};
    if (text != null) e['text'] = text.trim();
    if (speaker != null) e['speaker'] = speaker;
    v.edits[k] = e;
    convs?.save();
    notifyListeners();
  }

  /// Write the notes again (e.g. after fixing the transcript).
  void rewriteNotes(Conversation v) => retryNotes(v);

  /// Delete a conversation from this phone: its transcript, notes, tasks and audio.
  void deleteConversation(Conversation v) {
    final h = heard, s = store;
    if (h != null && s != null) {
      for (final seq in v.seqs) {
        final ch = h.bySeq(seq);
        if (ch == null) continue;
        final f = s.fileFor(seq, (ch.start * 1e6).round());
        if (f != null && f.path.contains('/kept/')) f.deleteSync(); // unsent audio still goes to the Mac
      }
    }
    h?.remove(v.seqs.toSet());
    convs?.all.remove(v);
    convs?.save();
    notifyListeners();
    unawaited(updateAskIndex());
  }

  void forgetVoice(String name) {
    voiceBook?.forget(name);
    notifyListeners();
  }

  /// Keep Ask's index up to date (a few conversations at a time, while the app is on screen).
  Future<void> updateAskIndex({int limit = 3}) async {
    final ix = askIndex, cs = convs, h = heard;
    if (ix == null || cs == null || h == null || _indexing || !asrOn || !asrEngine.supported) return;
    if (!pendant.foreground) return;
    _indexing = true;
    try {
      if (await ix.update(cs.all, h, asrEngine.embed, limit: limit)) notifyListeners();
    } catch (_) {
    } finally {
      _indexing = false;
    }
  }

  int get askPending => (convs == null || heard == null || askIndex == null) ? 0 : askIndex!.pending(convs!.all, heard!);

  /// Ask a question about everything heard: the best passages, and an answer from Apple's
  /// on-device model citing them (when Apple Intelligence is available).
  Future<AskAnswer> ask(String question) async {
    final ix = askIndex, cs = convs;
    if (ix == null || cs == null) return AskAnswer(question, null, const [], const []);
    await updateAskIndex(limit: 50);
    var qv = const <double>[];
    try {
      qv = (await asrEngine.embed([question])).firstOrNull ?? const <double>[];
    } catch (_) {}
    var hits = ix.search(question, qv);
    // "today", "yesterday", "on Monday", "this week": the conversations of that time too
    final span = askSpan(question, DateTime.now());
    if (span != null) {
      final seen = {for (final (p, _) in hits) '${p.conv}@${p.at}'};
      final timed = [
        for (final p in ix.during(cs.all, span.$1.millisecondsSinceEpoch / 1000, span.$2.millisecondsSinceEpoch / 1000))
          if (seen.add('${p.conv}@${p.at}')) (p, 1.0),
      ];
      final inSpan = {for (final (p, _) in timed) p.conv};
      hits = [...timed, ...hits.where((h) => inSpan.contains(h.$1.conv))].take(10).toList();
      if (timed.isEmpty) hits = [];
    }
    if (hits.isEmpty) return AskAnswer(question, null, const [], const []);
    if (!notesOn) return AskAnswer(question, null, hits, const []);
    final excerpts = [
      for (final (p, _) in hits)
        () {
          final c = cs.byId(p.conv);
          final when = c == null ? '' : _stamp(c.start + p.at);
          final title = c == null ? '' : convTitleText(c);
          return '$when · $title\n${p.text}';
        }(),
    ];
    try {
      final now = DateTime.now();
      final model = cloud;
      final (text, used) = await (model != null ? model.answer : asrEngine.answer)(question, excerpts,
          today: '${_weekday(now)} ${now.day}/${now.month}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
      return AskAnswer(question, text, hits, used);
    } on NotesError catch (e) {
      return AskAnswer(question, null, hits, const [], error: e.message);
    }
  }

  static String _stamp(double epoch) {
    final t = DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round());
    return '${_weekday(t)} ${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// A conversation's title for Ask (its notes' title, else its first words).
  String convTitleText(Conversation c) {
    if ((c.title ?? '').isNotEmpty) return c.title!;
    final h = heard;
    if (h == null) return 'Conversation';
    final w = Conversations.lines(c, h).map((l) => l.text).join(' ').split(' ');
    return w.take(8).join(' ');
  }

  final Map<int, DateTime> _askedMac = {};

  /// Speech in other languages is transcribed and translated by your Mac: once a conversation has
  /// ended and its audio is on the Mac, fetch the Mac's English text for those parts.
  Future<void> fillFromMac({DateTime? now}) async {
    final a = api, h = heard, cs = convs;
    if (a == null || h == null || cs == null || link != Link.online) return;
    final t = now ?? DateTime.now();
    final unsent = {for (final c in store?.pending() ?? const <Chunk>[]) c.seq};
    for (final v in cs.all) {
      if (v.status == 'open' || !Conversations.awaitingMac(v, h)) continue;
      if (v.seqs.any(unsent.contains)) continue; // the Mac doesn't have all of it yet
      final asked = _askedMac[v.id];
      if (asked != null && t.difference(asked) < const Duration(seconds: 60)) continue;
      _askedMac[v.id] = t;
      try {
        final r = Map<String, dynamic>.from(await a.get('/api/app/text', {'start': '${v.start}', 'end': '${v.end}'}) as Map);
        if (r['ready'] != true) continue;
        final segs = [for (final g in (r['segments'] as List? ?? [])) Map<String, dynamic>.from(g as Map)];
        for (final seq in v.seqs) {
          final ch = h.bySeq(seq);
          if (ch == null || !ch.awaitingMac) continue;
          final mine = segs.where((g) => (g['start'] as num) >= ch.start - 0.5 && (g['start'] as num) < ch.end).toList();
          final words = <List<Object>>[];
          for (final g in mine) {
            final toks = '${g['text']}'.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
            final a0 = (g['start'] as num).toDouble() - ch.start, a1 = (g['end'] as num).toDouble() - ch.start;
            final step = toks.isEmpty ? 0.0 : ((a1 - a0) / toks.length).clamp(0.05, 5.0);
            for (var i = 0; i < toks.length; i++) {
              words.add([double.parse((a0 + i * step).toStringAsFixed(2)), double.parse((a0 + (i + 1) * step).toStringAsFixed(2)), toks[i]]);
            }
          }
          h.replace(ch.withMacText(mine.map((g) => '${g['text']}').join(' '), words));
        }
        cs.sync(h, gap: gapSeconds, now: t.millisecondsSinceEpoch / 1000);
        final after = cs.byId(v.id);
        if (after != null && !Conversations.awaitingMac(after, h)) {
          if (after.status == 'ready' || after.status == 'failed') after.status = 'pending'; // notes again, with the translation
          if (after.status == 'pending' && after.words < 3) after.status = 'empty';
        }
        cs.save();
        notifyListeners();
      } catch (_) {/* try again in a minute */}
    }
  }

  static String _weekday(DateTime t) => const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][t.weekday - 1];

  /// Tick a phone task done or not done.
  void setTaskDone(ConvTask t, bool done) {
    t.done = done;
    convs?.save();
    notifyListeners();
    unawaited(syncReminders(force: true));
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
    unawaited(_buzz(paused ? Buzz.paused : Buzz.recording));
    if (paused) {
      unawaited(pendant.setLed(0));
    } else {
      _applySettings();
    }
    _queueEvent(paused ? 'pause' : 'resume', DateTime.now());
  }

  void _earmark(DateTime at) {
    if (paused) {
      unawaited(_buzz(Buzz.paused)); // reminder: nothing is being recorded
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
    unawaited(_buzz(Buzz.earmark));
    _queueEvent('earmark', at);
  }

  void _gesture(ButtonAction a, DateTime at) {
    switch (a) {
      case ButtonAction.earmark:
        _earmark(at);
      case ButtonAction.pause:
        unawaited(togglePause());
      case ButtonAction.none:
        break;
    }
  }

  /// Flash and buzz the pendant so it can be found.
  Future<void> findPendant() => pendant.findMe(paused ? 0 : prefs.led);

  /// A press of the pendant's button (as it arrives over Bluetooth).
  void button(ButtonEvent e) => _taps.handle(e);

  /// Earmark from the app's own button (same as a single tap on the pendant).
  void earmarkNow() => _earmark(DateTime.now());

  Future<void> _buzz(List<Pulse> pattern) async {
    if (prefs.haptics) await pendant.buzz(pattern);
  }

  void _applySettings() {
    unawaited(pendant.setLed(paused ? 0 : prefs.led));
    if (prefs.micGain >= 0) unawaited(pendant.setMicGain(prefs.micGain));
  }

  /// Change the pendant's settings from this phone: applied to the pendant right away and sent
  /// to the Mac, so both behave the same.
  Future<void> setPrefs(PendantPrefs p) async {
    if (p == prefs) return;
    final ledChanged = p.led != prefs.led, micChanged = p.micGain != prefs.micGain;
    prefs = p;
    _prefsDirty = true;
    notifyListeners();
    if (pendant.connected) {
      if (ledChanged) unawaited(pendant.setLed(paused ? 0 : p.led));
      if (micChanged && p.micGain >= 0) unawaited(pendant.setMicGain(p.micGain));
    }
    try {
      await config.savePendantPrefs(p, dirty: true);
    } catch (_) {}
    await _pushPrefs();
  }

  /// Try a vibration on the pendant (ignores the vibration switch, so you can feel what it does).
  Future<void> testBuzz() => pendant.buzz(Buzz.earmark);

  Future<void> _pushPrefs() async {
    final a = api;
    if (a == null || !_prefsDirty) return;
    final sent = prefs;
    try {
      await a.pendantSettings(sent.toJson());
      if (prefs != sent) return; // changed again meanwhile: the next push sends it
      _prefsDirty = false;
      try {
        await config.savePendantPrefs(sent);
      } catch (_) {}
    } catch (_) {/* the Mac is away: sent with the next heartbeat */}
  }

  /// The Mac's copy of the settings wins unless this phone changed them and hasn't sent them yet.
  Future<void> _takeMacPrefs(Map<String, dynamic> m) async {
    if (_prefsDirty) {
      await _pushPrefs();
      return;
    }
    final p = PendantPrefs.fromJson(m, prefs);
    if (p == prefs) return;
    prefs = p;
    try {
      await config.savePendantPrefs(p);
    } catch (_) {}
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
      await _takeMacPrefs(macSettings);
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
        unawaited(_buzz(paused ? Buzz.paused : Buzz.recording));
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
