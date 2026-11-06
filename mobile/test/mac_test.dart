// Earmark for Mac: every section renders against the engine's real answers (recorded from the
// engine's test mode into test/mac_fixtures), and the main actions call the right endpoints.
import 'dart:convert';
import 'dart:io';

import 'package:earmark/core/api.dart';
import 'package:earmark/mac/engine.dart';
import 'package:earmark/mac/mac_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'screens_test.dart' show loadFonts;

dynamic fx(String name) => jsonDecode(File('test/mac_fixtures/$name.json').readAsStringSync());

/// The recorded engine, with a few more conversations and people so the pages look lived in.
class FakeEngine {
  final calls = <String>[];
  late final Map<String, dynamic> status = Map<String, dynamic>.from(fx('status'));
  late final List sessions;
  late final Map<String, dynamic> session = Map<String, dynamic>.from(fx('session'));
  Map<String, dynamic> settings = Map<String, dynamic>.from(fx('settings'));

  FakeEngine() {
    final base = Map<String, dynamic>.from((fx('sessions') as List).first as Map);
    final n = DateTime.now();
    final now = DateTime(n.year, n.month, n.day, 12).millisecondsSinceEpoch ~/ 1000; // today at noon: stable goldens
    sessions = [
      {...base, 'started_at': now - 1800, 'ended_at': now - 1200},
      {...base, 'id': 2, 'title': 'Vendor call with Rahul', 'started_at': now - 7200, 'ended_at': now - 6000, 'duration_s': 1200,
        'gist': 'Pricing for the second phase; Rahul to confirm volumes.', 'people': ['Rahul', 'Priya'], 'task_count': 1, 'earmark_count': 1,
        'transcribed_by': 'iphone'},
      {...base, 'id': 3, 'title': 'Standup', 'started_at': now - 90000, 'ended_at': now - 89400, 'duration_s': 600,
        'gist': 'Blocked on the test environment; Sam fixing access today.', 'people': ['Sam'], 'task_count': 0},
    ];
    session['speakers'] = [
      {'label': 'S1', 'seconds': 6.0, 'state': 'confirmed', 'name': null, 'is_me': true},
      {'label': 'S2', 'seconds': 3.0, 'state': 'auto', 'name': 'Rahul', 'is_me': false},
    ];
    session['earmarks'] = [4.5];
  }

  http.Client get client => MockClient((r) async {
        final p = r.url.path;
        calls.add('${r.method} $p${r.url.hasQuery ? '?${r.url.query}' : ''}${r.body.isNotEmpty ? ' ${r.body}' : ''}');
        Object? body = switch ((r.method, p)) {
          ('GET', '/api/status') => status,
          ('GET', '/api/day') => fx('day'),
          ('GET', '/api/sessions') => sessions,
          ('GET', '/api/tasks') => r.url.queryParameters['view'] == 'done' ? fx('tasks_done') : fx('tasks'),
          ('GET', '/api/people') => [
              {'id': 1, 'name': 'me', 'is_me': true, 'seconds': 312.0, 'trained': true, 'conversations': 14},
              {'id': 2, 'name': 'Rahul', 'is_me': false, 'seconds': 95.5, 'trained': true, 'conversations': 4},
              {'id': 3, 'name': 'Priya', 'is_me': false, 'seconds': 41.0, 'trained': true, 'conversations': 2},
            ],
          ('GET', '/api/settings') => settings,
          ('PUT', '/api/settings') => () {
              final cfg = {...(settings['config'] as Map), ...(jsonDecode(r.body) as Map)};
              settings = {...settings, 'config': cfg};
              return {'ok': true, 'config': cfg};
            }(),
          ('GET', '/api/phone') => fx('phone'),
          ('POST', '/api/ask') => fx('ask'),
          ('POST', '/api/earmark') => {'ok': true},
          ('POST', '/api/pause') => () {
              status['paused'] = (jsonDecode(r.body) as Map)['paused'];
              return {'ok': true};
            }(),
          _ when p.startsWith('/api/sessions/') => session,
          _ => {'ok': true},
        };
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      });
}

Widget app(MacState s, {Brightness b = Brightness.light}) => MacApp(s: s);

Future<(MacState, FakeEngine)> start(WidgetTester t) async {
  t.view.physicalSize = const Size(2560, 1640);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final e = FakeEngine();
  final s = MacState(api: Api(Uri.parse('http://127.0.0.1:8765'), null, client: e.client));
  await t.runAsync(() async {
    await s.refresh();
    await s.loadSettings();
  });
  await t.pumpWidget(MacApp(s: s));
  await settle(t);
  return (s, e);
}

/// Let the pages' requests (real futures) finish, then draw.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadFonts);

  testWidgets('Mac: every section renders', (t) async {
    final (s, e) = await start(t);
    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('Pilot launch reviewed; budget held flat'), findsOneWidget);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_today.png'));

    await t.tap(find.byKey(const Key('nav_conversations')));
    await settle(t);
    await settle(t);
    expect(find.byKey(const Key('convTitle')), findsOneWidget);
    expect(find.textContaining('Rahul · '), findsOneWidget);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_conversations.png'));

    await t.tap(find.byKey(const Key('nav_tasks')));
    await settle(t);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_tasks.png'));

    await t.tap(find.byKey(const Key('nav_ask')));
    await settle(t);
    await t.enterText(find.byKey(const Key('askField')), 'When is the vendor contract coming?');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect(find.byKey(const Key('answerText')), findsOneWidget);
    expect(e.calls.where((c) => c.startsWith('POST /api/ask')), isNotEmpty);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_ask.png'));

    await t.tap(find.byKey(const Key('nav_people')));
    await settle(t);
    expect(find.text('Rahul'), findsWidgets);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_people.png'));

    await t.tap(find.byKey(const Key('nav_pendant')));
    await settle(t);
    await t.tap(find.descendant(of: find.byKey(const Key('hold_action')), matching: find.text('Earmark')));
    await settle(t);
    expect(e.calls.any((c) => c.startsWith('PUT /api/settings') && c.contains('"hold_action":"earmark"')), isTrue);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_pendant.png'));

    await t.tap(find.byKey(const Key('nav_settings')));
    await settle(t);
    await expectLater(find.byType(MacShell), matchesGoldenFile('goldens/mac_settings.png'));

    // pause and earmark from the sidebar
    await t.tap(find.byKey(const Key('earmarkBtn')));
    await settle(t);
    expect(e.calls.any((c) => c.startsWith('POST /api/earmark')), isTrue);
    await t.tap(find.byKey(const Key('pauseBtn')));
    await settle(t);
    expect(s.paused, isTrue);
    s.dispose();
  });
}
