import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../pendant/pendant_service.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The pendant, recording, and the link to the Mac, at a glance.
class NowScreen extends StatefulWidget {
  final EarmarkController c;
  const NowScreen({super.key, required this.c});
  @override
  State<NowScreen> createState() => _NowScreenState();
}

class _NowScreenState extends State<NowScreen> {
  Timer? _tick;
  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Listenable.merge([widget.c, widget.c.pendant]), builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final c = widget.c, p = c.pendant, t = context.t, tt = Theme.of(context).textTheme;
    final (label, sub, color, pulse) = _state(c, t);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Earmark'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(c: c))),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: c.heartbeat,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Panel(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _Dot(color: color, pulse: pulse),
                const SizedBox(width: 10),
                Text(label, key: const Key('stateLabel'), style: tt.titleLarge),
                const Spacer(),
                if (p.battery != null) _Battery(pct: p.battery!),
              ]),
              const SizedBox(height: 6),
              Text(sub, style: tt.bodyMedium?.copyWith(color: t.ink2)),
              if (p.connected && !c.paused) ...[
                const SizedBox(height: 14),
                Text(clock(c.store?.openSeconds ?? 0),
                    style: TextStyle(fontFamily: 'Geist', fontSize: 40, fontWeight: FontWeight.w500, color: t.ink,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                Text('in this stretch of recording', style: tt.bodySmall),
              ],
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('pauseBtn'),
                    onPressed: c.togglePause,
                    style: c.paused ? FilledButton.styleFrom(backgroundColor: t.live, foregroundColor: Colors.white) : FilledButton.styleFrom(backgroundColor: t.ink, foregroundColor: t.bg),
                    icon: Icon(c.paused ? Icons.fiber_manual_record : Icons.pause),
                    label: Text(c.paused ? 'Resume' : 'Pause'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('earmarkBtn'),
                    onPressed: c.paused ? null : () {
                      c.earmarkNow();
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Earmarked this moment')));
                    },
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Earmark'),
                  ),
                ),
              ]),
              if (!p.connected && c.holding && c.macHasPendant) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('takeBtn'),
                  onPressed: c.takeFromMac,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Take the pendant from the Mac'),
                ),
              ],
              if (c.lastEarmark != null) ...[
                const SizedBox(height: 10),
                Text('Last earmark ${DateFormat.Hm().format(c.lastEarmark!)}', style: tt.bodySmall),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          _MacCard(c: c),
          const SizedBox(height: 14),
          Panel(
            color: t.sunk,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On the pendant', style: tt.labelLarge),
              const SizedBox(height: 8),
              _hint(context, 'Single tap', 'Earmark this moment. Say what to remember right after: "remind me to…"'),
              _hint(context, 'Double tap', 'Pause or resume recording'),
              _hint(context, 'Vibrations', 'three short = recording, one long = paused, one medium = earmarked'),
              _hint(context, 'Hold 3 s', 'Power off (press to turn back on)'),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _hint(BuildContext context, String a, String b) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 92, child: Text(a, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.t.ink))),
          Expanded(child: Text(b, style: TextStyle(fontSize: 13.5, color: context.t.ink2))),
        ]),
      );

  (String, String, Color, bool) _state(EarmarkController c, Tokens t) {
    final p = c.pendant;
    if (!c.holding) return ('Mac has the pendant', 'This phone is not recording. Turn on "Hold the pendant" in Settings to take it back.', t.ink3, false);
    switch (p.state) {
      case PendantState.connected:
        return c.paused
            ? ('Paused', 'Nothing is being recorded. Double-tap the pendant or press Resume.', t.due, false)
            : ('Recording', 'Audio is saved on this phone and sent to your Mac.', t.live, true);
      case PendantState.connecting:
        return c.macHasPendant
            ? ('Mac has the pendant', 'Your Mac is recording. Take it over here, or it moves to this phone by itself when you leave the Mac.', t.ink3, false)
            : ('Connecting', 'Waiting for the pendant. While it is away it records to its own memory.', t.ink3, true);
      case PendantState.searching:
        return ('Looking for the pendant', 'Keep it close and switched on. Quit the Omi app if it is open.', t.ink3, true);
      case PendantState.bluetoothOff:
        return ('Bluetooth is off', 'Turn on Bluetooth to connect to the pendant.', t.bad, false);
      case PendantState.needsPermission:
        return ('Allow Bluetooth', 'Earmark needs Bluetooth permission to reach the pendant. Allow it in Settings.', t.bad, false);
      case PendantState.idle:
        return ('Not connected', 'Pair with your Mac to start.', t.ink3, false);
    }
  }
}

class _MacCard extends StatelessWidget {
  final EarmarkController c;
  const _MacCard({required this.c});
  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme;
    final q = c.queuedSeconds;
    final (title, body, color) = switch (c.link) {
      Link.online => ('Mac connected',
          q > 2 ? 'Sending ${dur(q)} of recording…' : (c.lastUpload != null ? 'Everything sent. Last at ${DateFormat.Hm().format(c.lastUpload!)}.' : 'Up to date.'),
          t.ok),
      Link.offline => ('Mac not reachable',
          'Recordings are kept safely on this phone${q > 2 ? ' (${dur(q)} waiting)' : ''} and sent when the Mac is back. Check Tailscale and that the Mac is awake.',
          t.due),
      Link.unpaired => ('Not paired', c.linkError ?? 'Pair with Earmark on your Mac.', t.bad),
      Link.unknown => ('Checking the Mac…', '', t.ink3),
    };
    return Panel(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 3), child: Icon(Icons.laptop_mac, size: 20, color: color)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, key: const Key('macState'), style: tt.labelLarge),
            if (body.isNotEmpty) ...[const SizedBox(height: 3), Text(body, style: tt.bodySmall)],
          ]),
        ),
      ]),
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final bool pulse;
  const _Dot({required this.color, required this.pulse});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  @override
  void initState() {
    super.initState();
    if (widget.pulse) a.repeat();
  }

  @override
  void didUpdateWidget(covariant _Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !a.isAnimating) a.repeat();
    if (!widget.pulse && a.isAnimating) a.stop();
  }

  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 14, height: 14,
        child: AnimatedBuilder(
          animation: a,
          builder: (_, _) => Stack(alignment: Alignment.center, children: [
            if (widget.pulse)
              Container(
                width: 14 * (1 + a.value * .9), height: 14 * (1 + a.value * .9),
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withValues(alpha: .35 * (1 - a.value))),
              ),
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
          ]),
        ),
      );
}

class _Battery extends StatelessWidget {
  final int pct;
  const _Battery({required this.pct});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = pct <= 15 ? t.bad : t.ink2;
    return Row(children: [
      Icon(pct > 80 ? Icons.battery_full : pct > 50 ? Icons.battery_5_bar : pct > 25 ? Icons.battery_3_bar : Icons.battery_1_bar,
          size: 18, color: color),
      const SizedBox(width: 3),
      Text('$pct%', style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500)),
    ]);
  }
}
