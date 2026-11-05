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
  static const ringService = '30295780-4301-eabd-2904-2849adfeae43'; // the pendant's own memory
  static const ringCtrl = '30295781-4301-eabd-2904-2849adfeae43';
  static const ringStat = '30295782-4301-eabd-2904-2849adfeae43';
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


// ---------------------------------------------------------------- the pendant's own memory
// While nothing is connected the pendant records into a ring of 444-byte records
// (4-byte big-endian timestamp + packed Opus). Commands go to ringCtrl; replies arrive as
// notifications on the same characteristic.
class Ring {
  static const record = 444;
  static const cmdStop = 0x03, cmdInfo = 0x10, cmdRead = 0x11, cmdAdvance = 0x12;
  static const nAck = 0x01, nInfo = 0x02, nData = 0x03, nDone = 0x04;
  static const statusText = {6: 'invalid command', 9: 'storage not ready', 10: 'sequence out of range'};

  static List<int> info() => [cmdInfo];
  static List<int> read(int start, int count) {
    final b = ByteData(13)
      ..setUint8(0, cmdRead)
      ..setUint64(1, start, Endian.big)
      ..setUint32(9, count, Endian.big);
    return b.buffer.asUint8List();
  }

  static List<int> advance(int seq) {
    final b = ByteData(9)
      ..setUint8(0, cmdAdvance)
      ..setUint64(1, seq, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Seconds of audio in [records] records (about 4000 bytes of Opus per second).
  static double seconds(int records) => records * 440 / 4000;
}

class RingInfo {
  final int readSeq, writeSeq, capacity, dropped, packetSize;
  const RingInfo(this.readSeq, this.writeSeq, this.capacity, this.dropped, this.packetSize);
  int get unread => writeSeq > readSeq ? writeSeq - readSeq : 0;

  /// INFO notification: [0x02][read u64][write u64][capacity u32][dropped u64][packet u16], big endian.
  static RingInfo? parse(List<int> m) {
    if (m.length < 31 || m[0] != Ring.nInfo) return null;
    final d = ByteData.sublistView(Uint8List.fromList(m));
    return RingInfo(d.getUint64(1, Endian.big), d.getUint64(9, Endian.big), d.getUint32(17, Endian.big),
        d.getUint64(21, Endian.big), d.getUint16(29, Endian.big));
  }
}

/// DONE notification: [0x04][status u8][next u64] -> (status, next sequence).
(int, int)? parseRingDone(List<int> m) {
  if (m.length < 10 || m[0] != Ring.nDone) return null;
  final d = ByteData.sublistView(Uint8List.fromList(m));
  return (d.getUint8(1), d.getUint64(2, Endian.big));
}
