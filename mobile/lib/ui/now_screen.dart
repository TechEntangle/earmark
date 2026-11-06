import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../pendant/pendant_service.dart';
import 'lists.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// Home: is it recording, is the chain healthy, the one action needed now, and what came out.
class NowScreen extends StatefulWidget {
  final EarmarkController c;
  const NowScreen({super.key, required this.c});
  @override
  State<NowScreen> createState() => _NowScreenState();
}

enum Home { recording, paused, onMac, moving, looking, bluetoothOff, needsPermission }

Home homeState(EarmarkController c) {
  final p = c.pendant;
  if (c.takingOver) return Home.moving;
  if (p.connected) return c.paused ? Home.paused : Home.recording;
  if (!c.holding || c.macHasPendant) return Home.onMac;
  if (p.state == PendantState.bluetoothOff) return Home.bluetoothOff;
  if (p.state == PendantState.needsPermission) return Home.needsPermission;
  return Home.looking;
}

class _NowScreenState extends State<NowScreen> {
  Timer? _tick;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    widget.c.refreshStatus();
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
    final c = widget.c, t = context.t, tt = Theme.of(context).textTheme;
    final b = c.battery;
    return Scaffold(
      appBar: AppBar(
        title: Text('Earmark', style: tt.headlineMedium),
        centerTitle: false,
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12), child: StatusChain(c: c, onTap: () => showDetails(context, c))),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() => _gen++);
          await c.heartbeat();
          await c.refreshStatus();
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          _Hero(c: c),
          if (b != null && b <= 20) ...[
            const SizedBox(height: 14),
            Container(
              key: const Key('lowBattery'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(color: t.badSoft, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(Icons.battery_alert, size: 20, color: t.bad),
                const SizedBox(width: 12),
                Expanded(child: Text('Pendant at $b%. Charge it soon.', style: TextStyle(fontSize: 14, color: t.bad))),
              ]),
            ),
          ],
          const SizedBox(height: 28),
          Row(children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('LATEST', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: t.ink2)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConversationsScreen(c: c))),
              child: const Text('All'),
            ),
          ]),
          _Latest(key: const ValueKey('latestList'), c: c, gen: _gen),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ the hero card
class _Hero extends StatelessWidget {
  final EarmarkController c;
  const _Hero({required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = homeState(c);
    final children = switch (s) {
      Home.recording => [
          _title(context, 'Recording', dot: t.live, pulse: true),
          _timer(context, c.store?.openSeconds ?? 0),
          _sub(context, _sendLine(c), color: c.link == Link.offline ? t.due : null),
          _pair(context, _pauseBtn(context), _earmarkBtn(context)),
        ],
      Home.paused => [
          _title(context, 'Paused', dot: t.due),
          if (c.pausedSince != null) _timer(context, DateTime.now().difference(c.pausedSince!).inSeconds, dim: true),
          _sub(context, 'Nothing is recorded'),
          _pair(context, _resumeBtn(context), _earmarkBtn(context, enabled: false)),
        ],
      Home.onMac => [
          _title(context, c.macPaused ? 'Paused on Mac' : 'Recording on Mac', icon: Icons.laptop_mac),
          if (!c.macPaused && c.macHasPendant) _timer(context, c.macOpenSeconds),
          _sub(context, c.takeoverFailed
              ? "Couldn't reach the pendant. Keep it close and try again."
              : (c.macHasPendant ? 'Leaving the desk? Move it to this iPhone.' : 'Waiting for the Mac to find the pendant.'),
              color: c.takeoverFailed ? t.due : null),
          const SizedBox(height: 20),
          _big(context, key: const Key('takeBtn'), label: 'Use this iPhone', icon: Icons.smartphone, bg: t.live, fg: Colors.white,
              onPressed: c.takeFromMac),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _small(context, key: const Key('pauseBtn'), label: c.paused ? 'Resume' : 'Pause',
                icon: c.paused ? Icons.fiber_manual_record : Icons.pause, onPressed: c.togglePause)),
            const SizedBox(width: 10),
            Expanded(child: _small(context, key: const Key('earmarkBtn'), label: 'Earmark', icon: Icons.bookmark_border,
                onPressed: c.paused ? null : () => _earmark(context))),
          ]),
        ],
      Home.moving => [
          _title(context, 'Moving to iPhone', icon: Icons.swap_horiz),
          const SizedBox(height: 18),
          _step(context, 'Mac let go', !c.macHasPendant ? _Step.done : _Step.now),
          _step(context, 'Connecting to the pendant', c.macHasPendant ? _Step.later : (c.pendant.connected ? _Step.done : _Step.now)),
          _step(context, 'Recording on iPhone', c.pendant.connected ? _Step.done : _Step.later),
          const SizedBox(height: 16),
          _sub(context, 'Keep the pendant near the phone. Nothing is lost meanwhile: it records to its own memory.'),
          const SizedBox(height: 16),
          _small(context, key: const Key('cancelTake'), label: 'Cancel', onPressed: c.cancelTakeover),
        ],
      Home.looking => [
          _title(context, c.pendant.catchingUp ? 'Copying from the pendant' : 'Looking for the pendant', dot: t.ink3, pulse: true),
          const SizedBox(height: 6),
          _sub(context, c.takeoverFailed ? "Couldn't reach the pendant. Is it on and close by?" : 'Keep it close and switched on.',
              color: c.takeoverFailed ? t.due : null),
          const SizedBox(height: 20),
          _small(context, key: const Key('retryBtn'), label: 'Try again', icon: Icons.refresh, onPressed: c.pendant.reconnectNow),
        ],
      Home.bluetoothOff => [
          _title(context, 'Bluetooth is off', dot: t.bad),
          const SizedBox(height: 6),
          _sub(context, 'Turn it on in Control Centre to reach the pendant.'),
        ],
      Home.needsPermission => [
          _title(context, 'Allow Bluetooth', dot: t.bad),
          const SizedBox(height: 6),
          _sub(context, 'Settings → Earmark → Bluetooth.'),
        ],
    };
    return Container(
      key: Key('hero_${s.name}'),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  static String _sendLine(EarmarkController c) {
    final q = c.queuedSeconds;
    return switch (c.link) {
      Link.offline => 'Mac not reachable${q > 2 ? ' · ${dur(q)} kept on iPhone' : ''}',
      Link.online => q > 40 ? 'Sending ${dur(q)} to your Mac' : 'All sent to your Mac',
      _ => 'Checking the Mac…',
    };
  }

  void _earmark(BuildContext context) {
    c.earmarkNow();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Earmarked'), duration: Duration(seconds: 2)));
  }

  Widget _title(BuildContext context, String text, {Color? dot, bool pulse = false, IconData? icon}) => Row(children: [
        if (dot != null) PulseDot(color: dot, pulse: pulse),
        if (icon != null) Icon(icon, size: 22, color: context.t.live),
        const SizedBox(width: 10),
        Flexible(child: Text(text, key: const Key('stateLabel'), style: const TextStyle(fontFamily: 'Newsreader', fontSize: 28, height: 1.2))),
      ]);

  Widget _timer(BuildContext context, num seconds, {bool dim = false}) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: FittedBox(
          alignment: Alignment.centerLeft,
          fit: BoxFit.scaleDown,
          child: Text(clock(seconds),
              style: TextStyle(fontFamily: 'Geist', fontSize: 64, height: 1.1, letterSpacing: -1, fontWeight: FontWeight.w500,
                  color: dim ? context.t.ink3 : context.t.ink, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      );

  Widget _sub(BuildContext context, String text, {Color? color}) =>
      Text(text, style: TextStyle(fontSize: 14, height: 1.4, color: color ?? context.t.ink2));

  Widget _pair(BuildContext context, Widget a, Widget b) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Row(children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]),
      );

  Widget _pauseBtn(BuildContext context) => _big(context, key: const Key('pauseBtn'), label: 'Pause', icon: Icons.pause,
      bg: context.t.ink, fg: context.t.bg, onPressed: c.togglePause);
  Widget _resumeBtn(BuildContext context) => _big(context, key: const Key('pauseBtn'), label: 'Resume', icon: Icons.fiber_manual_record,
      bg: context.t.live, fg: Colors.white, onPressed: c.togglePause);
  Widget _earmarkBtn(BuildContext context, {bool enabled = true}) => SizedBox(
        height: 56,
        child: OutlinedButton.icon(
          key: const Key('earmarkBtn'),
          onPressed: enabled ? () => _earmark(context) : null,
          style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              side: BorderSide(color: context.t.line2), textStyle: const TextStyle(fontFamily: 'Geist', fontSize: 16, fontWeight: FontWeight.w600)),
          icon: const Icon(Icons.bookmark_border, size: 20),
          label: const Text('Earmark'),
        ),
      );

  Widget _big(BuildContext context, {Key? key, required String label, required IconData icon, required Color bg, required Color fg,
          required VoidCallback onPressed}) =>
      SizedBox(
        height: 56,
        child: FilledButton.icon(
          key: key,
          onPressed: onPressed,
          style: FilledButton.styleFrom(backgroundColor: bg, foregroundColor: fg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: const TextStyle(fontFamily: 'Geist', fontSize: 16, fontWeight: FontWeight.w600)),
          icon: Icon(icon, size: 20),
          label: Text(label),
        ),
      );

  Widget _small(BuildContext context, {Key? key, required String label, IconData? icon, VoidCallback? onPressed}) => SizedBox(
        height: 48,
        child: OutlinedButton(
          key: key,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              side: BorderSide(color: context.t.line2), textStyle: const TextStyle(fontFamily: 'Geist', fontSize: 15, fontWeight: FontWeight.w600)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ]),
        ),
      );

  Widget _step(BuildContext context, String text, _Step s) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        SizedBox(
          width: 22, height: 22,
          child: switch (s) {
            _Step.done => Icon(Icons.check_circle_outline, size: 22, color: t.ok),
            _Step.now => Padding(padding: const EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2.2, color: t.live)),
            _Step.later => Icon(Icons.radio_button_unchecked, size: 22, color: t.line2),
          },
        ),
        const SizedBox(width: 12),
        Text(text, style: TextStyle(fontSize: 16, fontWeight: s == _Step.now ? FontWeight.w600 : FontWeight.w400,
            color: s == _Step.later ? t.ink2 : t.ink)),
      ]),
    );
  }
}

enum _Step { done, now, later }

// ------------------------------------------------------------------ the status chain
/// Pendant + battery, then whoever holds it, then the other device. Solid green = connected,
/// dashed = not (blue while moving, amber when the Mac can't be reached).
class StatusChain extends StatelessWidget {
  final EarmarkController c;
  final VoidCallback onTap;
  const StatusChain({super.key, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.t, p = c.pendant;
    final onMac = !p.connected && (c.macHasPendant || !c.holding) && !c.takingOver;
    final b = c.battery;
    final held = p.connected || (onMac && c.macHasPendant);
    final bColor = b == null ? t.ink2 : (b <= 15 ? t.bad : (b <= 25 ? t.due : t.ink));
    final pendantLink = held ? _Link(t.ok) : (c.takingOver ? _Link(t.live, dashed: true) : _Link(t.line2, dashed: true));
    final macLink = switch (c.link) {
      Link.online => _Link(t.ok),
      Link.offline => _Link(t.due, dashed: true),
      _ => _Link(t.line2, dashed: true),
    };
    final phone = Icon(Icons.smartphone, size: 20, color: onMac ? t.ink2 : t.ink);
    final mac = Icon(Icons.laptop_mac, size: 20, color: c.link == Link.offline ? t.due : t.ink);
    final label = [
      'Pendant${b != null ? ' at $b%' : ''}',
      held ? (p.connected ? 'on this iPhone' : 'on the Mac') : 'not connected',
      c.link == Link.online ? 'Mac connected' : 'Mac not reachable',
    ].join(', ');
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: t.surface,
        shape: StadiumBorder(side: BorderSide(color: t.line)),
        child: InkWell(
          key: const Key('statusChain'),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ExcludeSemantics(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.radio_button_checked, size: 20, color: held ? bColor : t.ink2),
                if (b != null) ...[
                  const SizedBox(width: 4),
                  Text('$b%', key: const Key('battery'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: bColor,
                      fontFeatures: const [FontFeature.tabularFigures()])),
                ],
                pendantLink,
                if (onMac) ...[mac, macLink, phone] else ...[phone, macLink, mac],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Link extends StatelessWidget {
  final Color color;
  final bool dashed;
  const _Link(this.color, {this.dashed = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          width: 16, height: 2,
          child: dashed
              ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [for (var i = 0; i < 3; i++) Container(width: 4, height: 2, color: color)])
              : DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1))),
        ),
      );
}

// ------------------------------------------------------------------ connections sheet
void showDetails(BuildContext context, EarmarkController c) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: context.t.surface,
      builder: (_) => _Details(c: c),
    );

class _Details extends StatelessWidget {
  final EarmarkController c;
  const _Details({required this.c});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([c, c.pendant]),
      builder: (context, _) {
        final t = context.t, p = c.pendant, b = c.battery;
        final holder = p.connected ? 'On this iPhone' : (c.macHasPendant ? 'On your Mac' : (c.takingOver ? 'Moving to this iPhone' : 'Not connected'));
        final sent = c.lastUpload != null ? 'last sent ${DateFormat.Hm().format(c.lastUpload!)}' : null;
        final macLine = switch (c.link) {
          Link.online => ['Connected', ?sent].join(' · '),
          Link.offline => 'Not reachable. Check Tailscale and that the Mac is awake.',
          _ => 'Checking…',
        };
        final busy = c.transcribing;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Connections', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              _row(context, Icons.radio_button_checked, p.connected || c.macHasPendant ? t.ok : t.ink2, 'Pendant',
                  [[holder, if (b != null) '$b%'].join(' · '), if (p.firmware != null) 'Firmware ${p.firmware}']),
              Divider(color: t.line, height: 1),
              _row(context, Icons.laptop_mac, c.link == Link.online ? t.ok : t.due, 'Mac', [
                macLine,
                if (c.queuedSeconds > 2) '${dur(c.queuedSeconds)} waiting on this iPhone',
                if (busy > 0) 'Transcribing $busy conversation${busy == 1 ? '' : 's'}',
              ]),
              const SizedBox(height: 14),
              if (p.connected)
                OutlinedButton.icon(
                  key: const Key('giveToMac'),
                  onPressed: () {
                    c.letMacHaveIt();
                    Navigator.pop(context);
                  },
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), side: BorderSide(color: t.line2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  icon: const Icon(Icons.laptop_mac, size: 18),
                  label: const Text('Give the pendant to the Mac'),
                )
              else if (!c.takingOver)
                FilledButton.icon(
                  onPressed: () {
                    c.takeFromMac();
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: t.live, foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  icon: const Icon(Icons.smartphone, size: 18),
                  label: const Text('Use this iPhone'),
                ),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                  childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  title: const Text('Pendant buttons', style: TextStyle(fontSize: 15)),
                  children: [
                    pendantHint(context, 'Single tap', 'Earmark this moment, then say "remind me to…"'),
                    pendantHint(context, 'Double tap', 'Pause or resume'),
                    pendantHint(context, 'Hold 3 s', 'Power off'),
                    pendantHint(context, 'Vibrations', 'three short = recording, one long = paused, one medium = earmarked'),
                  ],
                ),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: const Text('Settings', style: TextStyle(fontSize: 15)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(c: c)));
                },
              ),
            ]),
          ),
        );
      });

  Widget _row(BuildContext context, IconData icon, Color color, String title, List<String> lines) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              for (final l in lines)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text(l, style: TextStyle(fontSize: 14, color: context.t.ink2))),
            ]),
          ),
        ]),
      );
}

// ------------------------------------------------------------------ latest conversations
/// The three most recent conversations, refreshed every minute, after each upload and on pull-down.
class _Latest extends StatefulWidget {
  final EarmarkController c;
  final int gen;
  const _Latest({super.key, required this.c, required this.gen});
  @override
  State<_Latest> createState() => _LatestState();
}

class _LatestState extends State<_Latest> {
  List<Map>? _rows;
  Timer? _t;
  DateTime? _seenUpload;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 60), (_) => _load());
    widget.c.addListener(_onController);
  }

  void _onController() {
    if (widget.c.lastUpload != _seenUpload) {
      _seenUpload = widget.c.lastUpload;
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant _Latest old) {
    super.didUpdateWidget(old);
    if (old.gen != widget.gen) _load();
  }

  @override
  void dispose() {
    _t?.cancel();
    widget.c.removeListener(_onController);
    super.dispose();
  }

  Future<void> _load() async {
    final api = widget.c.api;
    if (api == null) return;
    try {
      final all = (await api.sessions()).cast<Map>();
      if (mounted) setState(() => _rows = all.take(3).toList());
    } catch (_) {/* keep what we had; the chain already shows the link state */}
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t, rows = _rows;
    if (rows == null) return const SizedBox(height: 56);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Text('Conversations show up here once your Mac has them.', style: TextStyle(fontSize: 14, color: t.ink2)),
      );
    }
    return Container(
      key: const Key('latest'),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.line),
          _row(context, rows[i]),
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, Map s) {
    final t = context.t;
    final pending = s['status'] != 'done';
    final tasks = (s['task_count'] as num?)?.toInt() ?? 0;
    final at = DateTime.fromMillisecondsSinceEpoch(((s['started_at'] as num) * 1000).round());
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConversationScreen(c: widget.c, id: s['id'] as int))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            SizedBox(width: 48, child: Text(DateFormat.Hm().format(at),
                style: TextStyle(fontSize: 13, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()]))),
            Expanded(
              child: Text(pending ? 'Transcribing…' : '${s['title'] ?? 'Conversation'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Newsreader', fontSize: 17, color: pending ? t.ink2 : t.ink,
                      fontStyle: pending ? FontStyle.italic : FontStyle.normal)),
            ),
            if (tasks > 0) ...[
              const SizedBox(width: 10),
              Text('$tasks task${tasks == 1 ? '' : 's'}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.liveInk)),
            ],
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ bits
class PulseDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  const PulseDot({super.key, required this.color, required this.pulse});
  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  @override
  void initState() {
    super.initState();
    if (widget.pulse) a.repeat();
  }

  @override
  void didUpdateWidget(covariant PulseDot old) {
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
        width: 22, height: 22,
        child: AnimatedBuilder(
          animation: a,
          builder: (_, _) => Stack(alignment: Alignment.center, children: [
            if (widget.pulse)
              Container(
                width: 12 * (1 + a.value * .8), height: 12 * (1 + a.value * .8),
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withValues(alpha: .35 * (1 - a.value))),
              ),
            Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
          ]),
        ),
      );
}
