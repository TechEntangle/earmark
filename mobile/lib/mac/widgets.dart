// Small pieces shared by the Mac app's pages.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ui/theme.dart';
import 'engine.dart';

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), width: 360, duration: const Duration(seconds: 2)));

DateTime epoch(num s) => DateTime.fromMillisecondsSinceEpoch((s * 1000).round());
String hm(num s) => DateFormat('HH:mm').format(epoch(s));
String dayLabel(num s) {
  final d = epoch(s), now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day), that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat('EEEE').format(d);
  return DateFormat(d.year == now.year ? 'EEE d MMM' : 'd MMM yyyy').format(d);
}

String mmss(num s) {
  final t = s.round();
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

class Dot extends StatelessWidget {
  final Color color;
  final bool pulse;
  const Dot({super.key, required this.color, this.pulse = false});
  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: pulse ? [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 0, spreadRadius: 3)] : null,
        ),
      );
}

class BatteryChip extends StatelessWidget {
  final int pct;
  final bool charging;
  const BatteryChip({super.key, required this.pct, this.charging = false});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final c = pct <= 15 ? t.bad : (pct <= 30 ? t.due : t.ink2);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(charging ? Icons.battery_charging_full : (pct > 60 ? Icons.battery_full : pct > 25 ? Icons.battery_4_bar : Icons.battery_1_bar),
          size: 15, color: c),
      Text('$pct%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
    ]);
  }
}

/// A page's title row.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 30, 28, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: TextStyle(fontSize: 13.5, color: context.t.ink2)),
              ],
            ]),
          ),
          ...actions,
        ]),
      );
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 11.5, letterSpacing: .7, fontWeight: FontWeight.w600, color: context.t.ink3)),
      );
}

class Chip2 extends StatelessWidget {
  final String text;
  final Color? color, bg;
  const Chip2(this.text, {super.key, this.color, this.bg});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: bg ?? context.t.sunk, borderRadius: BorderRadius.circular(6), border: Border.all(color: context.t.line)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: color ?? context.t.ink2)),
      );
}

/// Loads something from the engine; reloads when [MacState.revision] changes or [reloadKey] does.
class Load<T> extends StatefulWidget {
  final MacState s;
  final Future<T> Function() load;
  final Widget Function(BuildContext, T, Future<void> Function() reload) builder;
  final Object? reloadKey;
  const Load({super.key, required this.s, required this.load, required this.builder, this.reloadKey});
  @override
  State<Load<T>> createState() => _LoadState<T>();
}

class _LoadState<T> extends State<Load<T>> {
  T? _data;
  String? _error;
  int _rev = -1;
  Object? _key;

  Future<void> _reload() async {
    try {
      final d = await widget.load();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void initState() {
    super.initState();
    widget.s.addListener(_maybe);
    _rev = widget.s.revision;
    _key = widget.reloadKey;
    _reload();
  }

  @override
  void didUpdateWidget(covariant Load<T> old) {
    super.didUpdateWidget(old);
    if (widget.reloadKey != _key) {
      _key = widget.reloadKey;
      _reload();
    }
  }

  void _maybe() {
    if (widget.s.revision != _rev) {
      _rev = widget.s.revision;
      _reload();
    }
  }

  @override
  void dispose() {
    widget.s.removeListener(_maybe);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) {
      return Center(
        child: _error != null
            ? Text(_error!, style: TextStyle(color: context.t.bad))
            : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return widget.builder(context, _data as T, _reload);
  }
}

/// A two-letter avatar in a colour picked from the name.
class Avatar extends StatelessWidget {
  final String name;
  final double size;
  const Avatar(this.name, {super.key, this.size = 26});
  static const _colors = [Color(0xFF5B8DEF), Color(0xFF2FA37A), Color(0xFFD08A2E), Color(0xFFB5598F), Color(0xFF7A6BD9), Color(0xFF3B9BB5)];
  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final init = parts.isEmpty || parts.first.isEmpty ? '?' : (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
    final c = _colors[name.hashCode.abs() % _colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: .16), shape: BoxShape.circle),
      child: Text(init, style: TextStyle(fontSize: size * .4, fontWeight: FontWeight.w700, color: c)),
    );
  }
}

/// The content column of a page, centred with a readable width.
class Readable extends StatelessWidget {
  final Widget child;
  final double max;
  const Readable({super.key, required this.child, this.max = 860});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: max), child: child),
      );
}
