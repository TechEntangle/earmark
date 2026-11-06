// Holds the Bluetooth connection to the pendant: finds it, connects, keeps reconnecting,
// streams Opus frames, reports battery and button presses, and plays vibrations.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import 'protocol.dart';

enum PendantState { idle, bluetoothOff, needsPermission, searching, connecting, connected }

class PendantService extends ChangeNotifier {
  FlutterReactiveBle? _ble;
  PendantService({FlutterReactiveBle? ble}) : _ble = ble; // ignore: prefer_initializing_formals
  FlutterReactiveBle get ble => _ble ??= FlutterReactiveBle(); // created on first use

  PendantState state = PendantState.idle;
  String? deviceId;
  int? battery;
  int? codec;
  String? firmware;
  String? model, manufacturer, hardware;
  /// on its charger (null: this firmware doesn't say)
  bool? charging;
  /// what the firmware says the pendant has
  List<String>? features;
  /// how far the pendant's clock was off when it connected (it is set right on every connect)
  Duration? clockWasOff;
  PendantHealth? health;
  /// the pendant's own memory, as of the last catch-up
  RingInfo? memory;
  String? lastError;
  DateTime? connectedAt;

  final _frames = StreamController<Uint8List>.broadcast();
  final _buttons = StreamController<ButtonEvent>.broadcast();
  Stream<Uint8List> get frames => _frames.stream;
  Stream<ButtonEvent> get buttons => _buttons.stream;

  /// Called when a pendant is first found, so it can be remembered.
  void Function(String id)? onPaired;

  /// Runs after connecting and before live audio starts: copy what the pendant recorded
  /// into its own memory while it was away (see [ringInfo], [ringRead], [ringAdvance]).
  Future<void> Function()? catchUp;
  bool catchingUp = false;
  double catchUpProgress = 0;

  bool _wanted = false;

  /// True while the app is on screen. Then a connection that hasn't completed within a few
  /// seconds falls back to scanning (finds the pendant the moment it is free); in the
  /// background a pending connection waits quietly instead.
  bool foreground = true;
  Timer? _stall;
  StreamSubscription? _statusSub, _scanSub, _connSub, _audioSub, _buttonSub, _battSub, _ringSub, _chargeSub;
  StreamController<List<int>>? _ringQ;
  Timer? _retry, _battTimer;
  late FrameAssembler _asm = FrameAssembler(_frames.add);
  int _attempt = 0;

  bool get connected => state == PendantState.connected;
  bool get wanted => _wanted;

  QualifiedCharacteristic _c(String service, String ch) => QualifiedCharacteristic(
      serviceId: Uuid.parse(service), characteristicId: Uuid.parse(ch), deviceId: deviceId!);

  /// Start holding the pendant: ask for Bluetooth access, find it (or use the remembered one),
  /// connect, and keep reconnecting until [stop] is called.
  Future<void> start({String? rememberedId}) async {
    _wanted = true;
    deviceId = rememberedId ?? deviceId;
    if (!await _permissions()) {
      _set(PendantState.needsPermission);
      return;
    }
    _statusSub ??= ble.statusStream.listen((s) {
      if (s == BleStatus.poweredOff) {
        _teardown();
        _set(PendantState.bluetoothOff);
      } else if (s == BleStatus.ready && _wanted && (state == PendantState.bluetoothOff || state == PendantState.idle)) {
        _go();
      } else if (s == BleStatus.unauthorized) {
        _set(PendantState.needsPermission);
      }
    });
    _go();
  }

  /// Let go of the pendant (so the Mac can take it, or the user turned Earmark off).
  Future<void> stop() async {
    _wanted = false;
    _teardown();
    _set(PendantState.idle);
  }

  /// Try right now, without waiting out the retry back-off (e.g. the Mac just let go).
  void reconnectNow() {
    if (!_wanted || connected) return;
    _teardown();
    _attempt = 0;
    foreground ? _scan() : _go();
  }

  /// Forget the remembered pendant and look for one again.
  Future<void> forget() async {
    deviceId = null;
    if (_wanted) {
      _teardown();
      _go();
    }
  }

  /// iOS only connects to a pendant this app has seen in a scan since it started
  /// ("peripheral is unknown"); a remembered id alone is not enough after a restart.
  bool _seen = false;

  void _go() {
    if (!_wanted) return;
    if (deviceId == null || (Platform.isIOS && !_seen)) {
      _scan();
    } else {
      _connect();
    }
  }

  void _scan() {
    _set(PendantState.searching);
    _scanSub?.cancel();
    final timeout = Timer(const Duration(seconds: 12), () {
      _scanSub?.cancel();
      _scanSub = null;
      if (!_wanted) return;
      // not advertising: someone else (the Mac) has it, or it is away. A remembered pendant
      // gets a pending connection, which completes by itself when it frees up.
      deviceId == null || (Platform.isIOS && !_seen) ? _later(_scan) : _connect();
    });
    _scanSub = ble.scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency, requireLocationServicesEnabled: false).listen((d) {
      if (d.name == deviceName || d.serviceUuids.contains(Uuid.parse(OmiUuids.audioService))) {
        timeout.cancel();
        _scanSub?.cancel();
        _scanSub = null;
        _seen = true;
        if (d.id != deviceId) {
          deviceId = d.id;
          onPaired?.call(d.id);
        }
        _connect(fromScan: true);
      }
    }, onError: (e) {
      timeout.cancel();
      lastError = '$e';
      _later(_scan);
    });
  }

  void _connect({bool fromScan = false}) {
    _set(PendantState.connecting);
    _connSub?.cancel();
    _stall?.cancel();
    // On screen, don't sit on a connection that isn't happening: look for the pendant instead.
    _stall = Timer(Duration(seconds: fromScan ? 20 : 10), () {
      if (_wanted && foreground && state == PendantState.connecting) {
        lastError = 'no answer from the pendant; looking for it';
        _teardown();
        _scan();
      }
    });
    // No timeout: on Android this uses autoConnect, on iOS a pending connection; both
    // complete by themselves whenever the pendant comes back in range, even in the background.
    _connSub = ble.connectToDevice(id: deviceId!).listen((u) async {
      switch (u.connectionState) {
        case DeviceConnectionState.connected:
          _stall?.cancel();
          _attempt = 0;
          try {
            await _setup();
          } catch (e) {
            lastError = 'setup: $e';
            _teardown();
            _later(_connect);
          }
        case DeviceConnectionState.disconnected:
          _onLost();
        default:
          break;
      }
    }, onError: (e) {
      lastError = '$e';
      _onLost();
    });
  }

  Future<void> _setup() async {
    if (Platform.isAndroid) {
      try {
        await ble.requestMtu(deviceId: deviceId!, mtu: 247);
        await ble.requestConnectionPriority(deviceId: deviceId!, priority: ConnectionPriority.balanced);
      } catch (_) {}
    }
    await ble.discoverAllServices(deviceId!);
    codec = (await ble.readCharacteristic(_c(OmiUuids.audioService, OmiUuids.codecType))).firstOrNull;
    try {
      firmware = String.fromCharCodes(await ble.readCharacteristic(_c(OmiUuids.deviceInfoService, OmiUuids.firmwareRev)))
          .replaceAll('\x00', '');
    } catch (_) {}
    Future<String?> str(String svc, String ch) async {
      try {
        return String.fromCharCodes(await ble.readCharacteristic(_c(svc, ch))).replaceAll('\x00', '').trim();
      } catch (_) {
        return null;
      }
    }
    model = await str(OmiUuids.deviceInfoService, OmiUuids.model);
    manufacturer = await str(OmiUuids.deviceInfoService, OmiUuids.manufacturer);
    hardware = await str(OmiUuids.deviceInfoService, OmiUuids.hardwareRev);
    try {
      final f = u32le(await ble.readCharacteristic(_c(OmiUuids.featuresService, OmiUuids.features)));
      if (f != null) features = decodeFeatures(f);
    } catch (_) {}
    try {
      final t = u32le(await ble.readCharacteristic(_c(OmiUuids.timeService, OmiUuids.timeRead)));
      if (t != null) clockWasOff = Duration(seconds: t - DateTime.now().millisecondsSinceEpoch ~/ 1000);
    } catch (_) {}
    try {
      health = PendantHealth.parse(await ble.readCharacteristic(_c(OmiUuids.diagnosticsService, OmiUuids.diagnostics)));
    } catch (_) {}
    try {
      final c = await ble.readCharacteristic(_c(OmiUuids.settingsService, OmiUuids.charging));
      if (c.isNotEmpty) charging = c.first == 1;
    } catch (_) {}
    await syncClock();
    await _readBattery();
    connectedAt = DateTime.now();
    _set(PendantState.connected);
    if (catchUp != null) {
      try {
        _ringQ = StreamController<List<int>>.broadcast();
        _ringSub = ble.subscribeToCharacteristic(_c(OmiUuids.ringService, OmiUuids.ringCtrl)).listen(_ringQ!.add, onError: (_) {});
        catchingUp = true;
        notifyListeners();
        await catchUp!();
      } catch (e) {
        lastError = 'catch-up: $e';
      } finally {
        catchingUp = false;
        await _ringSub?.cancel();
        _ringSub = null;
        await _ringQ?.close();
        _ringQ = null;
        notifyListeners();
      }
    }
    _asm = FrameAssembler(_frames.add);
    _audioSub = ble.subscribeToCharacteristic(_c(OmiUuids.audioService, OmiUuids.audioData)).listen(_asm.add,
        onError: (e) => lastError = 'audio: $e');
    _buttonSub = ble.subscribeToCharacteristic(_c(OmiUuids.buttonService, OmiUuids.button)).listen(
        (d) => _buttons.add(decodeButton(d)),
        onError: (_) {});
    try {
      _battSub = ble.subscribeToCharacteristic(_c(OmiUuids.batteryService, OmiUuids.batteryLevel)).listen((d) {
        if (d.isNotEmpty) {
          battery = d.first;
          notifyListeners();
        }
      }, onError: (_) {});
    } catch (_) {}
    try {
      _chargeSub = ble.subscribeToCharacteristic(_c(OmiUuids.settingsService, OmiUuids.charging)).listen((d) {
        if (d.isNotEmpty) {
          charging = d.first == 1;
          notifyListeners();
        }
      }, onError: (_) {});
    } catch (_) {}
    _battTimer?.cancel();
    _battTimer = Timer.periodic(const Duration(minutes: 2), (_) => _readBattery());
    lastError = null;
    _set(PendantState.connected);
  }

  Future<void> _readBattery() async {
    try {
      final b = await ble.readCharacteristic(_c(OmiUuids.batteryService, OmiUuids.batteryLevel));
      if (b.isNotEmpty) {
        battery = b.first;
        notifyListeners();
      }
    } catch (_) {}
  }

  void _onLost() {
    _asm.flush();
    _cancelStreams();
    connectedAt = null;
    if (_wanted) {
      _set(PendantState.connecting);
      _later(_connect);
    }
  }

  void _later(void Function() f) {
    _retry?.cancel();
    _attempt = (_attempt + 1).clamp(1, 6);
    _retry = Timer(Duration(seconds: [2, 3, 5, 10, 20, 30][_attempt - 1]), () {
      if (_wanted) f();
    });
  }

  void _cancelStreams() {
    _audioSub?.cancel();
    _buttonSub?.cancel();
    _battSub?.cancel();
    _chargeSub?.cancel();
    _chargeSub = null;
    _battTimer?.cancel();
    _audioSub = _buttonSub = _battSub = null;
  }

  void _teardown() {
    _retry?.cancel();
    _stall?.cancel();
    _scanSub?.cancel();
    _scanSub = null;
    _asm.flush();
    _cancelStreams();
    _connSub?.cancel(); // cancelling the connection stream disconnects
    _connSub = null;
    connectedAt = null;
  }

  // ---- commands
  Future<bool> _write(String service, String ch, List<int> v) async {
    if (!connected) return false;
    try {
      await ble.writeCharacteristicWithResponse(_c(service, ch), value: v);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- the pendant's own memory
  Future<List<int>> _ringReply(bool Function(List<int>) want, Duration timeout) =>
      _ringQ!.stream.firstWhere((m) {
        if (m.isNotEmpty && m[0] == Ring.nAck && m.length > 1 && m[1] != 0) {
          throw StateError(Ring.statusText[m[1]] ?? 'status ${m[1]}');
        }
        return want(m);
      }).timeout(timeout);

  Future<RingInfo> ringInfo() async {
    final f = _ringReply((m) => RingInfo.parse(m) != null, const Duration(seconds: 10));
    await ble.writeCharacteristicWithResponse(_c(OmiUuids.ringService, OmiUuids.ringCtrl), value: Ring.info());
    return memory = RingInfo.parse(await f)!;
  }

  /// Read up to [count] records starting at [start]. Returns the bytes and the next sequence.
  Future<(Uint8List, int)> ringRead(int start, int count) async {
    final buf = BytesBuilder(copy: false);
    final done = Completer<int>();
    Timer? stall;
    void arm() {
      stall?.cancel();
      stall = Timer(const Duration(seconds: 20), () {
        if (!done.isCompleted) done.completeError(StateError('transfer stalled after ${buf.length} bytes'));
      });
    }
    final sub = _ringQ!.stream.listen((m) {
      if (m.isEmpty) return;
      if (m[0] == Ring.nData) {
        buf.add(m.sublist(1));
        arm();
      } else if (m[0] == Ring.nDone) {
        final r = parseRingDone(m);
        if (r == null) return;
        if (r.$1 != 0) {
          done.completeError(StateError('read failed: ${Ring.statusText[r.$1] ?? 'status ${r.$1}'}'));
        } else {
          done.complete(r.$2);
        }
      } else if (m[0] == Ring.nAck && m.length > 1 && m[1] != 0 && !done.isCompleted) {
        done.completeError(StateError(Ring.statusText[m[1]] ?? 'status ${m[1]}'));
      }
    });
    try {
      arm();
      await ble.writeCharacteristicWithResponse(_c(OmiUuids.ringService, OmiUuids.ringCtrl), value: Ring.read(start, count));
      final next = await done.future;
      return (buf.takeBytes(), next);
    } finally {
      stall?.cancel();
      await sub.cancel();
    }
  }

  Future<void> ringAdvance(int seq) =>
      ble.writeCharacteristicWithResponse(_c(OmiUuids.ringService, OmiUuids.ringCtrl), value: Ring.advance(seq));

  Future<bool> syncClock() => _write(OmiUuids.timeService, OmiUuids.timeWrite, clockBytes(DateTime.now()));
  Future<bool> setLed(int pct) => _write(OmiUuids.settingsService, OmiUuids.dimRatio, [pct.clamp(0, 100)]);
  Future<bool> setMicGain(int level) => _write(OmiUuids.settingsService, OmiUuids.micGain, [level.clamp(0, 8)]);

  /// Help find the pendant: the light flashes and it vibrates for about ten seconds.
  /// [restoreLed] is the brightness to go back to.
  Future<void> findMe(int restoreLed) async {
    for (var i = 0; i < 8 && connected; i++) {
      await setLed(100);
      await _write(OmiUuids.hapticService, OmiUuids.haptic, [3]);
      await Future.delayed(const Duration(milliseconds: 650));
      await setLed(0);
      await Future.delayed(const Duration(milliseconds: 600));
    }
    await setLed(restoreLed);
  }

  Future<void> buzz(List<Pulse> pattern) async {
    for (final (code, pause) in pattern) {
      await _write(OmiUuids.hapticService, OmiUuids.haptic, [code]);
      await Future.delayed(Duration(milliseconds: Buzz.durationMs(code) + pause));
    }
  }

  Future<bool> _permissions() async {
    if (Platform.isAndroid) {
      final r = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.notification].request();
      return r[Permission.bluetoothScan]!.isGranted && r[Permission.bluetoothConnect]!.isGranted;
    }
    return true; // iOS asks by itself on first Bluetooth use
  }

  void _set(PendantState s) {
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardown();
    _statusSub?.cancel();
    _frames.close();
    _buttons.close();
    super.dispose();
  }
}
