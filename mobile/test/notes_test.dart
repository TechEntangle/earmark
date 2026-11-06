import 'dart:io';

import 'package:earmark/app_controller.dart';
import 'package:earmark/core/config.dart';
import 'package:earmark/notes/conversations.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:earmark/transcribe/heard.dart';
import 'package:earmark/ui/phone_lists.dart';
import 'package:earmark/ui/theme.dart';
import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

class FakeEngine extends LocalAsr {
  final prompts = <List<String>>[];
  final List<Object> replies; // a Map (notes) or an exception, one per call
  FakeEngine(this.replies);
  @override
  bool get supported => true;
  @override
  Future<String> notesAvailability() async => 'available';
  @override
  Future<Map<String, dynamic>> notes(List<String> lines, {String header = ''}) async {
    prompts.add(lines);
    final r = replies[prompts.length - 1];
    if (r is Exception) throw r;
    return r as Map<String, dynamic>;
  }
}

class MemConfig extends ConfigStore {
  @override
  Future<bool> paused() async => false;
}

List<List<Object>> words(double from, String text) {
  var t = from;
  return [
    for (final w in text.split(' ')) [t, (t += 0.4) - 0.1, w],
  ];
}

const notes = {
  'title': 'Vendor contract follow-up',
  'kind': 'meeting',
  'summary': 'We went through the vendor contract. Sam will send it by Thursday.',
  'keyPoints': ['Contract terms agreed'],
  'decisions': ['Keep the budget'],
  'tasks': [
    {'task': 'Send the vendor contract to me', 'owner': 'Sam', 'dueText': 'by Thursday', 'done': false},
    {'task': 'Call the bank about the card', 'owner': 'me', 'dueText': '', 'done': false},
  ],
  'people': ['Sam'],
  'topics': ['contracts'],
};

void main() {
  late Directory dir;
  late Heard heard;
  final t0 = DateTime(2026, 11, 6, 10).millisecondsSinceEpoch / 1000;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('notes');
    heard = Heard(Directory('${dir.path}/heard'));
    heard.add(HeardChunk(1, t0, 30, '', words(1, 'Let us go through the vendor contract.')));
    heard.add(HeardChunk(2, t0 + 30, 30, '', words(2, 'Sam will send it by Thursday. Remind me to call the bank about the card.')));
    heard.add(HeardChunk(3, t0 + 60, 20, '', const [])); // silence, still part of it
    heard.add(HeardChunk(4, t0 + 600, 10, '', words(1, 'Okay.'))); // 10 minutes later: another one, too short
  });

  test('chunks become conversations; they close after the gap; lines and markers for the model', () {
    final cs = Conversations(File('${dir.path}/c.json'));
    cs.sync(heard, gap: 90, now: t0 + 100);
    expect(cs.all.map((c) => (c.id, c.status)), [(4, 'open'), (1, 'open')]);
    cs.sync(heard, gap: 90, now: t0 + 800);
    expect(cs.all.map((c) => (c.id, c.status)), [(4, 'empty'), (1, 'pending')]);
    expect(cs.visible.map((c) => c.id), [1]);
    final c = cs.byId(1)!;
    expect(c.seqs, [1, 2, 3]);
    final lines = Conversations.lines(c, heard);
    expect(lines.map((l) => l.text), [
      'Let us go through the vendor contract.',
      'Sam will send it by Thursday.',
      'Remind me to call the bank about the card.',
    ]);
    expect(lines[1].at, 32);
    final p = Conversations.promptLines(c, heard, [t0 + 33]);
    expect(p[1], startsWith('★ [00:32] Sam'), reason: 'near an earmark');
    expect(p[2], startsWith('◆ ★ [00:'), reason: 'a spoken request to save a task');
    expect(p[0], '[00:01] Let us go through the vendor contract.');
    // kept on the phone
    cs.save();
    expect(Conversations(File('${dir.path}/c.json')).byId(1)!.status, 'pending');
  });

  test('notes are written on the phone, retried when busy, and given up after two failures', () async {
    final engine = FakeEngine([
      const NotesError('busy', 'busy'),
      notes,
      const NotesError('failed', 'boom'),
      const NotesError('failed', 'boom again'),
    ]);
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: engine)
      ..heard = heard
      ..convs = Conversations(File('${dir.path}/c.json'))
      ..asr = const AsrStatus('ready', onDisk: true)
      ..notesState = 'available';
    final later = DateTime.fromMillisecondsSinceEpoch(((t0 + 800) * 1000).round());
    await c.processConversations(now: later);
    expect(c.convs!.byId(1)!.status, 'pending', reason: 'busy: try again later');
    await c.processConversations(now: later);
    final v = c.convs!.byId(1)!;
    expect(v.status, 'ready');
    expect(v.title, 'Vendor contract follow-up');
    expect(v.tasks.map((k) => (k.text, k.owner, k.due)), [
      ('Send the vendor contract to me', 'Sam', 'by Thursday'),
      ('Call the bank about the card', 'me', ''),
    ]);
    expect(engine.prompts.last.any((l) => l.startsWith('◆')), isTrue);
    c.setTaskDone(v.tasks[1], true);
    expect(Conversations(File('${dir.path}/c.json')).byId(1)!.tasks[1].done, isTrue, reason: 'saved');

    c.retryNotes(v);
    await Future<void>.delayed(Duration.zero);
    await c.processConversations(now: later);
    expect(c.convs!.byId(1)!.status, 'failed');
    expect(c.convs!.byId(1)!.error, 'boom again');
    c.dispose();
  });

  testWidgets('conversation and tasks screens', (t) async {
    await loadFonts();
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: FakeEngine([]))
      ..heard = heard
      ..convs = Conversations(File('${dir.path}/c.json'))
      ..notesState = 'available';
    c.convs!.sync(heard, gap: 90, now: t0 + 800);
    Conversations.applyNotes(c.convs!.byId(1)!, Map<String, dynamic>.from(notes));
    Widget wrap(Widget w) => MaterialApp(debugShowCheckedModeBanner: false, theme: earmarkTheme(Brightness.dark), home: w);

    await t.pumpWidget(wrap(PhoneConversationScreen(c: c, id: 1)));
    expect(find.text('Vendor contract follow-up'), findsOneWidget);
    expect(find.text('Send the vendor contract to me'), findsOneWidget);
    expect(find.text('Remind me to call the bank about the card.'), findsOneWidget);
    await expectLater(find.byType(PhoneConversationScreen), matchesGoldenFile('goldens/phone_conversation.png'));

    await t.pumpWidget(wrap(PhoneTasksScreen(c: c)));
    expect(find.text('Call the bank about the card'), findsOneWidget);
    expect(find.text('Send the vendor contract to me'), findsNothing, reason: "Sam's task is under Others");
    await t.tap(find.byType(Checkbox).first);
    await t.pump();
    expect(find.text('Call the bank about the card'), findsNothing, reason: 'done');
    await t.tap(find.text('Others'));
    await t.pump();
    expect(find.text('Send the vendor contract to me'), findsOneWidget);
    await expectLater(find.byType(PhoneTasksScreen), matchesGoldenFile('goldens/phone_tasks.png'));
    t.view.resetPhysicalSize();
  });
}
