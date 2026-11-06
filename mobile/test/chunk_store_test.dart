import 'dart:io';
import 'dart:typed_data';

import 'package:earmark/recorder/chunk_store.dart';
import 'package:flutter_test/flutter_test.dart';

List<Uint8List> parse(Uint8List b) {
  final out = <Uint8List>[];
  var i = 0;
  final d = ByteData.sublistView(b);
  while (i + 2 <= b.length) {
    final n = d.getUint16(i, Endian.big);
    i += 2;
    out.add(b.sublist(i, i + n));
    i += n;
  }
  expect(i, b.length);
  return out;
}

void main() {
  late Directory dir;
  late int now;
  ChunkStore make({int chunkSeconds = 30}) => ChunkStore(dir, chunkSeconds: chunkSeconds, nowMicros: () => now);
  Uint8List frame(int k) => Uint8List.fromList(List.filled(40 + k % 7, k % 251));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('earmark_chunks');
    now = 1_800_000_000 * 1000000;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('frames become a chunk in the Mac upload format, with the right start time', () {
    final s = make();
    for (var k = 0; k < 100; k++) {
      now += 20000;
      s.add(frame(k));
    }
    expect(s.pending(), isEmpty, reason: 'still being written');
    s.close();
    final p = s.pending();
    expect(p.length, 1);
    expect(p.single.seq, 1);
    expect(p.single.startSeconds, closeTo(1_800_000_000.0, 0.001));
    final frames = parse(p.single.file.readAsBytesSync());
    expect(frames.length, 100);
    expect(frames[5], frame(5));
  });

  test('a long chunk rolls over and a gap starts a new one', () {
    final s = make(chunkSeconds: 1);
    for (var k = 0; k < 120; k++) {
      now += 20000;
      s.add(frame(k));
    }
    now += 5 * 1000000; // pendant away for 5 s
    s.add(frame(1));
    s.close();
    final p = s.pending();
    expect(p.map((c) => parse(c.file.readAsBytesSync()).length).toList(), [50, 50, 20, 1]);
    expect(p.last.startSeconds - p[2].startSeconds, greaterThan(5));
    expect(p.map((c) => c.seq).toList(), [1, 2, 3, 4]);
  });

  test('a chunk open when the app died is kept and uploaded later', () {
    var s = make();
    for (var k = 0; k < 10; k++) {
      now += 20000;
      s.add(frame(k));
    }
    // no close(): simulate a crash, then a fresh start
    sleep(const Duration(milliseconds: 50));
    s = make();
    final p = s.pending();
    expect(p.length, 1);
    expect(parse(p.single.file.readAsBytesSync()).length, greaterThan(0));
  });

  test('sequence numbers never repeat, even after uploads and restarts', () {
    var s = make();
    s.add(frame(1));
    s.close();
    for (final c in s.pending()) {
      s.markUploaded(c);
    }
    s = make();
    now += 5 * 1000000;
    s.add(frame(2));
    s.close();
    expect(s.pending().single.seq, 2);
    // the Mac says it already has up to 40 (e.g. app reinstalled)
    s.ensureSeqAbove(40);
    now += 5 * 1000000;
    s.add(frame(3));
    s.close();
    expect(s.pending().last.seq, 41);
  });

  test('sent chunks are kept for playing back, then pruned', () {
    final dir = Directory.systemTemp.createTempSync('keep');
    var now = DateTime(2026, 11, 6).microsecondsSinceEpoch;
    final s = ChunkStore(dir, chunkSeconds: 1, nowMicros: () => now);
    for (var i = 0; i < 50; i++) {
      s.add(Uint8List.fromList([1, 2, 3]));
      now += 20000;
    }
    final c = s.pending().single;
    s.markUploaded(c);
    expect(s.pending(), isEmpty);
    expect(s.fileFor(c.seq, c.startMicros)!.path, contains('/kept/'));
    now += 31 * 86400 * 1000000;
    final again = ChunkStore(dir, chunkSeconds: 1, nowMicros: () => now);
    expect(again.fileFor(c.seq, c.startMicros), isNull, reason: 'older than 30 days');
  });
}
