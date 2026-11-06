import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:earmark/app_controller.dart';
import 'package:earmark/core/api.dart';
import 'package:earmark/core/config.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:earmark/transcribe/heard.dart';
import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeAsr extends LocalAsr {
  final calls = <(String, String?)>[];
  @override
  bool get supported => true;
  @override
  Future<AsrStatus> status() async => const AsrStatus('ready', progress: 1, onDisk: true);
  @override
  Future<void> prepare() async {}
  @override
  Future<AsrResult> transcribe(String path, {String? prev}) async {
    calls.add((path, prev));
    final n = calls.length;
    return AsrResult('words of chunk $n', [AsrWord(0.1, 0.4, 'words'), AsrWord(0.5, 0.7, 'of')], 30);
  }
}

class MemConfig extends ConfigStore {
  @override
  Future<bool> paused() async => false;
}

void main() {
  test('heard: stretches join chunks without a gap; a week is kept; survives a restart', () {
    final dir = Directory.systemTemp.createTempSync('heard');
    final h = Heard(dir);
    final t0 = DateTime.now().millisecondsSinceEpoch / 1000 - 3600;
    h.add(HeardChunk(1, t0, 30, 'one', const []));
    h.add(HeardChunk(2, t0 + 30.02, 30, 'two', const []));
    h.add(HeardChunk(3, t0 + 300, 12, 'three', const []));
    h.add(HeardChunk(3, t0 + 300, 12, 'duplicate', const []));
    final day = Heard.dayKey(DateTime.fromMillisecondsSinceEpoch((t0 * 1000).round()));
    final s = h.stretches(day);
    expect(s.map((x) => x.text), ['three', 'one two'], reason: 'newest first');
    // an old day is dropped on start
    File('${dir.path}/2020-01-01.jsonl').writeAsStringSync('{"seq":9,"start":1,"seconds":1,"text":"old","words":[]}\n');
    final again = Heard(dir);
    expect(again.has(2), isTrue);
    expect(again.days().contains('2020-01-01'), isFalse);
    expect(again.latest()!.text, 'three');
  });

  test('chunks are transcribed on the phone first, then the text and the audio go to the Mac', () async {
    final dir = Directory.systemTemp.createTempSync('asr');
    var now = DateTime(2026, 11, 6, 10).microsecondsSinceEpoch;
    final asr = FakeAsr();
    final c = EarmarkController(config: MemConfig(), asr: asr);
    c.store = ChunkStore(Directory('${dir.path}/rec'), chunkSeconds: 1, nowMicros: () => now);
    c.heard = Heard(Directory('${dir.path}/heard'));
    final sent = <String>[];
    c.api = Api(Uri.parse('https://mac.test'), 'tok', client: MockClient((r) async {
      if (r.url.path == '/api/app/transcript') {
        final b = jsonDecode(r.body) as Map;
        sent.add('text ${b['seq']}: ${b['text']}');
      } else if (r.url.path == '/api/app/audio') {
        sent.add('audio ${r.headers['x-earmark-seq']}');
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    }));
    // two back-to-back one-second chunks
    for (var i = 0; i < 100; i++) {
      c.store!.add(Uint8List.fromList([0xf8, 1, 2]));
      now += 20000;
    }
    expect(c.store!.pending().length, 2);

    // the model isn't ready: nothing is held back (the Mac transcribes)
    c.asr = const AsrStatus('downloading');
    await c.transcribePending();
    expect(asr.calls, isEmpty);

    c.asr = const AsrStatus('ready', onDisk: true);
    await c.pumpUploads();
    expect(sent, isEmpty, reason: 'a chunk waits for its text while the model is ready');

    await c.transcribePending();
    expect(asr.calls.length, 2);
    expect(asr.calls[0].$2, isNull);
    expect(asr.calls[1].$2, endsWith('asr_prev.bin'), reason: 'the chunk before gives context at the boundary');
    expect(c.heard!.has(1) && c.heard!.has(2), isTrue);

    await c.pumpUploads();
    expect(sent, ['text 1: words of chunk 1', 'audio 1', 'text 2: words of chunk 2', 'audio 2']);
    expect(c.store!.pending(), isEmpty);
    expect(c.heard!.latest()!.text, 'words of chunk 1 words of chunk 2', reason: 'kept on the phone after sending');
  });
}
