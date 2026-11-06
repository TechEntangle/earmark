// Settings: notes and tasks (which model), transcription, conversations, phone, this Mac, activity.
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../widgets.dart';

class SettingsPage extends StatefulWidget {
  final MacState s;
  const SettingsPage({super.key, required this.s});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? login;
  final _keys = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    widget.s.loadSettings();
    Native.loginItem().then((v) {
      if (mounted) setState(() => login = v);
    });
  }

  @override
  void dispose() {
    for (final c in _keys.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctl(String k, Map c) => _keys.putIfAbsent(k, () => TextEditingController(text: '${c[k] ?? ''}'));

  Future<void> _set(Map<String, Object?> ch) async {
    final err = await widget.s.saveSettings(ch);
    if (mounted) toast(context, err ?? 'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s, t = context.t, c = s.settings, tt = Theme.of(context).textTheme;
    if (c == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    final provider = '${c['intel_provider']}';
    final intel = Map<String, dynamic>.from(s.settingsInfo['intel'] as Map? ?? {});
    final local = Map<String, dynamic>.from(s.settingsInfo['local_models'] as Map? ?? {});
    final ollama = [for (final m in (s.settingsInfo['ollama_models'] as List? ?? [])) '$m'];
    Widget field(String k, String label, {bool secret = false, String? hint}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: TextField(
            controller: _ctl(k, c),
            obscureText: secret,
            decoration: InputDecoration(labelText: label, hintText: hint),
            onSubmitted: (v) => _set({k: v.trim()}),
          ),
        );

    return ListView(padding: const EdgeInsets.only(bottom: 48), children: [
      const PageHeader(title: 'Settings'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Readable(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // ---------------------------------------------------------------- notes
            const SectionLabel('Notes, tasks and Ask'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text('Which model writes the notes, picks up tasks, writes the day brief and answers Ask.', style: tt.bodySmall),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: SegmentedButton<String>(
                    key: const Key('provider'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'local', label: Text('On this Mac')),
                      ButtonSegment(value: 'ollama', label: Text('Ollama')),
                      ButtonSegment(value: 'openai', label: Text('OpenAI')),
                      ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
                      ButtonSegment(value: 'off', label: Text('Off')),
                    ],
                    selected: {provider},
                    onSelectionChanged: (v) => _set({'intel_provider': v.first}),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(children: [
                    Icon(provider == 'openai' || provider == 'anthropic' ? Icons.cloud_outlined : Icons.lock_outline,
                        size: 15, color: provider == 'openai' || provider == 'anthropic' ? t.due : t.ok),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        switch (provider) {
                          'openai' => 'Transcripts (text only, never audio) are sent to OpenAI.',
                          'anthropic' => 'Transcripts (text only, never audio) are sent to Anthropic.',
                          'off' => 'Transcripts only: no notes, tasks or answers.',
                          _ => 'Nothing leaves this Mac.',
                        },
                        style: TextStyle(fontSize: 12.5, color: t.ink2),
                      ),
                    ),
                    if (intel['detail'] != null) Text('${intel['detail']}', style: TextStyle(fontSize: 12, color: intel['ready'] == true ? t.ok : t.due)),
                  ]),
                ),
                if (provider == 'local')
                  ListTile(
                    title: const Text('Model'),
                    trailing: DropdownButton<String>(
                      value: local.containsKey(c['local_model']) ? '${c['local_model']}' : null,
                      underline: const SizedBox(),
                      items: [for (final e in local.entries) DropdownMenuItem(value: e.key, child: Text('${e.value}'))],
                      onChanged: (v) => _set({'local_model': v}),
                    ),
                  ),
                if (provider == 'ollama') ...[
                  field('ollama_host', 'Ollama address'),
                  if (ollama.isEmpty)
                    field('ollama_model', 'Model name')
                  else
                    ListTile(
                      title: const Text('Model'),
                      trailing: DropdownButton<String>(
                        value: ollama.contains(c['ollama_model']) ? '${c['ollama_model']}' : null,
                        underline: const SizedBox(),
                        items: [for (final m in ollama) DropdownMenuItem(value: m, child: Text(m))],
                        onChanged: (v) => _set({'ollama_model': v}),
                      ),
                    ),
                ],
                if (provider == 'openai') ...[
                  field('openai_key', 'OpenAI API key', secret: true, hint: 'sk-…  (press Return to save)'),
                  field('openai_model', 'Model'),
                ],
                if (provider == 'anthropic') ...[
                  field('anthropic_key', 'Anthropic API key', secret: true, hint: 'sk-ant-…  (press Return to save)'),
                  field('anthropic_model', 'Model'),
                ],
                const SizedBox(height: 8),
              ]),
            ),

            // ---------------------------------------------------------------- transcription
            const SectionLabel('Transcription'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ListTile(
                  title: const Text('Speech model'),
                  subtitle: Text('Automatic: Parakeet for English, Whisper large for other languages.', style: tt.bodySmall),
                  trailing: DropdownButton<String>(
                    value: '${c['engine']}',
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 'auto', child: Text('Automatic')),
                      DropdownMenuItem(value: 'parakeet-v2', child: Text('Parakeet (English)')),
                      DropdownMenuItem(value: 'parakeet-v3', child: Text('Parakeet v3 (European)')),
                      DropdownMenuItem(value: 'whisper', child: Text('Whisper')),
                    ],
                    onChanged: (v) => _set({'engine': v}),
                  ),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Translate other languages to English'),
                  subtitle: Text('Hindi, Marathi, Urdu, Arabic and the rest become English text. The original isn\'t kept.', style: tt.bodySmall),
                  value: c['translate'] == true,
                  onChanged: (v) => _set({'translate': v}),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Recognise who is speaking'),
                  subtitle: Text('Splits conversations by voice and names people you have named before.', style: tt.bodySmall),
                  value: c['identify_speakers'] == true,
                  onChanged: (v) => _set({'identify_speakers': v}),
                ),
              ]),
            ),

            // ---------------------------------------------------------------- conversations
            const SectionLabel('Conversations'),
            Panel(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('A new conversation starts after a silence of', style: tt.bodyLarge),
                _GapSlider(value: (c['session_gap_seconds'] as num? ?? 90).toDouble(), onDone: (v) => _set({'session_gap_seconds': v.round()})),
                Text('Shorter splits a day into more, smaller conversations.', style: tt.bodySmall),
              ]),
            ),

            // ---------------------------------------------------------------- phone
            const SectionLabel('iPhone'),
            _PhonePanel(s: s),

            // ---------------------------------------------------------------- this Mac
            const SectionLabel('This Mac'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  key: const Key('loginItem'),
                  title: const Text('Open Earmark at login'),
                  subtitle: Text('It sits in the menu bar and keeps the engine running.', style: tt.bodySmall),
                  value: login ?? false,
                  onChanged: login == null
                      ? null
                      : (v) async {
                          final r = await Native.setLoginItem(v);
                          setState(() => login = r['on'] == true);
                          if (r['error'] != null && context.mounted) toast(context, '${r['error']}');
                        },
                ),
                const Divider(),
                ListTile(
                  title: const Text('Where your data is'),
                  subtitle: Text('${(s.settingsInfo['paths'] as Map?)?['home'] ?? '~/Earmark'}', style: tt.bodySmall),
                  trailing: TextButton(
                    onPressed: () => Native.reveal('${(s.settingsInfo['paths'] as Map?)?['notes'] ?? ''}'),
                    child: const Text('Show in Finder'),
                  ),
                ),
                const Divider(),
                ListTile(
                  title: const Text('Restart the engine'),
                  subtitle: Text('If something seems stuck.', style: tt.bodySmall),
                  trailing: OutlinedButton(
                    onPressed: () async {
                      try {
                        await s.api.post('/api/restart');
                      } catch (_) {}
                      if (context.mounted) toast(context, 'Restarting…');
                    },
                    child: const Text('Restart'),
                  ),
                ),
              ]),
            ),

            // ---------------------------------------------------------------- activity
            const SectionLabel('Activity'),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final e in (s.status?['log'] as List? ?? []).reversed.take(14))
                  if (e is Map)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 52, child: Text(hm(e['t'] as num), style: TextStyle(fontSize: 12.5, color: t.ink3))),
                        Expanded(
                          child: Text('${e['msg']}',
                              style: TextStyle(fontSize: 13, color: e['level'] == 'warn' || e['level'] == 'error' ? t.due : t.ink2)),
                        ),
                      ]),
                    ),
              ]),
            ),
            const SizedBox(height: 18),
            Text('Earmark for Mac. Private by design: no accounts, no tracking.', style: tt.bodySmall),
          ]),
        ),
      ),
    ]);
  }
}

class _GapSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onDone;
  const _GapSlider({required this.value, required this.onDone});
  @override
  State<_GapSlider> createState() => _GapSliderState();
}

class _GapSliderState extends State<_GapSlider> {
  double? _v;
  @override
  Widget build(BuildContext context) {
    final v = (_v ?? widget.value).clamp(30, 600).toDouble();
    return Row(children: [
      Expanded(
        child: Slider(
          value: v,
          min: 30,
          max: 600,
          divisions: 19,
          onChanged: (x) => setState(() => _v = x),
          onChangeEnd: (x) {
            setState(() => _v = null);
            widget.onDone(x);
          },
        ),
      ),
      SizedBox(width: 70, child: Text(v < 120 ? '${v.round()} s' : '${(v / 60).toStringAsFixed(v % 60 == 0 ? 0 : 1)} min',
          style: const TextStyle(fontWeight: FontWeight.w600))),
    ]);
  }
}

class _PhonePanel extends StatefulWidget {
  final MacState s;
  const _PhonePanel({required this.s});
  @override
  State<_PhonePanel> createState() => _PhonePanelState();
}

class _PhonePanelState extends State<_PhonePanel> {
  String? code;

  @override
  Widget build(BuildContext context) {
    final s = widget.s, tt = Theme.of(context).textTheme, t = context.t;
    return Load<Map<String, dynamic>>(
      s: s,
      reloadKey: code,
      load: () async => Map<String, dynamic>.from(await s.api.get('/api/phone') as Map),
      builder: (context, p, reload) {
        final ts = Map<String, dynamic>.from(p['tailscale'] as Map? ?? {});
        final devices = [for (final d in (p['devices'] as List? ?? [])) Map<String, dynamic>.from(d as Map)];
        final active = (s.status?['phone']?['active'] as List? ?? []);
        return Panel(
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final d in devices) ...[
              ListTile(
                leading: const Icon(Icons.phone_iphone),
                title: Text('${d['name']}'.replaceFirst('Earmark app on ', '')),
                subtitle: Text(
                    active.any((a) => a is Map && a['device_id'] == d['id']) ? 'Connected now' : d['last_seen'] == null ? 'Paired' : 'Last seen ${dayLabel(d['last_seen'] as num)} ${hm(d['last_seen'] as num)}',
                    style: tt.bodySmall),
                trailing: TextButton(
                  onPressed: () async {
                    await s.api.delete('/api/phone/devices/${d['id']}');
                    await reload();
                  },
                  child: Text('Remove', style: TextStyle(color: t.bad)),
                ),
              ),
              const Divider(),
            ],
            ListTile(
              title: const Text('Pair an iPhone'),
              subtitle: Text(
                  code != null
                      ? 'In the Earmark app on your iPhone, enter this code (valid for 10 minutes).'
                      : ts['url'] != null
                          ? 'Over Tailscale: ${ts['url']}'
                          : 'Your iPhone reaches this Mac through Tailscale or the same Wi-Fi.',
                  style: tt.bodySmall),
              trailing: code != null
                  ? SelectableText(code!, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: 4))
                  : OutlinedButton(
                      key: const Key('pairCode'),
                      onPressed: () async {
                        final r = await s.api.post('/api/phone/code') as Map;
                        setState(() => code = '${r['code']}');
                      },
                      child: const Text('Show a code'),
                    ),
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Also allow the same Wi-Fi'),
              subtitle: Text(p['lan_url'] != null ? 'Address: ${p['lan_url']} (paired phones only)' : 'Paired phones only.', style: tt.bodySmall),
              value: p['lan_access'] == true,
              onChanged: (v) async {
                final r = await s.api.post('/api/phone/lan', {'on': v}) as Map;
                if (r['restart_needed'] == true && context.mounted) toast(context, 'Restart the engine to apply');
                await reload();
              },
            ),
          ]),
        );
      },
    );
  }
}
