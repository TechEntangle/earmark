// End-to-end: the app's own code (ChunkStore + Api) against a running Earmark Mac service.
// Run with: EARMARK_TEST_SERVER=http://127.0.0.1:PORT EARMARK_TEST_FRAMES=frames.bin flutter test test_e2e
import 'dart:io';
import 'dart:typed_data';

import 'package:earmark/core/api.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:flutter_test/flutter_test.dart';

List<Uint8List> frames(Uint8List b) {
  final out = <Uint8List>[];
  final d = ByteData.sublistView(b);
  var i = 0;
  while (i + 2 <= b.length) {
    final n = d.getUint16(i, Endian.big);
    out.add(b.sublist(i + 2, i + 2 + n));
    i += 2 + n;
  }
  return out;
}

void main() {
  final server = Platform.environment['EARMARK_TEST_SERVER'];
  test('pair, hold the pendant, upload real audio, see the conversation on the Mac', () async {
    final base = Uri.parse(server!);
    final local = Api(base, null); // this test runs on the same machine: it can make a pairing code
    final code = (await local.post('/api/phone/code'))['code'] as String;
    // everything after this goes the way the phone does it
    final token = await Api(base, null).pair(code, 'Test phone', 'Android');
    final api = Api(base, token);
    final hb = await api.heartbeat({'holds_pendant': true, 'pendant_connected': true, 'battery': 64, 'state': 'recording'});
    expect(hb['settings'], isA<Map>());
    final before = (await api.sessions()).length;

    final dir = Directory.systemTemp.createTempSync('earmark_e2e');
    var now = (DateTime.now().millisecondsSinceEpoch - 900 * 1000) * 1000;
    final store = ChunkStore(dir, chunkSeconds: 5, nowMicros: () => now);
    store.ensureSeqAbove(hb['last_seq'] as int);
    final audio = frames(File(Platform.environment['EARMARK_TEST_FRAMES']!).readAsBytesSync());
    for (final f in audio) {
      now += 20000;
      store.add(f);
    }
    store.close();
    // a later stretch after a long break closes the first conversation on the Mac
    now += 300 * 1000000;
    for (final f in audio.take(100)) {
      now += 20000;
      store.add(f);
    }
    store.close();
    final pending = store.pending();
    expect(pending.length, greaterThan(2));
    for (final c in pending) {
      final r = await api.uploadChunk(c.file.readAsBytesSync(), start: c.startSeconds, seq: c.seq);
      expect(r['ok'], isTrue);
      store.markUploaded(c);
    }
    // retrying an already-sent chunk is harmless
    final again = await api.uploadChunk(Uint8List.fromList([0, 1, 7]), start: pending.first.startSeconds, seq: pending.first.seq);
    expect(again['duplicate'], isTrue);
    await api.event('earmark', at: DateTime.fromMicrosecondsSinceEpoch(now - 1000000));

    List<dynamic> phoneSessions = [];
    for (var i = 0; i < 40 && phoneSessions.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      phoneSessions = (await api.sessions()).where((s) => s['source'] == 'phone').toList();
    }
    expect(phoneSessions, isNotEmpty);
    expect((await api.sessions()).length, greaterThan(before));
    final st = await api.status();
    expect('${st['pendant']['via']}', startsWith('Test phone'));
    expect(st['pendant']['battery'], 64);
    await api.heartbeat({'holds_pendant': false});
    dir.deleteSync(recursive: true);
  }, skip: server == null ? 'set EARMARK_TEST_SERVER to run against a Mac service' : false, timeout: const Timeout(Duration(minutes: 2)));
}
