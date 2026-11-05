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

  // ------------------------------------------------------------ lifecycle
  Future<void> init() async {
    final docs = await getApplicationSupportDirectory();
    store = ChunkStore(Directory('${docs.path}/recordings'));
    _eventsFile = File('${docs.path}/pending_events.json');
    if (_eventsFile!.existsSync()) {
      try {
        _events.addAll((jsonDecode(_eventsFile!.readAsStringSync()) as List).cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    paused = await config.paused();
    pairing = await config.pairing();
    if (pairing != null) api = Api(pairing!.server, pairing!.token);
    pendant.onPaired = (id) => config.savePendantId(id);
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
        'wants_pendant': holding && !pendant.connected,
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

  /// Send finished chunks to the Mac, oldest first; delete each only once the Mac has it.
  Future<void> pumpUploads() async {
    final a = api, s = store;
    if (a == null || s == null || _uploading) return;
    _uploading = true;
    try {
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
