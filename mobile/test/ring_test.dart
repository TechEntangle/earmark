import 'dart:typed_data';

import 'package:earmark/pendant/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ring commands match the firmware (big endian)', () {
    expect(Ring.info(), [0x10]);
    expect(Ring.read(258, 3), [0x11, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 3]);
    expect(Ring.advance(1), [0x12, 0, 0, 0, 0, 0, 0, 0, 1]);
  });

  test('INFO and DONE replies parse', () {
    final b = ByteData(31)
      ..setUint8(0, Ring.nInfo)
      ..setUint64(1, 10, Endian.big)
      ..setUint64(9, 25, Endian.big)
      ..setUint32(17, 1000, Endian.big)
      ..setUint64(21, 2, Endian.big)
      ..setUint16(29, 444, Endian.big);
    final i = RingInfo.parse(b.buffer.asUint8List())!;
    expect([i.readSeq, i.writeSeq, i.capacity, i.dropped, i.packetSize, i.unread], [10, 25, 1000, 2, 444, 15]);
    expect(RingInfo.parse([Ring.nAck, 0]), isNull);
    final d = ByteData(10)
      ..setUint8(0, Ring.nDone)
      ..setUint8(1, 0)
      ..setUint64(2, 77, Endian.big);
    expect(parseRingDone(d.buffer.asUint8List()), (0, 77));
    expect(Ring.seconds(100), closeTo(11, 0.01));
  });
}
