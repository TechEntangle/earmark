import 'dart:convert';
import 'dart:io';

import 'package:earmark/app_controller.dart';
import 'package:earmark/notes/cloud.dart';
import 'package:earmark/notes/conversations.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:earmark/ui/settings_screen.dart';
import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'screens_test.dart' show FakeConfig, FakePendant, loadFonts, wrap;

class OnPhone extends LocalAsr {
  @override
  bool get supported => true;
}

void main() {
  setUpAll(loadFonts);

  test('cloud notes and answers: the right request, the reply in the on-device shape', () async {
    final sent = <http.Request>[];
    final openai = CloudModel(AiProvider.openai, 'sk-test', client: MockClient((r) async {
      sent.add(r);
      final notes = {'title': 'Vendor call', 'kind': 'call', 'summary': 'Talked pricing.', 'keyPoints': ['Price agreed'],
        'decisions': [], 'tasks': [{'task': 'Send the contract', 'owner': 'me', 'dueText': 'by Friday', 'done': false}],
        'people': ['Sam'], 'topics': ['pricing']};
      return http.Response(jsonEncode({'choices': [{'message': {'content': jsonEncode(notes)}}]}), 200);
    }));
    final n = await openai.notes(['[00:01] Me: I will send the contract by Friday.'], header: 'The recording started Friday.');
    expect(n['title'], 'Vendor call');
    expect((n['tasks'] as List).single['dueText'], 'by Friday');
    expect(sent.single.headers['Authorization'], 'Bearer sk-test');
    expect(sent.single.body, contains('send the contract by Friday'));
    expect(sent.single.body, isNot(contains('audio')), reason: 'text only');

    final anthropic = CloudModel(AiProvider.anthropic, 'k', client: MockClient((r) async {
      expect(r.url.host, 'api.anthropic.com');
      expect(r.headers['x-api-key'], 'k');
      return http.Response(jsonEncode({'content': [{'type': 'text', 'text': '{"answer": "Sam sends it Friday.", "sources": [2, 9]}'}]}), 200);
    }));
    final (text, used) = await anthropic.answer('When?', ['a', 'b']);
    expect(text, 'Sam sends it Friday.');
    expect(used, [2], reason: 'only excerpts that exist');

    final bad = CloudModel(AiProvider.openai, 'nope', client: MockClient((r) async => http.Response('{"error": {"message": "bad key"}}', 401)));
    expect(await bad.check(), contains('did not accept'));
    expect(() => CloudModel(AiProvider.openai, '').notes(['x']), throwsA(isA<NotesError>()));
  });

  testWidgets('settings: everything in one place; choosing a cloud model asks for a key', (t) async {
    t.view.physicalSize = const Size(1179, 6400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final p = FakePendant();
    await p.start();
    final c = EarmarkController(config: FakeConfig(), pendant: p, asr: OnPhone())
      ..store = ChunkStore(Directory.systemTemp.createTempSync('st'))
      ..convs = Conversations(File('${Directory.systemTemp.createTempSync('cv').path}/c.json'))
      ..transcribeHere = true
      ..notesState = 'notEligible';
    expect(c.notesOn, isFalse);
    await t.pumpWidget(wrap(SettingsScreen(c: c)));
    expect(find.text('NOTES, TASKS AND ASK'), findsOneWidget);
    expect(find.text('STORAGE'), findsOneWidget);
    await t.tap(find.text('OpenAI'));
    await t.pump();
    expect(c.ai, AiProvider.openai);
    expect(find.byKey(const Key('aiKey')), findsOneWidget);
    await c.setAiKey(AiProvider.openai, 'sk-test');
    expect(c.notesOn, isTrue, reason: 'notes with your own key, even without Apple Intelligence');
    expect(c.cloud?.model, 'gpt-4.1-mini');
    await t.pump();
    await expectLater(find.byType(SettingsScreen), matchesGoldenFile('goldens/settings_full.png'));
    c.dispose();
  });
}
