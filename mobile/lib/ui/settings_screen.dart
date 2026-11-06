import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'phone_lists.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  final EarmarkController c;
  const SettingsScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              SwitchListTile(
                key: const Key('holdSwitch'),
                title: const Text('Hold the pendant'),
                subtitle: Text('This phone keeps the pendant connected and records. Turn off to let your Mac have it.',
                    style: tt.bodySmall),
                value: c.holding,
                onChanged: (v) => v ? c.startHolding() : c.letMacHaveIt(),
              ),
              const Divider(),
              ListTile(
                title: const Text('Find the pendant again'),
                subtitle: Text('Use this if you replaced your pendant.', style: tt.bodySmall),
                onTap: () async {
                  await c.forgetPendant();
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Looking for the pendant')));
                },
              ),
            ]),
          ),
          const SizedBox(height: 14),
          PendantPanel(c: c),
          if (c.asrEngine.supported) ...[
            const SizedBox(height: 14),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(children: [
                SwitchListTile(
                  key: const Key('asrSwitch'),
                  title: const Text('Transcribe on this iPhone'),
                  subtitle: Text(
                      'Text appears here within seconds, with or without your Mac. Uses a 480 MB speech model that stays on the phone.',
                      style: tt.bodySmall),
                  value: c.transcribeHere,
                  onChanged: c.setTranscribeHere,
                ),
                if (c.transcribeHere) ...[
                  const Divider(),
                  SwitchListTile(
                    key: const Key('remindersSwitch'),
                    title: const Text('Send my tasks to Reminders'),
                    subtitle: Text(c.remindersError ?? 'Your tasks appear in a Reminders list called Earmark, with due dates and alerts. Ticking one off there ticks it off here.',
                        style: tt.bodySmall),
                    value: c.remindersOn,
                    onChanged: c.setReminders,
                  ),
                  const Divider(),
                  ListTile(
                    title: const Text('Notes and tasks'),
                    subtitle: Text(c.notesState == 'available'
                        ? "Written on this iPhone by Apple's on-device model"
                        : notesHint(c), style: tt.bodySmall),
                  ),
                  const Divider(),
                  ListTile(
                    title: const Text('Speech model'),
                    subtitle: Text(switch (c.asr.state) {
                      'ready' => 'Ready · Parakeet (English), on the Neural Engine',
                      'downloading' => 'Downloading · ${(c.asr.progress * 100).round()}%',
                      'loading' => 'Loading…',
                      'error' => "Didn't load: ${c.asrError ?? c.asr.error ?? ''}",
                      _ => c.asr.onDisk ? 'On this phone' : 'Not downloaded yet',
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
                        'ready' => 'Ready · English is transcribed here; other languages are translated by your Mac',
                        'downloading' => 'Downloading · ${((c.asr.languages?.progress ?? 0) * 100).round()}%',
                        'loading' => 'Loading…',
                        'error' => "Didn't load: ${c.asr.languages?.error ?? ''}",
                        _ => 'Not downloaded yet',
                      }, style: tt.bodySmall),
                      trailing: c.asr.languages?.state == 'error'
                          ? TextButton(onPressed: c.retryLanguages, child: const Text('Try again'))
                          : null,
                    ),
                  ],
                ],
              ]),
            ),
          ],
          const SizedBox(height: 14),
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
                  final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
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
          const SizedBox(height: 14),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              if ((c.voiceBook?.voices ?? const []).isNotEmpty) ...[
                ExpansionTile(
                  key: const Key('voices'),
                  title: const Text('Voices'),
                  subtitle: Text('${c.voiceBook!.voices.length} known on this iPhone', style: tt.bodySmall),
                  shape: const Border(),
                  children: [
                    for (final v in c.voiceBook!.voices)
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
                ),
                const Divider(),
              ],
              ListTile(
                title: const Text('About and licences'),
                subtitle: Text('Earmark $appVersion. Private by design: no accounts, no tracking, no cloud.', style: tt.bodySmall),
                onTap: () => showLicensePage(context: context, applicationName: 'Earmark', applicationVersion: appVersion),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

Widget pendantHint(BuildContext context, String a, String b) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 92, child: Text(a, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.t.ink))),
        Expanded(child: Text(b, style: TextStyle(fontSize: 13.5, color: context.t.ink2))),
      ]),
    );

/// The pendant itself: its light, microphone, what the button does and whether it vibrates.
/// The same settings as on the Mac; changing them here changes them there too.
class PendantPanel extends StatelessWidget {
  final EarmarkController c;
  const PendantPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme, p = c.prefs, here = c.pendant.connected;
    final about = [
      if (c.pendant.battery != null) 'Battery ${c.pendant.battery}%',
      if (c.pendant.firmware != null) 'firmware ${c.pendant.firmware}',
    ];
    return Panel(
      key: const Key('pendantPanel'),
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          title: const Text('Pendant'),
          subtitle: Text(
              here
                  ? about.join(' · ')
                  : c.macHasPendant
                      ? 'With your Mac. Changes here reach it through your Mac.'
                      : 'Not connected. Changes reach it when it connects.',
              style: tt.bodySmall),
        ),
        const Divider(),
        SwitchListTile(
          key: const Key('singleTapSwitch'),
          title: const Text('Single tap to earmark'),
          subtitle: Text('Tap once to mark a moment as important. Say "remind me to…" after the tap and it becomes a task.',
              style: tt.bodySmall),
          value: p.singleTapEarmark,
          onChanged: (v) => c.setPrefs(p.copyWith(singleTapEarmark: v)),
        ),
        SwitchListTile(
          key: const Key('doubleTapSwitch'),
          title: const Text('Double tap to pause'),
          subtitle: Text('Double tap to stop recording; the light turns off. Double tap again to resume.', style: tt.bodySmall),
          value: p.doubleTapPause,
          onChanged: (v) => c.setPrefs(p.copyWith(doubleTapPause: v)),
        ),
        SwitchListTile(
          key: const Key('hapticsSwitch'),
          title: const Text('Vibrate to confirm'),
          subtitle: Text('One medium buzz for an earmark, one long when paused, three short when recording again.',
              style: tt.bodySmall),
          value: p.haptics,
          onChanged: (v) => c.setPrefs(p.copyWith(haptics: v)),
        ),
        const Divider(),
        _LedSlider(c: c),
        const Divider(),
        ListTile(
          title: const Text('Microphone level'),
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
        const Divider(),
        ExpansionTile(
          key: const Key('pendantHelp'),
          title: const Text('Button and vibrations'),
          shape: const Border(),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            pendantHint(context, 'Single tap', p.singleTapEarmark ? 'Earmark this moment' : 'Does nothing (turned off)'),
            pendantHint(context, 'Double tap', p.doubleTapPause ? 'Pause or resume recording' : 'Does nothing (turned off)'),
            pendantHint(context, 'Vibrations', p.haptics ? 'three short = recording, one long = paused, one medium = earmarked' : 'Off'),
            pendantHint(context, 'Hold 3 s', 'Power off (press to turn back on)'),
            if (here)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('tryBuzz'),
                  onPressed: c.testBuzz,
                  icon: const Icon(Icons.vibration, size: 18),
                  label: const Text('Feel an earmark buzz'),
                ),
              ),
          ],
        ),
        if (c.pendant.lastError != null && !here)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Last problem: ${c.pendant.lastError}', style: TextStyle(fontSize: 12.5, color: t.ink3)),
          ),
      ]),
    );
  }
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
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Light brightness', style: tt.bodyLarge)),
          Text(v == 0 ? 'Off' : '${v.round()}%', style: TextStyle(fontWeight: FontWeight.w600, color: context.t.ink2)),
          const SizedBox(width: 8),
        ]),
        Text(c.paused ? 'Off while paused.' : '0% turns the light off. While paused it is always off.', style: tt.bodySmall),
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
