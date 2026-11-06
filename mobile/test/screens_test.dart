import 'dart:io';

import 'dart:convert';

import 'package:earmark/app_controller.dart';
import 'package:earmark/core/api.dart';
import 'package:earmark/core/config.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:earmark/ui/now_screen.dart';
import 'package:earmark/ui/pair_screen.dart';
import 'package:earmark/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Settings kept in memory instead of the Keychain.
class FakeConfig extends ConfigStore {
  final m = <String, String>{};
  @override
  Future<bool> paused() async => m['paused'] == '1';
  @override
  Future<void> savePaused(bool p) async => m['paused'] = p ? '1' : '0';
  @override
  Future<String?> pendantId() async => m['pendant'];
  @override
  Future<void> savePendantId(String? id) async => id == null ? m.remove('pendant') : m['pendant'] = id;
  @override
  Future<DateTime?> lastHeld() async => m['held'] == null ? null : DateTime.parse(m['held']!);
  @override
  Future<void> saveLastHeld(DateTime t) async => m['held'] = t.toIso8601String();
}

/// A pendant that is "connected" without Bluetooth.
class FakePendant extends PendantService {
  FakePendant() : super();
  final List<List<(int, int)>> buzzes = [];
  @override
  Future<void> start({String? rememberedId}) async {
    state = PendantState.connected;
    battery = 82;
    notifyListeners();
  }

  @override
  Future<void> buzz(List<(int, int)> pattern) async => buzzes.add(pattern);
  @override
  Future<bool> setLed(int pct) async => true;
  int reconnects = 0;
  @override
  void reconnectNow() => reconnects++;
}

Future<void> loadFonts() async {
  for (final (fam, files) in [
    ('Geist', ['Geist_400Regular', 'Geist_500Medium', 'Geist_600SemiBold']),
    ('Newsreader', ['Newsreader_400Regular', 'Newsreader_500Medium']),
    ('MaterialIcons', <String>[]),
  ]) {
    final l = FontLoader(fam);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
    }
    if (fam == 'MaterialIcons') {
      final icons = File('${Platform.environment['FLUTTER_ROOT'] ?? '/home/claude/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (icons.existsSync()) l.addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    }
    await l.load();
  }
}

Widget wrap(Widget w, {Brightness b = Brightness.light}) =>
    MaterialApp(debugShowCheckedModeBanner: false, theme: earmarkTheme(b), home: w);

EarmarkController controller(FakePendant p) {
  final c = EarmarkController(config: FakeConfig(), pendant: p);
  c.store = ChunkStore(Directory.systemTemp.createTempSync('earmark_ui'));
  c.pairing = Pairing(Uri.parse('https://mac.tail1234.ts.net'), 'tok');
  return c;
}

void main() {
  setUpAll(loadFonts);

  testWidgets('pairing screen asks for address and code', (t) async {
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final c = controller(FakePendant());
    await t.pumpWidget(wrap(PairScreen(c: c)));
    expect(find.text('Connect to your Mac'), findsOneWidget);
    expect(find.text('6-digit code'), findsOneWidget);
    await expectLater(find.byType(PairScreen), matchesGoldenFile('goldens/pair.png'));
  });

  testWidgets('home: recording, paused, offline, on the Mac, moving, connections', (t) async {
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    final p = FakePendant();
    final c = controller(p)..link = Link.online;
    final now = DateTime(2026, 11, 6, 11, 30).millisecondsSinceEpoch / 1000;
    var macHas = false;
    c.api = Api(Uri.parse('https://mac.tail1234.ts.net'), 'tok', client: MockClient((r) async {
      switch (r.url.path) {
        case '/api/sessions':
          return http.Response(jsonEncode([
            {'id': 3, 'started_at': now - 120, 'duration_s': 95, 'status': 'queued', 'source': 'phone'},
            {'id': 2, 'started_at': now - 1500, 'duration_s': 342, 'status': 'done', 'title': 'Excel add-ins migration and patching plan', 'task_count': 4},
            {'id': 1, 'started_at': now - 4000, 'duration_s': 600, 'status': 'done', 'title': 'Security incident response', 'task_count': 3},
            {'id': 0, 'started_at': now - 9000, 'duration_s': 60, 'status': 'done', 'title': 'Older'},
          ]), 200, headers: {'content-type': 'application/json'});
        case '/api/status':
          return http.Response(jsonEncode({'paused': false, 'open_seconds': 2530, 'pendant': {'battery': 82},
              'tasks': {'open': 7}, 'counts': {'done': 40, 'queued': 1}}), 200);
        case '/api/app/heartbeat':
          return http.Response(jsonEncode({'ok': true, 'paused': false, 'settings': {}, 'last_seq': 0, 'mac_has_pendant': macHas}), 200);
      }
      return http.Response('{}', 200);
    }));
    await p.start();
    Future<void> settle() async {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
    }

    await t.runAsync(() async => t.pumpWidget(wrap(NowScreen(c: c), b: Brightness.dark)));
    await settle();
    expect(find.text('Excel add-ins migration and patching plan'), findsOneWidget);
    expect(find.text('Older'), findsNothing, reason: 'only the latest three');
    expect(find.text('Recording'), findsOneWidget);
    expect(find.byKey(const Key('battery')), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_recording.png'));

    await t.runAsync(c.togglePause);
    await t.pump();
    expect(find.text('Paused'), findsOneWidget);
    expect(p.buzzes.last.single.$1, 3, reason: 'one long vibration = paused');
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_paused.png'));

    await t.runAsync(c.togglePause);
    p.battery = 14;
    c.link = Link.offline;
    p.notifyListeners();
    await t.pump();
    expect(find.textContaining('Mac not reachable'), findsOneWidget);
    expect(find.byKey(const Key('lowBattery')), findsOneWidget);
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_offline_low.png'));

    // the Mac has the pendant: the big action is "Use this iPhone"
    p.battery = null;
    p.state = PendantState.connecting;
    c.link = Link.online;
    c.macHasPendant = macHas = true;
    await t.runAsync(c.refreshStatus);
    await t.pump();
    expect(find.text('Recording on Mac'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget, reason: "the Mac's pendant battery");
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_on_mac.png'));

    macHas = false; // the Mac lets go as soon as it hears the claim
    await t.tap(find.byKey(const Key('takeBtn')));
    await settle();
    expect(find.text('Moving to iPhone'), findsOneWidget);
    expect(p.reconnects, greaterThanOrEqualTo(1));
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_moving.png'));
    c.cancelTakeover();
    await settle();

    await t.tap(find.byKey(const Key('statusChain')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Connections'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/home_connections.png'));
    t.view.resetPhysicalSize();
  });

  test('frames are recorded only while not paused', () async {
    final p = FakePendant();
    final c = controller(p);
    c.paused = false;
    // feed through the same path the pendant uses
    for (var k = 0; k < 5; k++) {
      c.store!.add(Uint8List.fromList([1, 2, 3]));
    }
    expect(c.store!.openSeconds, closeTo(0.1, 1e-9));
  });

  test('take over: claims the pendant at once, goes for it, and stops claiming once it is here', () async {
    final p = FakePendant()..state = PendantState.connecting;
    final c = controller(p)..holding = true;
    final sent = <Map>[];
    var macHas = true;
    c.api = Api(Uri.parse('https://mac.tail1234.ts.net'), 'tok', client: MockClient((r) async {
      if (r.url.path == '/api/app/heartbeat') {
        sent.add(jsonDecode(r.body) as Map);
        final reply = {'ok': true, 'paused': false, 'settings': {}, 'last_seq': 0, 'mac_has_pendant': macHas};
        macHas = false; // the Mac lets go as soon as it hears the claim
        return http.Response(jsonEncode(reply), 200);
      }
      return http.Response('{}', 200);
    }));
    await c.takeFromMac();
    expect(sent.first['wants_pendant'], isTrue);
    expect(c.takingOver, isTrue);
    expect(p.reconnects, greaterThanOrEqualTo(1), reason: 'no waiting out the retry back-off');
    p.state = PendantState.connected;
    c.pendant.notifyListeners();
    await c.heartbeat();
    expect(sent.last['wants_pendant'], isFalse);
    expect(sent.last['holds_pendant'], isTrue);
    c.dispose();
  });
}
