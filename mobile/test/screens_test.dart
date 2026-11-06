import 'dart:io';

import 'dart:convert';

import 'package:earmark/app_controller.dart';
import 'package:earmark/core/api.dart';
import 'package:earmark/core/config.dart';
import 'package:earmark/pendant/pendant_service.dart';
import 'package:earmark/pendant/prefs.dart';
import 'package:earmark/pendant/protocol.dart';
import 'package:earmark/recorder/chunk_store.dart';
import 'package:earmark/ui/now_screen.dart';
import 'package:earmark/ui/pair_screen.dart';
import 'package:earmark/ui/pendant_screen.dart';
import 'package:earmark/ui/settings_screen.dart';
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
  @override
  Future<String?> aiProvider() async => m['ai'];
  @override
  Future<void> saveAiProvider(String p) async => m['ai'] = p;
  @override
  Future<String> aiKey(String provider) async => m['key_$provider'] ?? '';
  @override
  Future<void> saveAiKey(String provider, String key) async => m['key_$provider'] = key;
  @override
  Future<String> aiModel(String provider) async => m['model_$provider'] ?? '';
  @override
  Future<void> saveAiModel(String provider, String model) async => m['model_$provider'] = model;
  @override
  Future<void> saveGapSeconds(int? s) async => m['gap'] = '$s';
  @override
  Future<void> saveKeepDays(int d) async => m['keep'] = '$d';
  @override
  Future<void> savePendantPrefs(PendantPrefs p, {bool dirty = false}) async {}
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
  final leds = <int>[], mics = <int>[];
  @override
  Future<bool> setLed(int pct) async => (leds..add(pct)).isNotEmpty;
  @override
  Future<bool> setMicGain(int level) async => (mics..add(level)).isNotEmpty;
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
            {'id': 2, 'started_at': now - 1500, 'duration_s': 342, 'status': 'done', 'title': 'Excel add-ins migration and patching plan', 'task_count': 4, 'transcribed_by': 'iphone'},
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
    expect(find.descendant(of: find.byKey(const Key('latest')), matching: find.byIcon(Icons.smartphone)), findsOneWidget);
    expect(find.text('Recording'), findsOneWidget);
    expect(find.byKey(const Key('battery')), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    await expectLater(find.byType(NowScreen), matchesGoldenFile('goldens/home_recording.png'));

    await t.runAsync(c.togglePause);
    c.pausedSince = DateTime(2026, 11, 6, 11, 30); // fixed, for the golden
    await t.pump();
    expect(find.text('Paused'), findsOneWidget);
    expect(find.textContaining('Since 11:30'), findsOneWidget);
    expect(find.text('0:00'), findsNothing, reason: 'no counter while paused');
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

  test('pendant settings: changed on the phone, applied at once, sent to the Mac; the button and buzz obey them', () async {
    final p = FakePendant();
    await p.start();
    final c = controller(p)..paused = false;
    final pushed = <Map>[];
    var macSettings = <String, Object>{'led_brightness': 60, 'mic_gain': -1, 'single_tap_earmark': true,
      'double_tap_pause': true, 'haptics': true, 'session_gap_seconds': 90};
    var macUp = false;
    c.api = Api(Uri.parse('https://mac.tail1234.ts.net'), 'tok', client: MockClient((r) async {
      if (r.url.path == '/api/app/settings') {
        if (!macUp) return http.Response('{}', 503);
        pushed.add(jsonDecode(r.body) as Map);
        macSettings = {...macSettings, ...(pushed.last.cast<String, Object>())};
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      if (r.url.path == '/api/app/heartbeat') {
        return http.Response(jsonEncode({'ok': true, 'paused': false, 'settings': macSettings, 'last_seq': 0}), 200);
      }
      return http.Response('{}', 200);
    }));
    // the Mac's settings arrive with the heartbeat
    await c.heartbeat();
    expect(c.prefs.led, 60);
    expect(p.leds.last, 60);
    // changed here while the Mac is away: applied to the pendant now, the Mac doesn't undo it
    await c.setPrefs(c.prefs.copyWith(led: 20, micGain: 6, haptics: false));
    expect(p.leds.last, 20);
    expect(p.mics.last, 6);
    expect(pushed, isEmpty);
    macSettings = {...macSettings, 'led_brightness': 60};
    macUp = true;
    await c.heartbeat();
    expect(c.prefs.led, 20, reason: 'not yet sent: the phone keeps its change and sends it');
    expect(pushed.last['led_brightness'], 20);
    expect(pushed.last['haptics'], false);
    // changed on the Mac later: the phone follows
    macSettings = {...macSettings, 'led_brightness': 80};
    await c.heartbeat();
    expect(c.prefs.led, 80);
    // vibration off: earmarks are silent
    p.buzzes.clear();
    c.earmarkNow();
    expect(c.earmarks, isNotEmpty);
    expect(p.buzzes, isEmpty);
    // double tap set to nothing: does nothing
    await c.setPrefs(c.prefs.copyWith(doubleTap: ButtonAction.none));
    c.button(ButtonEvent.doubleTap);
    c.button(ButtonEvent.up);
    expect(c.paused, isFalse);
    // press and hold set to earmark: a release with no tap before it
    final n = c.earmarks.length;
    await c.setPrefs(c.prefs.copyWith(hold: ButtonAction.earmark));
    c.button(ButtonEvent.up);
    expect(c.earmarks.length, n + 1);
    expect(pushed.last['hold_action'], 'earmark');
    await c.setPrefs(c.prefs.copyWith(doubleTap: ButtonAction.pause));
    c.button(ButtonEvent.doubleTap);
    await Future<void>.delayed(Duration.zero);
    expect(c.paused, isTrue);
    expect(p.leds.last, 0, reason: 'the light is off while paused');
    c.dispose();
  });

  testWidgets('settings: the pendant page', (t) async {
    t.view.physicalSize = const Size(1179, 5200);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final p = FakePendant()
      ..firmware = '3.0.22'
      ..model = 'Omi CV 1'
      ..manufacturer = 'Based Hardware'
      ..hardware = '5.0'
      ..charging = true
      ..features = decodeFeatures(0x1EC)
      ..clockWasOff = const Duration(seconds: -95)
      ..health = PendantHealth.parse([1, 0, 0, 2, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0])
      ..memory = const RingInfo(10, 10, 9000, 0, 444);
    await p.start();
    final c = controller(p);
    await t.pumpWidget(wrap(SettingsScreen(c: c)));
    expect(find.text('82%, charging · connected to this iPhone'), findsOneWidget);
    await t.tap(find.byKey(const Key('pendantRow')));
    await t.pumpAndSettle();
    expect(find.text('Omi CV 1 by Based Hardware'), findsOneWidget);
    expect(find.text('Was 95 s behind, set right on connect'), findsOneWidget);
    expect(find.text('Good · software restart'), findsOneWidget);
    expect(find.text('button, battery, vibration, own memory, light dimming, microphone level'), findsOneWidget);
    await t.tap(find.descendant(of: find.byKey(const Key('holdAction')), matching: find.text('Pause')));
    await t.pump();
    expect(c.prefs.hold, ButtonAction.pause);
    await t.tap(find.byKey(const Key('hapticsSwitch')));
    await t.pump();
    expect(c.prefs.haptics, isFalse);
    await expectLater(find.byType(PendantScreen), matchesGoldenFile('goldens/pendant.png'));
    c.dispose();
  });

  test('Siri and Shortcuts: earmark at the moment asked, pause, resume, ask', () async {
    final p = FakePendant();
    await p.start();
    final c = controller(p)..paused = false;
    final at = DateTime.now().subtract(const Duration(seconds: 3));
    c.handleIntent({'action': 'earmark', 'at': at.millisecondsSinceEpoch / 1000});
    expect(c.earmarks.last, closeTo(at.millisecondsSinceEpoch / 1000, 0.01));
    c.handleIntent({'action': 'pause'});
    await Future<void>.delayed(Duration.zero);
    expect(c.paused, isTrue);
    c.handleIntent({'action': 'pause'});
    await Future<void>.delayed(Duration.zero);
    expect(c.paused, isTrue, reason: 'pause twice stays paused');
    c.handleIntent({'action': 'resume'});
    await Future<void>.delayed(Duration.zero);
    expect(c.paused, isFalse);
    c.handleIntent({'action': 'ask', 'q': 'What did Sam promise?'});
    expect(c.navRequest.value, 'ask');
    expect(c.pendingQuestion, 'What did Sam promise?');
    c.dispose();
  });
}
