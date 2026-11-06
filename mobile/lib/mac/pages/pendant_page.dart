// Pendant: its state, and everything its firmware lets you change (the same settings as on the iPhone).
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../widgets.dart';

class PendantPage extends StatelessWidget {
  final MacState s;
  const PendantPage({super.key, required this.s});

  @override
  Widget build(BuildContext context) {
    final t = context.t, p = s.pendant, c = s.settings;
    Future<void> set(Map<String, Object?> ch) async {
      final err = await s.saveSettings(ch);
      if (err != null && context.mounted) toast(context, err);
    }

    Widget action(String key, String label, String hint) => _Row(
          label: label,
          hint: hint,
          child: SegmentedButton<String>(
            key: Key(key),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'earmark', label: Text('Earmark')),
              ButtonSegment(value: 'pause', label: Text('Pause')),
              ButtonSegment(value: 'none', label: Text('Nothing')),
            ],
            selected: {'${c?[key] ?? 'none'}'},
            onSelectionChanged: (v) => set({key: v.first}),
          ),
        );

    final rows = <(String, String)>[
      ('State', s.via != null ? 'With ${s.via}' : p['connected'] == true ? 'Connected to this Mac' : p['visible'] == true ? 'Nearby' : 'Not nearby'),
      if (s.battery != null) ('Battery', '${s.battery}%'),
      if (p['firmware'] != null) ('Firmware', '${p['firmware']}'),
      if (p['led'] != null) ('Light now', '${p['led']}%'),
      if (p['mic_gain'] != null) ('Microphone level now', '${p['mic_gain']}'),
      if (p['rtc_valid'] != null) ('Clock', p['rtc_valid'] == true ? 'Set' : 'Not set (set on the next connect)'),
      if (p['seen_at'] != null) ('Last seen', '${dayLabel(p['seen_at'] as num)} ${hm(p['seen_at'] as num)}'),
    ];
    return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      PageHeader(
        title: 'Pendant',
        subtitle: 'Changes here also apply when your iPhone holds the pendant.',
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              await s.api.post('/api/sync');
              if (context.mounted) toast(context, 'Looking for the pendant');
            },
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Connect now'),
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Readable(
          child: c == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Panel(
                    child: Column(children: [
                      for (final (k, v) in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            SizedBox(width: 200, child: Text(k, style: TextStyle(color: t.ink3, fontSize: 13.5))),
                            Expanded(child: Text(v, style: const TextStyle(fontSize: 13.5))),
                          ]),
                        ),
                    ]),
                  ),
                  const SectionLabel('Button'),
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      action('tap_action', 'Single tap', 'After an earmark, say “remind me to…” and it becomes a task.'),
                      const Divider(),
                      action('double_tap_action', 'Double tap', 'Pause also resumes.'),
                      const Divider(),
                      action('hold_action', 'Press and hold', 'About a second, then let go. Holding 3 seconds turns it off.'),
                    ]),
                  ),
                  const SectionLabel('Feedback'),
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      SwitchListTile(
                        title: const Text('Vibrate to confirm'),
                        subtitle: Text('Medium buzz: earmarked. Long: paused. Three short: recording again.', style: Theme.of(context).textTheme.bodySmall),
                        value: c['haptics'] == true,
                        onChanged: (v) => set({'haptics': v}),
                      ),
                      const Divider(),
                      _Row(
                        label: 'Light brightness',
                        hint: '0% turns it off. While paused it is always off.',
                        child: SizedBox(
                          width: 300,
                          child: _LiveSlider(
                            value: (c['led_brightness'] as num? ?? 100).toDouble(),
                            max: 100,
                            divisions: 20,
                            label: (v) => v == 0 ? 'Off' : '${v.round()}%',
                            onDone: (v) => set({'led_brightness': v.round()}),
                          ),
                        ),
                      ),
                      const Divider(),
                      _Row(
                        label: 'Microphone level',
                        hint: 'Higher picks up quieter voices, and more noise.',
                        child: DropdownButton<int>(
                          value: (c['mic_gain'] as num? ?? -1).toInt(),
                          underline: const SizedBox(),
                          items: [
                            const DropdownMenuItem(value: -1, child: Text('As is')),
                            for (var i = 0; i <= 8; i++)
                              DropdownMenuItem(value: i, child: Text(i == 0 ? '0 (off)' : i == 8 ? '8 (loudest)' : '$i')),
                          ],
                          onChanged: (v) => set({'mic_gain': v}),
                        ),
                      ),
                    ]),
                  ),
                  const SectionLabel('Connection'),
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      SwitchListTile(
                        title: const Text('Connect automatically'),
                        subtitle: Text('Whenever the pendant is near this Mac and your iPhone doesn\'t have it.', style: Theme.of(context).textTheme.bodySmall),
                        value: c['auto_sync'] == true,
                        onChanged: (v) => set({'auto_sync': v}),
                      ),
                      const Divider(),
                      SwitchListTile(
                        title: const Text('Stay connected'),
                        subtitle: Text('Record live while in range. Off: collect what the pendant stored every few minutes (saves its battery).',
                            style: Theme.of(context).textTheme.bodySmall),
                        value: c['stay_connected'] == true,
                        onChanged: (v) => set({'stay_connected': v, 'poll_seconds': v ? 20 : 300}),
                      ),
                      const Divider(),
                      SwitchListTile(
                        title: const Text('Skip recordings with no speech'),
                        subtitle: Text('Coughs, a glass on the table or room noise are deleted instead of transcribed.', style: Theme.of(context).textTheme.bodySmall),
                        value: (c['min_speech_seconds'] as num? ?? 0) > 0,
                        onChanged: (v) => set({'min_speech_seconds': v ? 3 : 0}),
                      ),
                    ]),
                  ),
                ]),
        ),
      ),
    ]);
  }
}

class _Row extends StatelessWidget {
  final String label, hint;
  final Widget child;
  const _Row({required this.label, required this.hint, required this.child});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodyLarge),
              Text(hint, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          const SizedBox(width: 16),
          child,
        ]),
      );
}

class _LiveSlider extends StatefulWidget {
  final double value, max;
  final int divisions;
  final String Function(double) label;
  final ValueChanged<double> onDone;
  const _LiveSlider({required this.value, required this.max, required this.divisions, required this.label, required this.onDone});
  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  double? _v;
  @override
  Widget build(BuildContext context) {
    final v = _v ?? widget.value;
    return Row(children: [
      Expanded(
        child: Slider(
          value: v,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (x) => setState(() => _v = x),
          onChangeEnd: (x) {
            setState(() => _v = null);
            widget.onDone(x);
          },
        ),
      ),
      SizedBox(width: 44, child: Text(widget.label(v), style: const TextStyle(fontWeight: FontWeight.w600))),
    ]);
  }
}
