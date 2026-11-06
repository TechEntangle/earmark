import 'dart:convert';
import 'dart:io';

import 'package:earmark/app_controller.dart';
import 'package:earmark/ask/ask_index.dart';
import 'package:earmark/core/api.dart';
import 'package:earmark/notes/conversations.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:earmark/transcribe/heard.dart';
import 'package:earmark/ui/ask_screen.dart';
import 'package:earmark/ui/phone_lists.dart';
import 'package:earmark/ui/phone_today.dart';
import 'package:earmark/ui/theme.dart';
import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'notes_test.dart' show MemConfig, words;
import 'screens_test.dart' show loadFonts;

/// A stand-in for Apple's sentence embedding: a bag of words hashed into 64 numbers.
List<double> bag(String s) {
  final v = List<double>.filled(64, 0);
  for (final w in terms(s)) {
    v[w.hashCode % 64] += 1;
  }
  return v;
}

class AskEngine extends LocalAsr {
  final asked = <(String, List<String>)>[];
  @override
  bool get supported => true;
  @override
  Future<String> notesAvailability() async => 'available';
  @override
  Future<List<List<double>>> embed(List<String> texts) async => [for (final t in texts) bag(t)];
  @override
  Future<(String, List<int>)> answer(String q, List<String> excerpts, {String today = ''}) async {
    asked.add((q, excerpts));
    return ('Sam will send the vendor contract by Thursday [1].', [1]);
  }
}

void main() {
  final t0 = DateTime(2026, 11, 6, 10).millisecondsSinceEpoch / 1000;

  (EarmarkController, AskEngine) setUpController() {
    final dir = Directory.systemTemp.createTempSync('ask');
    final heard = Heard(Directory('${dir.path}/heard'));
    heard.add(HeardChunk(1, t0, 30, '', words(1, 'Let us go through the vendor contract. Sam will send it by Thursday.')));
    heard.add(HeardChunk(5, t0 + 3600, 30, '', words(1, 'The office plants need water. Lunch is at one.')));
    final engine = AskEngine();
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: engine)
      ..heard = heard
      ..convs = Conversations(File('${dir.path}/c.json'))
      ..askIndex = AskIndex(Directory('${dir.path}/ask'))
      ..asr = const AsrStatus('ready', onDisk: true)
      ..notesState = 'available';
    c.convs!.sync(heard, gap: 90, now: t0 + 9000);
    Conversations.applyNotes(c.convs!.byId(1)!, {
      'title': 'Vendor contract follow-up',
      'summary': 'Went through the vendor contract.',
      'tasks': [
        {'task': 'Send the vendor contract to me', 'owner': 'Sam', 'dueText': 'by Thursday'},
      ],
    });
    return (c, engine);
  }

  test('passages from notes, tasks and talk; found by words and meaning; kept across restarts', () async {
    final (c, engine) = setUpController();
    expect(c.askPending, 2);
    final a = await c.ask('When will Sam send the contract?');
    expect(c.askPending, 0, reason: 'indexed before answering');
    expect(a.text, 'Sam will send the vendor contract by Thursday [1].');
    expect(a.hits.first.$1.conv, 1);
    expect(engine.asked.single.$2.first, contains('Vendor contract follow-up'), reason: 'excerpts carry the title and time');
    expect(a.hits.any((h) => h.$1.text.contains('plants')), isFalse, reason: 'unrelated: ranked below or left out');
    final again = AskIndex(c.askIndex!.dir);
    expect(again.passages.length, c.askIndex!.passages.length);
    expect(again.indexed.keys.toSet(), {1, 5});
  });

  testWidgets('Ask screen: example question, answer with the moments it came from', (t) async {
    await loadFonts();
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final (c, _) = setUpController();
    await t.pumpWidget(MaterialApp(theme: earmarkTheme(Brightness.dark), home: AskScreen(c: c)));
    await t.runAsync(() async {
      await t.enterText(find.byKey(const Key('askField')), 'When will Sam send the contract?');
      await t.tap(find.byKey(const Key('askSend')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('answerText')), findsOneWidget);
    expect(find.textContaining('Vendor contract follow-up'), findsWidgets);
    await expectLater(find.byType(AskScreen), matchesGoldenFile('goldens/ask.png'));
    await t.tap(find.textContaining('Vendor contract follow-up').first);
    await t.pumpAndSettle();
    expect(find.byType(PhoneConversationScreen), findsOneWidget);
    t.view.resetPhysicalSize();
  });

  test('without the sentence model, Ask still finds passages by their words', () async {
    final (c, _) = setUpController();
    final noModel = _NoEmbed();
    final c2 = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: noModel)
      ..heard = c.heard
      ..convs = c.convs
      ..askIndex = AskIndex(Directory.systemTemp.createTempSync('ask2'))
      ..asr = const AsrStatus('ready', onDisk: true)
      ..notesState = 'available';
    final a = await c2.ask('When will the vendor contract arrive?');
    expect(a.hits, isNotEmpty);
    expect(a.hits.first.$1.conv, 1);
    expect(c2.askIndex!.passages, isNotEmpty);
    // the model shows up later: vectors fill in on the next change, nothing breaks
    expect(AskIndex(c2.askIndex!.dir).passages.length, c2.askIndex!.passages.length);
  });

  test('a question about a day uses that day\'s conversations', () async {
    final now = DateTime(2026, 11, 7, 9); // Saturday morning
    expect(askSpan('Summarise yesterday', now), (DateTime(2026, 11, 6), DateTime(2026, 11, 7)));
    expect(askSpan('what happened today', now)!.$1, DateTime(2026, 11, 7));
    expect(askSpan('what did we say on Thursday', now), (DateTime(2026, 11, 5), DateTime(2026, 11, 6)));
    expect(askSpan('this week', now)!.$1, DateTime(2026, 11, 2));
    expect(askSpan('budget', now), isNull);
    final (c, _) = setUpController();
    await c.updateAskIndex(limit: 50);
    final ps = c.askIndex!.during(c.convs!.all, t0 - 60, t0 + 86400);
    expect(ps.first.kind, 'notes');
    expect(ps.map((p) => p.conv).toSet(), {1, 5});
  });

  testWidgets("today on the phone: the day's brief, what's due, conversations", (t) async {
    t.view.physicalSize = const Size(1179, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (c, engine) = setUpController();
    final day = DateTime.fromMillisecondsSinceEpoch((t0 * 1000).round());
    expect(c.dayConversations(day).map((v) => v.id), [1, 5]);
    await t.runAsync(() => c.writeBrief(day));
    expect(c.briefFor(day), 'Sam will send the vendor contract by Thursday.');
    expect(engine.asked.last.$2.first, contains('Vendor contract follow-up'));
    await t.pumpWidget(MaterialApp(theme: earmarkTheme(Brightness.light), home: PhoneTodayScreen(c: c)));
    await t.pump();
    expect(find.byKey(const Key('dayBrief')), findsOneWidget);
    c.dispose();
  });

  test('follow-up questions read the one before; nothing here: your Mac answers', () async {
    expect(EarmarkController.isFollowUp('and when is it due?'), isTrue);
    expect(EarmarkController.isFollowUp('What did we decide about the vendor contract budget?'), isFalse);
    final (c, engine) = setUpController();
    final first = await c.ask('Who sends the vendor contract?');
    await c.ask('and when?', previous: first);
    expect(engine.asked.last.$1, contains('Earlier I asked: "Who sends the vendor contract?"'));
    expect(engine.asked.last.$2.join(), contains('vendor contract'), reason: 'found through the question before');

    c.api = Api(Uri.parse('https://mac.tail1234.ts.net'), 'tok', client: MockClient((r) async {
      expect(r.url.path, '/api/ask');
      return http.Response(jsonEncode({'answer': 'Priya booked the venue on Monday.', 'used': [1],
        'passages': [{'sid': 9, 't': 0, 'kind': 'talk', 'text': 'Priya booked the venue.', 'at': 1790000000}]}), 200);
    }));
    c.link = Link.online;
    final a = await c.ask('Who booked the venue?');
    expect(a.fromMac, isTrue);
    expect(a.text, 'Priya booked the venue on Monday.');
    c.dispose();
  });
}

class _NoEmbed extends AskEngine {
  @override
  Future<List<List<double>>> embed(List<String> texts) async => [for (final _ in texts) <double>[]];
}
