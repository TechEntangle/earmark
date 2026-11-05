import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_controller.dart';
import 'ui/lists.dart';
import 'ui/now_screen.dart';
import 'ui/pair_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _licences();
  if (Platform.isAndroid) FlutterForegroundTask.initCommunicationPort();
  final c = EarmarkController();
  runApp(EarmarkApp(c: c));
  c.init().then((_) => _keepAliveWhileHolding(c));
}

void _licences() {
  LicenseRegistry.addLicense(() async* {
    for (final (pkg, file) in [('Geist font', 'OFL-Geist.txt'), ('Newsreader font', 'OFL-Newsreader.txt')]) {
      yield LicenseEntryWithLineBreaks([pkg], await rootBundle.loadString('assets/fonts/$file'));
    }
    yield LicenseEntryWithLineBreaks(['Omi (BasedHardware)'], await rootBundle.loadString('assets/OMI_LICENSE.txt'));
  });
}

// ---- Android: a foreground service keeps the app alive while the screen is off, so the
// pendant stays connected and recording continues. (iOS keeps Bluetooth apps running by itself.)
@pragma('vm:entry-point')
void _serviceCallback() => FlutterForegroundTask.setTaskHandler(_Keepalive());

class _Keepalive extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

void _keepAliveWhileHolding(EarmarkController c) {
  if (!Platform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'earmark_recording',
      channelName: 'Recording',
      channelDescription: 'Shown while Earmark holds the pendant',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  var last = '';
  Future<void> sync() async {
    final on = c.holding && c.pairing != null;
    final text = c.paused ? 'Paused' : (c.pendant.connected ? 'Recording' : 'Waiting for the pendant');
    final key = '$on|$text';
    if (key == last) return;
    last = key;
    final running = await FlutterForegroundTask.isRunningService;
    if (on && !running) {
      await FlutterForegroundTask.startService(
        serviceId: 1701,
        notificationTitle: 'Earmark',
        notificationText: text,
        callback: _serviceCallback,
      );
    } else if (on) {
      await FlutterForegroundTask.updateService(notificationTitle: 'Earmark', notificationText: text);
    } else if (!on && running) {
      await FlutterForegroundTask.stopService();
    }
  }

  c.addListener(() => sync());
  sync();
}

class EarmarkApp extends StatelessWidget {
  final EarmarkController c;
  const EarmarkApp({super.key, required this.c});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Earmark',
        debugShowCheckedModeBanner: false,
        theme: earmarkTheme(Brightness.light),
        darkTheme: earmarkTheme(Brightness.dark),
        home: WithForegroundTask(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              if (!c.ready) return const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2)));
              if (c.pairing == null || c.link == Link.unpaired) return PairScreen(c: c);
              return Shell(c: c);
            },
          ),
        ),
      );
}

class Shell extends StatefulWidget {
  final EarmarkController c;
  const Shell({super.key, required this.c});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;
  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final pages = [NowScreen(c: c), TodayScreen(c: c), TasksScreen(c: c), ConversationsScreen(c: c)];
    return Scaffold(
      body: IndexedStack(index: i, children: [for (var k = 0; k < pages.length; k++) k == i || k == 0 ? pages[k] : const SizedBox()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          NavigationDestination(
            icon: Icon(c.pendant.connected && !c.paused ? Icons.graphic_eq : Icons.radio_button_unchecked),
            label: c.paused ? 'Paused' : (c.pendant.connected ? 'Recording' : 'Pendant'),
          ),
          const NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), label: 'Today'),
          const NavigationDestination(icon: Icon(Icons.check_box_outlined), label: 'Tasks'),
          const NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Conversations'),
        ],
      ),
    );
  }
}
