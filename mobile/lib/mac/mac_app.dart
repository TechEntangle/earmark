// Earmark for Mac: a sidebar (status, pause, earmark, sections) and the section on the right.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'engine.dart';
import 'pages/ask_page.dart';
import 'pages/conversations_page.dart';
import 'pages/people_page.dart';
import 'pages/pendant_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';
import 'pages/today_page.dart';
import 'widgets.dart';

enum Section {
  today('Today', Icons.wb_sunny_outlined),
  conversations('Conversations', Icons.forum_outlined),
  tasks('Tasks', Icons.check_circle_outline),
  ask('Ask', Icons.auto_awesome_outlined),
  people('People', Icons.people_outline),
  pendant('Pendant', Icons.radio_button_checked),
  settings('Settings', Icons.tune);

  final String label;
  final IconData icon;
  const Section(this.label, this.icon);
}

class MacApp extends StatelessWidget {
  final MacState s;
  const MacApp({super.key, required this.s});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Earmark',
        debugShowCheckedModeBanner: false,
        theme: earmarkTheme(Brightness.light),
        darkTheme: earmarkTheme(Brightness.dark),
        home: MacShell(s: s),
      );
}

/// Where to go, from anywhere: a section, a conversation (at a moment).
class Nav extends ChangeNotifier {
  Section section = Section.today;
  int? conversation;
  double? at;
  void go(Section s) {
    section = s;
    notifyListeners();
  }

  void open(int id, {double? at}) {
    section = Section.conversations;
    conversation = id;
    this.at = at;
    notifyListeners();
  }
}

class NavScope extends InheritedNotifier<Nav> {
  const NavScope({super.key, required Nav nav, required super.child}) : super(notifier: nav);
  static Nav of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NavScope>()!.notifier!;
}

class MacShell extends StatefulWidget {
  final MacState s;
  const MacShell({super.key, required this.s});
  @override
  State<MacShell> createState() => _MacShellState();
}

class _MacShellState extends State<MacShell> {
  final nav = Nav();

  @override
  void initState() {
    super.initState();
    Native.onMenu((a) {
      if (a == 'settings') nav.go(Section.settings);
      if (a == 'pause') widget.s.refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return NavScope(
      nav: nav,
      child: CallbackShortcuts(
        bindings: {
          for (final (i, sec) in Section.values.indexed)
            SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: true): () => nav.go(sec),
          const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true): () => s.earmark(),
          const SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true): () => s.setPaused(!s.paused),
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => nav.go(Section.ask),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([s, nav]),
              builder: (context, _) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Sidebar(s: s, nav: nav),
                VerticalDivider(width: 1, color: context.t.line),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (s.updateReady) _UpdateBanner(s: s),
                    Expanded(child: _page(s)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(MacState s) => !s.online
                      ? _Offline(s: s)
                      : switch (nav.section) {
                          Section.today => TodayPage(s: s),
                          Section.conversations => ConversationsPage(s: s),
                          Section.tasks => TasksPage(s: s),
                          Section.ask => AskPage(s: s),
                          Section.people => PeoplePage(s: s),
                          Section.pendant => PendantPage(s: s),
                          Section.settings => SettingsPage(s: s),
                        };
}

class _UpdateBanner extends StatelessWidget {
  final MacState s;
  const _UpdateBanner({required this.s});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: const Key('updateBanner'),
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 10),
      color: t.liveSoft,
      child: Row(children: [
        Icon(Icons.system_update_alt, size: 18, color: t.liveInk),
        const SizedBox(width: 10),
        Expanded(child: Text("An update for Earmark's engine is ready.", style: TextStyle(color: t.liveInk, fontWeight: FontWeight.w600))),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
          onPressed: s.updating
              ? null
              : () async {
                  final err = await s.applyUpdate();
                  if (context.mounted) toast(context, err ?? 'Updated. The engine restarted.');
                },
          child: Text(s.updating ? 'Installing…' : 'Install and restart'),
        ),
      ]),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final MacState s;
  final Nav nav;
  const _Sidebar({required this.s, required this.nav});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: 250,
      color: t.sunk,
      padding: const EdgeInsets.fromLTRB(12, 38, 12, 14), // room for the window's traffic lights
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 14),
          child: Text('Earmark', style: TextStyle(fontFamily: 'Newsreader', fontSize: 24, color: t.ink)),
        ),
        _StatusCard(s: s),
        const SizedBox(height: 14),
        for (final sec in Section.values)
          _NavItem(
            key: Key('nav_${sec.name}'),
            section: sec,
            selected: nav.section == sec,
            badge: sec == Section.tasks ? (s.status?['tasks']?['open'] as num?)?.toInt() : null,
            onTap: () => nav.go(sec),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            s.online ? 'Everything stays on this Mac.' : (s.starting ? 'Starting the engine…' : 'Engine not running'),
            style: TextStyle(fontSize: 11.5, color: t.ink3),
          ),
        ),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  final Section section;
  final bool selected;
  final int? badge;
  final VoidCallback onTap;
  const _NavItem({super.key, required this.section, required this.selected, required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? t.liveSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(section.icon, size: 18, color: selected ? t.liveInk : t.ink2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(section.label,
                    style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? t.liveInk : t.ink)),
              ),
              if (badge != null && badge! > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: t.line, borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.ink2)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Pendant state at a glance, with the two things you do most: pause and earmark.
class _StatusCard extends StatelessWidget {
  final MacState s;
  const _StatusCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (label, color) = !s.online
        ? ('Engine not running', t.ink3)
        : s.paused
            ? ('Paused', t.due)
            : s.via != null
                ? ('Recording on ${s.via}', t.ok)
                : s.pendant['connected'] == true
                    ? ('Recording', t.ok)
                    : ('Pendant not nearby', t.ink3);
    final open = (s.status?['open_seconds'] as num?)?.toDouble() ?? 0;
    return Panel(
      key: const Key('statusCard'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Dot(color: color, pulse: !s.paused && s.pendantHere),
          const SizedBox(width: 8),
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
          if (s.battery != null) BatteryChip(pct: s.battery!),
        ]),
        if (s.online && !s.paused && open > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 16),
            child: Text('${clock(open)} in this conversation', style: TextStyle(fontSize: 12, color: t.ink2)),
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('pauseBtn'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: s.online ? () => s.setPaused(!s.paused) : null,
              icon: Icon(s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
              label: Text(s.paused ? 'Resume' : 'Pause', style: const TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('earmarkBtn'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: s.online && !s.paused && s.pendantHere
                  ? () async {
                      final err = await s.earmark();
                      if (context.mounted) toast(context, err ?? 'Earmarked this moment');
                    }
                  : null,
              icon: const Icon(Icons.bookmark_add_outlined, size: 17),
              label: const Text('Earmark', style: TextStyle(fontSize: 13)),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _Offline extends StatelessWidget {
  final MacState s;
  const _Offline({required this.s});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (s.starting) const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5)),
          if (!s.starting) Icon(Icons.power_settings_new, size: 34, color: t.ink3),
          const SizedBox(height: 16),
          Text(s.starting ? 'Starting Earmark…' : "Earmark's engine isn't running",
              style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            s.engineError ??
                'The engine records the pendant, transcribes and writes notes on this Mac. It usually starts with the app.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.ink2),
          ),
          const SizedBox(height: 18),
          if (!s.starting)
            FilledButton(
              onPressed: () async {
                s.starting = true;
                s.changed();
                final r = await Native.ensureEngine();
                s.engineError = r['error'] as String?;
                s.starting = false;
                await s.refresh();
              },
              child: const Text('Start the engine'),
            ),
        ]),
      ),
    );
  }
}
