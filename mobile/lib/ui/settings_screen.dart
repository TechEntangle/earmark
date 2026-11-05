import 'package:flutter/material.dart';

import '../app_controller.dart';
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
              ListTile(
                title: const Text('Pendant'),
                subtitle: Text([
                  if (c.pendant.firmware != null) 'Firmware ${c.pendant.firmware}',
                  if (c.pendant.codec != null) 'codec ${c.pendant.codec}',
                  if (c.pendant.lastError != null) 'last error: ${c.pendant.lastError}',
                ].join(' · '), style: tt.bodySmall),
              ),
              const Divider(),
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
