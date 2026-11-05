// The app's brain: pendant + recording on the phone + sync with the Mac.
//
//  pendant frames ──► ChunkStore (on the phone, crash-safe) ──► uploader ──► Mac /api/app/audio
//  button taps   ──► pause / earmark (with vibrations) ──────► Mac /api/app/event
//  every 30 s    ──► heartbeat: "I have the pendant", battery, state ◄── Mac settings + pause
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'pendant/pendant_service.dart';
import 'pendant/protocol.dart';
import 'recorder/chunk_store.dart';

const appVersion = '0.1.0';

enum Link { unknown, online, offline, unpaired }

class EarmarkController extends ChangeNotifier {
  final ConfigStore config;
  final PendantService pendant;
  EarmarkController({ConfigStore? config, PendantService? pendant})
      : config = config ?? ConfigStore(),
        pendant = pendant ?? PendantService();

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

  /// Ask the Mac to step back. Only when this phone had the pendant moments ago, or the user
  /// asked: a phone without the pendant nearby (or an emulator) must not stop the Mac recording.
  bool get _wantsPendant {
    if (!holding || pendant.connected) return false;
    final now = DateTime.now();
    if (_lastHeld != null && now.difference(_lastHeld!) < const Duration(minutes: 2)) return true;
    return _takeoverAsked != null && now.difference(_takeoverAsked!) < const Duration(minutes: 5);
  }

  /// "Take it from the Mac": the Mac lets go and this phone connects.
  Future<void> takeFromMac() async {
    _takeoverAsked = DateTime.now();
    notifyListeners();
    await heartbeat();
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
    _pump = Timer.periodic(const Duration(seconds: 5), (_) => pumpUploads());
    unawaited(heartbeat());
  }

  @override
  void dispose() {
    _beat?.cancel();
    _pump?.cancel();
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
    if (pendant.connected) _lastHeld = DateTime.now();
    if (!pendant.connected) store?.close();
    notifyListeners();
    if (pendant.connected) {
      _applySettings();
      unawaited(heartbeat());
    }
  }

  void _onFrame(Uint8List f) {
    if (paused) return;
    store?.add(f);
  }

  Future<void> togglePause() async {
    paused = !paused;
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
      });
      link = Link.online;
      linkError = null;
      macSettings = Map<String, dynamic>.from(r['settings'] as Map? ?? {});
      macHasPendant = r['mac_has_pendant'] == true;
      if (pendant.connected) _lastHeld = DateTime.now();
      final last = r['last_seq'];
      if (last is int) store?.ensureSeqAbove(last);
      // the Mac's Pause button wins when nothing from the phone is waiting to be sent
      final macPaused = r['paused'] == true;
      if (macPaused != paused && !_events.any((e) => e['type'] == 'pause' || e['type'] == 'resume')) {
        paused = macPaused;
        await config.savePaused(paused);
        if (paused) store?.close();
        unawaited(pendant.buzz(paused ? Buzz.paused : Buzz.recording));
      }
      if (pendant.connected) _applySettings();
      notifyListeners();
      unawaited(_sendEvents());
      unawaited(pumpUploads());
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

  double get queuedSeconds => store?.pendingSeconds() ?? 0;
}
