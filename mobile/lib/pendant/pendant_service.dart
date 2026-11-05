// Holds the Bluetooth connection to the pendant: finds it, connects, keeps reconnecting,
// streams Opus frames, reports battery and button presses, and plays vibrations.
import 'dart:async';
import 'dart:io';

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
  String? lastError;
  DateTime? connectedAt;

  final _frames = StreamController<Uint8List>.broadcast();
  final _buttons = StreamController<ButtonEvent>.broadcast();
  Stream<Uint8List> get frames => _frames.stream;
  Stream<ButtonEvent> get buttons => _buttons.stream;

  /// Called when a pendant is first found, so it can be remembered.
  void Function(String id)? onPaired;

  bool _wanted = false;
  StreamSubscription? _statusSub, _scanSub, _connSub, _audioSub, _buttonSub, _battSub;
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

  /// Forget the remembered pendant and look for one again.
  Future<void> forget() async {
    deviceId = null;
    if (_wanted) {
      _teardown();
      _go();
    }
  }

  void _go() {
    if (!_wanted) return;
    if (deviceId == null) {
      _scan();
    } else {
      _connect();
    }
  }

  void _scan() {
    _set(PendantState.searching);
    _scanSub?.cancel();
    final timeout = Timer(const Duration(seconds: 25), () {
      _scanSub?.cancel();
      _scanSub = null;
      if (_wanted && deviceId == null) _later(_scan);
    });
    _scanSub = ble.scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency, requireLocationServicesEnabled: false).listen((d) {
      if (d.name == deviceName || d.serviceUuids.contains(Uuid.parse(OmiUuids.audioService))) {
        timeout.cancel();
        _scanSub?.cancel();
        _scanSub = null;
        deviceId = d.id;
        onPaired?.call(d.id);
        _connect();
      }
    }, onError: (e) {
      timeout.cancel();
      lastError = '$e';
      _later(_scan);
    });
  }

  void _connect() {
    _set(PendantState.connecting);
    _connSub?.cancel();
    // No timeout: on Android this uses autoConnect, on iOS a pending connection; both
    // complete by themselves whenever the pendant comes back in range, even in the background.
    _connSub = ble.connectToDevice(id: deviceId!).listen((u) async {
      switch (u.connectionState) {
        case DeviceConnectionState.connected:
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
    await syncClock();
    await _readBattery();
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
    _battTimer?.cancel();
    _battTimer = Timer.periodic(const Duration(minutes: 2), (_) => _readBattery());
    connectedAt = DateTime.now();
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
    _battTimer?.cancel();
    _audioSub = _buttonSub = _battSub = null;
  }

  void _teardown() {
    _retry?.cancel();
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

  Future<bool> syncClock() => _write(OmiUuids.timeService, OmiUuids.timeWrite, clockBytes(DateTime.now()));
  Future<bool> setLed(int pct) => _write(OmiUuids.settingsService, OmiUuids.dimRatio, [pct.clamp(0, 100)]);
  Future<bool> setMicGain(int level) => _write(OmiUuids.settingsService, OmiUuids.micGain, [level.clamp(0, 8)]);

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
