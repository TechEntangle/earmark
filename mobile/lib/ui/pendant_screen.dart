// Everything the pendant's firmware lets you see and change: what the button does, vibration,
// light, microphone level, finding it, and what it is (model, firmware, health, memory).
// The settings are the same as on the Mac and kept in step with it.
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../pendant/prefs.dart';
import '../pendant/protocol.dart';
import 'theme.dart';

/// One line for the Settings row.
String pendantSummary(EarmarkController c) {
  final p = c.pendant;
  if (p.connected) {
    return [
      if (p.battery != null) '${p.battery}%${p.charging == true ? ', charging' : ''}',
      'connected to this iPhone',
    ].join(' · ');
  }
  return c.macHasPendant ? 'With your Mac' : 'Not connected';
}

class PendantScreen extends StatelessWidget {
  final EarmarkController c;
  const PendantScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pendant')),
      body: ListenableBuilder(
        listenable: Listenable.merge([c, c.pendant]),
        builder: (context, _) {
          final t = context.t, tt = Theme.of(context).textTheme, p = c.prefs, pd = c.pendant, here = pd.connected;
          Widget head(String s) => Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
                child: Text(s.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w600, color: t.ink3)),
              );
          return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 28), children: [
            if (!here)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    c.macHasPendant
                        ? 'The pendant is with your Mac. Changes here reach it through your Mac.'
                        : 'The pendant is not connected. Changes reach it when it connects.',
                    style: TextStyle(fontSize: 13.5, color: t.ink2)),
              ),
            head('Button'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                _ActionRow(key: const Key('tapAction'), label: 'Single tap', value: p.tap,
                    onChanged: (a) => c.setPrefs(p.copyWith(tap: a))),
                const Divider(),
                _ActionRow(key: const Key('doubleTapAction'), label: 'Double tap', value: p.doubleTap,
                    onChanged: (a) => c.setPrefs(p.copyWith(doubleTap: a))),
                const Divider(),
                _ActionRow(key: const Key('holdAction'), label: 'Press and hold', hint: 'About a second, then let go', value: p.hold,
                    onChanged: (a) => c.setPrefs(p.copyWith(hold: a))),
                const Divider(),
                ListTile(
                  dense: true,
                  title: Text('Pause also resumes. Hold 3 seconds to turn the pendant off; press once to turn it on.',
                      style: TextStyle(fontSize: 13, color: t.ink2)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text('After an earmark, say "remind me to…" and it becomes a task.', style: TextStyle(fontSize: 12.5, color: t.ink3)),
            ),
            head('Feedback'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  key: const Key('hapticsSwitch'),
                  title: const Text('Vibrate to confirm'),
                  subtitle: Text('Medium buzz: earmarked. Long: paused. Three short: recording again.', style: tt.bodySmall),
                  value: p.haptics,
                  onChanged: (v) => c.setPrefs(p.copyWith(haptics: v)),
                ),
                const Divider(),
                _LedSlider(c: c),
                if (here) ...[
                  const Divider(),
                  ListTile(
                    key: const Key('tryBuzz'),
                    leading: const Icon(Icons.vibration),
                    title: const Text('Feel an earmark buzz'),
                    onTap: c.testBuzz,
                  ),
                  const Divider(),
                  _FindRow(c: c),
                ],
              ]),
            ),
            head('Microphone'),
            Panel(
              padding: EdgeInsets.zero,
              child: ListTile(
                title: const Text('Level'),
                subtitle: Text(p.micGain < 0 ? "The pendant's own setting" : 'Higher picks up quieter voices, and more noise.',
                    style: tt.bodySmall),
                trailing: DropdownButton<int>(
                  key: const Key('micGain'),
                  value: p.micGain,
                  underline: const SizedBox(),
                  borderRadius: BorderRadius.circular(12),
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('As is')),
                    for (var i = 0; i <= 8; i++)
                      DropdownMenuItem(value: i, child: Text(i == 0 ? '0 (off)' : i == 8 ? '8 (loudest)' : '$i')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.setPrefs(p.copyWith(micGain: v));
                  },
                ),
              ),
            ),
            if (here) ...[
              head('About this pendant'),
              Panel(child: _About(c: c)),
            ],
          ]);
        },
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final String label;
  final String? hint;
  final ButtonAction value;
  final ValueChanged<ButtonAction> onChanged;
  const _ActionRow({super.key, required this.label, this.hint, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
            if (hint != null) ...[
              const SizedBox(width: 8),
              Expanded(child: Text(hint!, style: Theme.of(context).textTheme.bodySmall)),
            ],
          ]),
          const SizedBox(height: 8),
          SegmentedButton<ButtonAction>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [for (final a in ButtonAction.values) ButtonSegment(value: a, label: Text(a.label))],
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ]),
      );
}

class _LedSlider extends StatefulWidget {
  final EarmarkController c;
  const _LedSlider({required this.c});
  @override
  State<_LedSlider> createState() => _LedSliderState();
}

class _LedSliderState extends State<_LedSlider> {
  double? _dragging;
  @override
  Widget build(BuildContext context) {
    final c = widget.c, tt = Theme.of(context).textTheme;
    final v = _dragging ?? c.prefs.led.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Light brightness', style: tt.bodyLarge)),
          Text(v == 0 ? 'Off' : '${v.round()}%', style: TextStyle(fontWeight: FontWeight.w600, color: context.t.ink2)),
          const SizedBox(width: 8),
        ]),
        Text(c.paused ? 'Off while paused.' : '0% turns it off. While paused it is always off.', style: tt.bodySmall),
        Slider(
          key: const Key('ledSlider'),
          value: v,
          min: 0,
          max: 100,
          divisions: 20,
          onChanged: (x) => setState(() => _dragging = x),
          onChangeEnd: (x) {
            setState(() => _dragging = null);
            c.setPrefs(c.prefs.copyWith(led: x.round()));
          },
        ),
      ]),
    );
  }
}

class _FindRow extends StatefulWidget {
  final EarmarkController c;
  const _FindRow({required this.c});
  @override
  State<_FindRow> createState() => _FindRowState();
}

class _FindRowState extends State<_FindRow> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => ListTile(
        key: const Key('findPendant'),
        leading: const Icon(Icons.wifi_tethering),
        title: Text(_busy ? 'Flashing and buzzing…' : 'Find my pendant'),
        subtitle: Text('Flashes the light and vibrates for ten seconds.', style: Theme.of(context).textTheme.bodySmall),
        onTap: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.c.findPendant();
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
      );
}

class _About extends StatelessWidget {
  final EarmarkController c;
  const _About({required this.c});

  @override
  Widget build(BuildContext context) {
    final pd = c.pendant, t = context.t;
    final rows = <(String, String)>[
      if (pd.battery != null) ('Battery', '${pd.battery}%${pd.charging == null ? '' : pd.charging! ? ', charging' : ', not charging'}'),
      if (pd.model != null || pd.manufacturer != null) ('Model', [pd.model, if (pd.manufacturer != null) 'by ${pd.manufacturer}'].whereType<String>().join(' ')),
      if (pd.firmware != null) ('Firmware', pd.firmware!),
      if (pd.hardware != null) ('Hardware', pd.hardware!),
      if (pd.codec != null) ('Audio', pd.codec == 20 || pd.codec == 21 ? 'Opus, 16 kHz' : 'codec ${pd.codec}'),
      if (pd.clockWasOff != null)
        ('Clock', pd.clockWasOff!.inSeconds.abs() <= 2 ? 'Right' : 'Was ${_off(pd.clockWasOff!)}, set right on connect'),
      if (pd.memory != null)
        ('Own memory', '${dur(Ring.seconds(pd.memory!.capacity))} of audio'
            '${pd.memory!.unread > 0 ? ', ${dur(Ring.seconds(pd.memory!.unread))} waiting' : ', all copied'}'
            '${pd.memory!.dropped > 0 ? '. ${dur(Ring.seconds(pd.memory!.dropped))} lost when it was full' : ''}'),
      if (pd.health != null)
        ('Health', pd.health!.ok
            ? 'Good · ${pd.health!.lastRestart}'
            : 'In recovery mode${pd.health!.latchReason == 1 ? ' after repeated crashes' : ''}. Charge it and update the firmware.'),
      if (pd.features != null) ('Has', pd.features!.join(', ')),
      if (pd.deviceId != null) ('Bluetooth ID', pd.deviceId!),
    ];
    return Column(children: [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 104, child: Text(k, style: TextStyle(fontSize: 13.5, color: t.ink3))),
            Expanded(child: SelectableText(v, style: TextStyle(fontSize: 13.5, color: t.ink))),
          ]),
        ),
    ]);
  }

  static String _off(Duration d) {
    final s = d.inSeconds.abs();
    final amount = s < 120 ? '$s s' : s < 7200 ? '${s ~/ 60} min' : s < 172800 ? '${s ~/ 3600} h' : '${s ~/ 86400} days';
    return d.isNegative ? '$amount behind' : '$amount ahead';
  }
}

Widget pendantHint(BuildContext context, String a, String b) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(a, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.t.ink))),
        Expanded(child: Text(b, style: TextStyle(fontSize: 13.5, color: context.t.ink2))),
      ]),
    );
