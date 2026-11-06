// Settings, all in one place: pendant, recording, transcription, notes and Ask (on the iPhone or
// with your own key), conversations, voices, storage, your Mac, about.
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../notes/cloud.dart';
import 'pendant_screen.dart';
import 'phone_lists.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  final EarmarkController c;
  const SettingsScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme;
    Widget head(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
          child: Text(s.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w600, color: t.ink3)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 28), children: [
          // ------------------------------------------------------------ pendant
          head('Pendant'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              ListTile(
                key: const Key('pendantRow'),
                title: const Text('Pendant'),
                subtitle: Text(pendantSummary(c), style: tt.bodySmall),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PendantScreen(c: c))),
              ),
              const Divider(),
              SwitchListTile(
                key: const Key('holdSwitch'),
                title: const Text('Hold the pendant'),
                subtitle: Text('This iPhone keeps the pendant connected and records. Turn off to let your Mac have it.', style: tt.bodySmall),
                value: c.holding,
                onChanged: (v) => v ? c.startHolding() : c.letMacHaveIt(),
              ),
              const Divider(),
              ListTile(
                title: const Text('Find the pendant again'),
                subtitle: Text('If you replaced your pendant.', style: tt.bodySmall),
                onTap: () async {
                  await c.forgetPendant();
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Looking for the pendant')));
                },
              ),
            ]),
          ),

          if (c.asrEngine.supported) ...[
            // ------------------------------------------------------------ transcription
            head('Transcription'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  key: const Key('asrSwitch'),
                  title: const Text('Transcribe on this iPhone'),
                  subtitle: Text('Text within seconds, with or without your Mac. English here; other languages are translated by your Mac.',
                      style: tt.bodySmall),
                  value: c.transcribeHere,
                  onChanged: c.setTranscribeHere,
                ),
                if (c.transcribeHere) ...[
                  const Divider(),
                  ListTile(
                    title: const Text('Speech model'),
                    subtitle: Text(switch (c.asr.state) {
                      'ready' => 'Ready · Parakeet, on the Neural Engine',
                      'downloading' => 'Downloading · ${(c.asr.progress * 100).round()}%',
                      'loading' => 'Loading…',
                      'error' => "Didn't load: ${c.asrError ?? c.asr.error ?? ''}",
                      _ => c.asr.onDisk ? 'On this iPhone' : 'Not downloaded yet',
                    }, style: tt.bodySmall),
                    trailing: c.asr.state == 'error' || (!c.asr.ready && !c.asr.busy)
                        ? TextButton(onPressed: c.prepareAsr, child: const Text('Get it'))
                        : null,
                  ),
                  if (c.asr.ready) ...[
                    const Divider(),
                    ListTile(
                      title: const Text('Language check'),
                      subtitle: Text(switch (c.asr.languages?.state) {
                        'ready' => 'Ready · spots speech in other languages and sends it to your Mac to translate',
                        'downloading' => 'Downloading · ${((c.asr.languages?.progress ?? 0) * 100).round()}%',
                        'loading' => 'Loading…',
                        'error' => "Didn't load: ${c.asr.languages?.error ?? ''}",
                        _ => 'Not downloaded yet',
                      }, style: tt.bodySmall),
                      trailing: c.asr.languages?.state == 'error' ? TextButton(onPressed: c.retryLanguages, child: const Text('Try again')) : null,
                    ),
                  ],
                ],
              ]),
            ),

            if (c.transcribeHere) ...[
              // ------------------------------------------------------------ notes and Ask
              head('Notes, tasks and Ask'),
              _AiPanel(c: c),
              const SizedBox(height: 10),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  SwitchListTile(
                    key: const Key('remindersSwitch'),
                    title: const Text('Send my tasks to Reminders'),
                    subtitle: Text(c.remindersError ?? 'A Reminders list called Earmark, with due dates and alerts. Ticking one off there ticks it off here.',
                        style: tt.bodySmall),
                    value: c.remindersOn,
                    onChanged: c.setReminders,
                  ),
                ]),
              ),

              // ------------------------------------------------------------ conversations
              head('Conversations'),
              Panel(child: _GapRow(c: c)),
            ],
          ],

          // ------------------------------------------------------------ voices
          if ((c.voiceBook?.voices ?? const []).isNotEmpty) ...[
            head('Voices'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final (i, v) in c.voiceBook!.voices.indexed) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    dense: true,
                    title: Text(v.name),
                    subtitle: Text('learnt from ${dur(v.weight)} of speech', style: tt.bodySmall),
                    trailing: IconButton(
                      tooltip: 'Forget this voice',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => c.forgetVoice(v.name),
                    ),
                  ),
                ],
              ]),
            ),
          ],

          // ------------------------------------------------------------ storage
          if (c.asrEngine.supported) ...[
            head('Storage'),
            _StoragePanel(c: c),
          ],

          // ------------------------------------------------------------ Mac
          head('Your Mac'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              ListTile(
                title: const Text('Your Mac'),
                subtitle: Text(c.pairing?.server.host ?? 'Not paired', style: tt.bodySmall),
                trailing: Text(c.link == Link.online ? 'Connected' : c.link == Link.offline ? 'Offline' : '',
                    style: TextStyle(color: c.link == Link.online ? t.ok : t.ink3, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const Divider(),
              ListTile(
                title: Text('Disconnect from this Mac', style: TextStyle(color: t.bad)),
                subtitle: Text('Recordings not yet sent stay on this phone until you pair again.', style: tt.bodySmall),
                onTap: () async {
                  final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                            title: const Text('Disconnect from the Mac?'),
                            content: const Text('You will need a new code from the Mac to connect again.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Disconnect')),
                            ],
                          ));
                  if (ok == true) {
                    await c.unpair();
                    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
              ),
            ]),
          ),

          // ------------------------------------------------------------ privacy and about
          head('Privacy'),
          Panel(
            child: Text(
              [
                'Audio never leaves your iPhone and your Mac.',
                if (c.ai.cloud)
                  'Transcript text is sent to ${c.ai.label} to write notes and answer Ask, because you chose it.'
                else
                  'Notes and answers are written on this iPhone.',
                'No accounts, no tracking.',
              ].join(' '),
              style: TextStyle(fontSize: 13.5, height: 1.45, color: t.ink2),
            ),
          ),
          const SizedBox(height: 10),
          Panel(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: const Text('About and licences'),
              subtitle: Text('Earmark $appVersion', style: tt.bodySmall),
              onTap: () => showLicensePage(context: context, applicationName: 'Earmark', applicationVersion: appVersion),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AiPanel extends StatefulWidget {
  final EarmarkController c;
  const _AiPanel({required this.c});
  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  final _key = TextEditingController(), _model = TextEditingController();
  AiProvider? _shown;
  String? _check;
  bool _checking = false;

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c, t = context.t, tt = Theme.of(context).textTheme;
    if (_shown != c.ai) {
      _shown = c.ai;
      _key.text = c.aiKeys[c.ai.name] ?? '';
      _model.text = c.aiModels[c.ai.name] ?? '';
      _check = null;
    }
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<AiProvider>(
          key: const Key('aiProvider'),
          showSelectedIcon: false,
          segments: [for (final p in AiProvider.values) ButtonSegment(value: p, label: Text(p == AiProvider.apple ? 'iPhone' : p.label))],
          selected: {c.ai},
          onSelectionChanged: (v) => c.setAi(v.first),
        ),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(c.ai.cloud ? Icons.cloud_outlined : Icons.lock_outline, size: 15, color: c.ai.cloud ? t.due : t.ok),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              c.ai.cloud
                  ? 'Transcript text (never audio) goes to ${c.ai.label} to write notes and answer Ask. Uses your own key.'
                  : c.notesState == 'available'
                      ? "Apple's on-device model. Nothing leaves this iPhone."
                      : notesHint(c),
              style: tt.bodySmall,
            ),
          ),
        ]),
        if (c.ai.cloud) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('aiKey'),
            controller: _key,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(labelText: '${c.ai.label} API key', hintText: c.ai == AiProvider.openai ? 'sk-…' : 'sk-ant-…'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(labelText: 'Model', hintText: c.ai.defaultModel),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(
              onPressed: _checking ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              child: Text(_checking ? 'Checking…' : 'Save and check'),
            ),
            const SizedBox(width: 12),
            if (_check != null)
              Expanded(
                child: Text(_check!, style: TextStyle(fontSize: 13, color: _check == 'Works' ? t.ok : t.bad)),
              ),
          ]),
        ],
      ]),
    );
  }

  Future<void> _save() async {
    final c = widget.c;
    await c.setAiKey(c.ai, _key.text, model: _model.text);
    setState(() => _checking = true);
    final err = await c.cloud?.check();
    if (mounted) {
      setState(() {
        _checking = false;
        _check = _key.text.trim().isEmpty ? 'Add a key' : (err ?? 'Works');
      });
    }
  }
}

class _GapRow extends StatefulWidget {
  final EarmarkController c;
  const _GapRow({required this.c});
  @override
  State<_GapRow> createState() => _GapRowState();
}

class _GapRowState extends State<_GapRow> {
  double? _v;
  @override
  Widget build(BuildContext context) {
    final c = widget.c, tt = Theme.of(context).textTheme;
    final v = (_v ?? c.gapSeconds).clamp(30, 600).toDouble();
    String fmt(double x) => x < 120 ? '${x.round()} s' : '${(x / 60).round()} min';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('New conversation after a silence of', style: tt.bodyLarge)),
        Text(fmt(v), style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
      Slider(
        key: const Key('gapSlider'),
        value: v,
        min: 30,
        max: 600,
        divisions: 19,
        onChanged: (x) => setState(() => _v = x),
        onChangeEnd: (x) {
          setState(() => _v = null);
          c.setGap(x.round());
        },
      ),
      Row(children: [
        Expanded(
          child: Text(c.gapOverride == null ? "Same as your Mac." : 'Your own setting for this iPhone.', style: tt.bodySmall),
        ),
        if (c.gapOverride != null) TextButton(onPressed: () => c.setGap(null), child: const Text("Use the Mac's")),
      ]),
    ]);
  }
}

class _StoragePanel extends StatelessWidget {
  final EarmarkController c;
  const _StoragePanel({required this.c});

  static String size(int b) => b > 1 << 30
      ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
      : b > 1 << 20
          ? '${(b / (1 << 20)).round()} MB'
          : '${(b / 1024).round()} KB';

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    int dirBytes(Directory? d) {
      if (d == null || !d.existsSync()) return 0;
      try {
        return d.listSync(recursive: true).whereType<File>().fold(0, (a, f) => a + f.lengthSync());
      } catch (_) {
        return 0;
      }
    }

    final audio = c.store?.keptBytes() ?? 0;
    final text = dirBytes(c.heard?.dir) + dirBytes(c.askIndex?.dir);
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(children: [
        ListTile(
          title: const Text('Keep audio for playing back'),
          subtitle: Text('${size(audio)} now. Transcripts and notes are kept either way.', style: tt.bodySmall),
          trailing: DropdownButton<int>(
            key: const Key('keepDays'),
            value: const [7, 30, 90, 365].contains(c.keepDays) ? c.keepDays : 30,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 7, child: Text('1 week')),
              DropdownMenuItem(value: 30, child: Text('30 days')),
              DropdownMenuItem(value: 90, child: Text('90 days')),
              DropdownMenuItem(value: 365, child: Text('1 year')),
            ],
            onChanged: (v) {
              if (v != null) c.setKeepDays(v);
            },
          ),
        ),
        const Divider(),
        ListTile(
          title: const Text('Transcripts, notes and the Ask index'),
          subtitle: Text(size(text), style: tt.bodySmall),
        ),
      ]),
    );
  }
}
