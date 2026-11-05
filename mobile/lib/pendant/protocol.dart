// The Omi CV1 pendant's Bluetooth protocol (stock firmware 3.0.x), as Earmark uses it.
//
// Ported from Earmark's Mac service (mac/earmark/pendant.py), which runs against the real
// device. Reference: BasedHardware/omi (MIT), firmware/omi/src/lib/core/{transport,button}.c.
//
// Firmware behaviour that matters:
//   connected + subscribed to audio  -> streamed live (Opus, 20 ms frames, 16 kHz mono)
//   not connected                    -> written to the pendant's own memory (ring storage)
//   connected but NOT subscribed     -> dropped
import 'dart:typed_data';

class OmiUuids {
  static const audioService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const audioData = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const codecType = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const settingsService = '19b10010-e8f2-537e-4f6c-d104768a1214';
  static const dimRatio = '19b10011-e8f2-537e-4f6c-d104768a1214'; // LED 0-100
  static const micGain = '19b10012-e8f2-537e-4f6c-d104768a1214'; // 0-8
  static const timeService = '19b10030-e8f2-537e-4f6c-d104768a1214';
  static const timeWrite = '19b10031-e8f2-537e-4f6c-d104768a1214'; // u32 LE epoch
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const deviceInfoService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const firmwareRev = '00002a26-0000-1000-8000-00805f9b34fb';
  static const buttonService = '23ba7924-0000-1000-7450-346eac492e92';
  static const button = '23ba7925-0000-1000-7450-346eac492e92'; // int32 LE events
  static const hapticService = 'cab1ab95-2ea5-4f4d-bb56-874b72cfc984';
  static const haptic = 'cab1ab96-2ea5-4f4d-bb56-874b72cfc984'; // 1=100ms 2=300ms 3=500ms
}

const deviceName = 'Omi';
const opusCodecs = {20, 21};

/// Button events the firmware sends.
enum ButtonEvent { tap, doubleTap, longPress, down, up, unknown }

ButtonEvent decodeButton(List<int> data) {
  if (data.length < 4) return ButtonEvent.unknown;
  final v = ByteData.sublistView(Uint8List.fromList(data)).getInt32(0, Endian.little);
  return switch (v) {
    1 => ButtonEvent.tap,
    2 => ButtonEvent.doubleTap,
    3 => ButtonEvent.longPress,
    4 => ButtonEvent.down,
    5 => ButtonEvent.up,
    _ => ButtonEvent.unknown,
  };
}

/// A vibration: strength code (1 short, 2 medium, 3 long) and pause after it in ms.
typedef Pulse = (int code, int pauseMs);

class Buzz {
  static const recording = <Pulse>[(1, 180), (1, 180), (1, 0)]; // three short
  static const paused = <Pulse>[(3, 0)]; // one long
  static const earmark = <Pulse>[(2, 0)]; // one medium
  static int durationMs(int code) => switch (code) { 2 => 300, 3 => 500, _ => 100 };
}

/// Rebuilds Opus frames from audio notifications.
///
/// Each notification is [packet u16 LE][index u8][bytes]. A frame longer than the
/// connection's MTU is split over several notifications with index 1, 2, ...; a new frame
/// always starts at index 0, so the previous one is complete when an index-0 packet arrives.
class FrameAssembler {
  final void Function(Uint8List frame) onFrame;
  final _buf = BytesBuilder(copy: false);
  FrameAssembler(this.onFrame);

  void add(List<int> data) {
    if (data.length <= 3) return;
    if (data[2] == 0 && _buf.length > 0) {
      onFrame(_buf.takeBytes());
    }
    _buf.add(data.sublist(3));
  }

  /// Emit whatever is buffered (when the stream stops).
  void flush() {
    if (_buf.length > 0) onFrame(_buf.takeBytes());
  }
}

/// Decides what a button press means.
///
/// The firmware only reports a double tap when the second press lands within 300 ms; a
/// relaxed double tap arrives as two single taps. Two taps within [pairWindow] count as a
/// double tap, so a single tap waits that long before it is acted on (as an earmark).
class TapInterpreter {
  final Duration pairWindow;
  final void Function(DateTime at) onSingle;
  final void Function() onDouble;
  final DateTime Function() now;
  DateTime? _pendingAt;
  Object? _timer;
  final Object? Function(Duration, void Function()) schedule;
  final void Function(Object?) cancel;

  TapInterpreter({
    required this.onSingle,
    required this.onDouble,
    required this.schedule,
    required this.cancel,
    this.pairWindow = const Duration(milliseconds: 1000),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  void handle(ButtonEvent ev) {
    switch (ev) {
      case ButtonEvent.doubleTap:
        _clear();
        onDouble();
      case ButtonEvent.tap:
        final t = now();
        if (_pendingAt != null && t.difference(_pendingAt!) <= pairWindow) {
          _clear();
          onDouble();
        } else {
          _clear();
          _pendingAt = t;
          _timer = schedule(pairWindow, () {
            final at = _pendingAt;
            _pendingAt = null;
            _timer = null;
            if (at != null) onSingle(at);
          });
        }
      default:
        break;
    }
  }

  void _clear() {
    if (_timer != null) cancel(_timer);
    _timer = null;
    _pendingAt = null;
  }
}

/// u32 little-endian epoch seconds, for the time-sync characteristic.
List<int> clockBytes(DateTime t) {
  final b = ByteData(4)..setUint32(0, t.millisecondsSinceEpoch ~/ 1000, Endian.little);
  return b.buffer.asUint8List();
}
