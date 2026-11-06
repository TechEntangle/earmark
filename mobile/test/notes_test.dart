import 'dart:io';

import 'dart:convert';

import 'package:earmark/app_controller.dart';
import 'package:earmark/core/api.dart';
import 'package:earmark/core/config.dart';
import 'package:earmark/notes/conversations.dart';
import 'package:earmark/notes/voices.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:earmark/transcribe/heard.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:earmark/ui/phone_lists.dart';
import 'package:earmark/ui/player.dart';
import 'package:earmark/ui/theme.dart';
import 'package:earmark_asr/earmark_asr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'screens_test.dart' show loadFonts;

class FakeEngine extends LocalAsr {
  final prompts = <List<String>>[];
  final List<Object> replies; // a Map (notes) or an exception, one per call
  Diarization? diarization;
  FakeEngine(this.replies, {this.diarization});
  @override
  bool get speakersSupported => diarization != null;
  @override
  Future<Diarization> diarize(List<String> paths, List<double> offsets) async => diarization!;
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

class FakeAudio extends AudioBackend {
  final calls = <String>[];
  bool _playing = false;
  double _pos = 0;
  @override
  bool get supported => true;
  @override
  Future<double> prepare(List<String> paths, List<double> offsets, String out) async {
    calls.add('prepare ${paths.length} ${offsets.join(',')}');
    return 80;
  }
  @override
  Future<PlayerState> play(String path, {double? at}) async {
    calls.add('play ${at ?? '-'}');
    _playing = true;
    _pos = at ?? _pos;
    return PlayerState(playing: true, position: _pos, duration: 80, path: path);
  }
  @override
  Future<PlayerState> pause() async {
    calls.add('pause');
    _playing = false;
    return PlayerState(playing: false, position: _pos, duration: 80);
  }
  @override
  Future<PlayerState> state() async => PlayerState(playing: _playing, position: _pos, duration: 80);
  @override
  Future<PlayerState> stop() async => const PlayerState();
  @override
  Future<PlayerState> seek(double at) async => PlayerState(playing: _playing, position: _pos = at, duration: 80);
  @override
  Future<PlayerState> speed(double x) async {
    calls.add('speed $x');
    return PlayerState(playing: _playing, position: _pos, duration: 80);
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

  test('another language waits for the Mac, is filled with its translation, then gets notes', () async {
    final h = Heard(Directory('${dir.path}/heard2'));
    h.add(HeardChunk(1, t0, 30, '', words(1, 'Let us start.')));
    h.add(const HeardChunk(2, 0, 30, '', [], lang: 'mr', checked: true).copyAt(t0 + 30));
    final engine = FakeEngine([notes]);
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: engine)
      ..heard = h
      ..convs = Conversations(File('${dir.path}/c2.json'))
      ..asr = const AsrStatus('ready', onDisk: true)
      ..notesState = 'available'
      ..link = Link.online;
    var ready = false;
    c.api = Api(Uri.parse('https://mac.test'), 'tok', client: MockClient((r) async {
      expect(r.url.path, '/api/app/text');
      return http.Response(jsonEncode({'ready': ready, 'segments': [
        {'start': t0 + 31, 'end': t0 + 38, 'text': 'We will meet the bank on Monday.', 'from': 'mr'},
      ]}), 200);
    }));
    final later = DateTime.fromMillisecondsSinceEpoch(((t0 + 800) * 1000).round());
    await c.processConversations(now: later);
    final v = c.convs!.byId(1)!;
    expect(v.status, 'pending');
    expect(engine.prompts, isEmpty, reason: 'waits for the translation');
    expect(Conversations.lines(v, h).last.text, pendingLabel);

    await c.fillFromMac(now: later); // the Mac hasn't finished
    expect(h.bySeq(2)!.awaitingMac, isTrue);
    ready = true;
    await c.fillFromMac(now: later.add(const Duration(minutes: 2)));
    expect(h.bySeq(2)!.text, 'We will meet the bank on Monday.');
    expect(Heard(Directory('${dir.path}/heard2')).bySeq(2)!.translated, isTrue, reason: 'saved');
    await c.processConversations(now: later);
    expect(c.convs!.byId(1)!.status, 'ready');
    expect(engine.prompts.single.last, contains('We will meet the bank on Monday.'));
    c.dispose();
  });

  testWidgets('playing back a conversation from the audio kept on the phone; a line plays from its time', (t) async {
    await loadFonts();
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final store = ChunkStore(Directory('${dir.path}/rec'));
    for (final (seq, at) in [(1, t0), (2, t0 + 30), (3, t0 + 60)]) {
      File('${store.keptDir.path}/${seq}_${(at * 1e6).round()}.chunk').writeAsBytesSync([0, 1, 0]);
    }
    final audio = FakeAudio();
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: FakeEngine([]))
      ..heard = heard
      ..store = store
      ..convs = Conversations(File('${dir.path}/c3.json'))
      ..notesState = 'available';
    c.convs!.sync(heard, gap: 90, now: t0 + 800);
    Conversations.applyNotes(c.convs!.byId(1)!, Map<String, dynamic>.from(notes));
    await t.pumpWidget(MaterialApp(theme: earmarkTheme(Brightness.dark), home: PhoneConversationScreen(c: c, id: 1, audio: audio)));
    expect(find.byKey(const Key('playerBar')), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const Key('playBtn')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    expect(audio.calls.take(2), ['prepare 3 0.0,30.0,60.0', 'play -']);
    await t.ensureVisible(find.text('Sam will send it by Thursday.'));
    await t.runAsync(() async {
      await t.tap(find.text('Sam will send it by Thursday.'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    expect(audio.calls.last, 'play 32.0');
    await expectLater(find.byType(PhoneConversationScreen), matchesGoldenFile('goldens/phone_playback.png'));
    await t.pumpWidget(const SizedBox());
    t.view.resetPhysicalSize();
  });

  testWidgets('who spoke when: turns split lines, the loudest voice is suggested as Me, naming a voice is remembered',
      (t) async {
    await loadFonts();
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final store = ChunkStore(Directory('${dir.path}/rec2'));
    for (final (seq, at) in [(1, t0), (2, t0 + 30), (3, t0 + 60)]) {
      File('${store.keptDir.path}/${seq}_${(at * 1e6).round()}.chunk').writeAsBytesSync([0, 1, 0]);
    }
    List<double> vec(double a, double b) => [a, b, 0, 0];
    final engine = FakeEngine([notes, notes, notes],
        diarization: Diarization([(0.5, 31.9, 'S1'), (31.95, 34.35, 'S2'), (34.36, 50, 'S1')], {
          'S1': SpeakerInfo(vec(1, 0.1), 45, 0.30), // the wearer: loudest
          'S2': SpeakerInfo(vec(0.1, 1), 2, 0.05),
        }));
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: engine)
      ..heard = heard
      ..store = store
      ..voiceBook = VoiceBook(File('${dir.path}/voices.json'))
      ..convs = Conversations(File('${dir.path}/c4.json'))
      ..asr = const AsrStatus('ready', onDisk: true)
      ..notesState = 'available';
    final later = DateTime.fromMillisecondsSinceEpoch(((t0 + 800) * 1000).round());
    await t.runAsync(() => c.processConversations(now: later)); // speakers
    final v = c.convs!.byId(1)!;
    expect(v.spk, 'done');
    expect(v.label('S1'), 'Me?', reason: 'loudest voice, no voice saved as Me yet');
    expect(v.label('S2'), 'Speaker 2');
    final lines = Conversations.lines(v, heard);
    expect(lines.map((l) => (l.speaker, l.text)).toList(), [
      ('S1', 'Let us go through the vendor contract.'),
      ('S2', 'Sam will send it by Thursday.'),
      ('S1', 'Remind me to call the bank about the card.'),
    ]);
    await t.runAsync(() => c.processConversations(now: later)); // notes, with speakers
    expect(engine.prompts.last[1], '[00:32] Speaker 2: Sam will send it by Thursday.',
        reason: 'guesses are not given to the model as names');

    await t.pumpWidget(MaterialApp(theme: earmarkTheme(Brightness.dark), home: PhoneConversationScreen(c: c, id: 1, audio: FakeAudio())));
    expect(find.text('ME?'), findsWidgets);
    await t.ensureVisible(find.byKey(const Key('speaker_S2')));
    await t.tap(find.byKey(const Key('speaker_S2')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('speakerName')), 'Sam');
    await t.tap(find.byKey(const Key('saveSpeaker')));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(v.label('S2'), 'Sam');
    expect(c.voiceBook!.byName('Sam'), isNotNull, reason: 'the voice is learnt');
    expect(v.status, isIn(['pending', 'ready']), reason: 'notes rewritten with the name');
    await expectLater(find.byType(PhoneConversationScreen), matchesGoldenFile('goldens/phone_speakers.png'));

    // a later conversation with the same voice: named automatically
    final v2 = Conversation(99, t0 + 5000, t0 + 5030, [], voices: {'X': {'embedding': vec(0.12, 1), 'seconds': 5.0}});
    c.convs!.all.add(v2);
    c.nameSpeaker(v, 'S1', 'me');
    expect(v.label('S1'), 'Me');
    expect(v2.label('X'), 'Sam', reason: 'recognised from the saved voice');
    await t.pumpWidget(const SizedBox());
    t.view.resetPhysicalSize();
  });

  testWidgets('editing: rename, star, fix a line and who said it, delete', (t) async {
    await loadFonts();
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final c = EarmarkController(config: MemConfig(), pendant: PendantService(), asr: FakeEngine([]))
      ..heard = heard
      ..convs = Conversations(File('${dir.path}/c5.json'))
      ..notesState = 'available';
    c.convs!.sync(heard, gap: 90, now: t0 + 800);
    final v = c.convs!.byId(1)!
      ..turns = [[0.0, 31.9, 'S1'], [31.95, 34.35, 'S2'], [34.36, 50.0, 'S1']]
      ..voices = {'S1': {'name': 'Me'}, 'S2': {}};
    Conversations.applyNotes(v, Map<String, dynamic>.from(notes));
    await t.pumpWidget(MaterialApp(
        theme: earmarkTheme(Brightness.dark),
        home: Builder(builder: (ctx) => TextButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => PhoneConversationScreen(c: c, id: 1))),
            child: const Text('open')))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('convMenu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Rename'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('renameField')), 'Contract with Sam');
    await t.tap(find.byKey(const Key('renameSave')));
    await t.pumpAndSettle();
    expect(find.text('Contract with Sam'), findsOneWidget);
    expect(convTitle(c, v), 'Contract with Sam');

    await t.tap(find.byKey(const Key('starBtn')));
    await t.pump();
    expect(v.starred, isTrue);

    await t.ensureVisible(find.text('Remind me to call the bank about the card.'));
    await t.longPress(find.text('Remind me to call the bank about the card.'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('lineText')), 'Remind me to call the bank about the new card.');
    await t.tap(find.widgetWithText(ChoiceChip, 'Speaker 2'));
    await t.pump();
    await t.tap(find.byKey(const Key('lineSave')));
    await t.pumpAndSettle();
    final fixed = Conversations.lines(v, heard).last;
    expect((fixed.text, fixed.speaker), ('Remind me to call the bank about the new card.', 'S2'));
    expect(Conversations(File('${dir.path}/c5.json')).byId(1)!.edits, isNotEmpty, reason: 'saved');

    await t.tap(find.byKey(const Key('convMenu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('deleteConfirm')));
    await t.pumpAndSettle();
    expect(c.convs!.byId(1), isNull);
    expect(heard.bySeq(1), isNull, reason: 'its transcript is gone too');
    expect(find.text('open'), findsOneWidget, reason: 'back to the list');
    t.view.resetPhysicalSize();
  });
}
