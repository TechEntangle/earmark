// People: the voices Earmark knows. Rename or forget one; see their conversations and what's open with them.
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../widgets.dart';
import 'today_page.dart';

class PeoplePage extends StatefulWidget {
  final MacState s;
  const PeoplePage({super.key, required this.s});
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  Map<String, dynamic>? chosen;

  @override
  Widget build(BuildContext context) {
    final s = widget.s, t = context.t;
    return Load<List<Map<String, dynamic>>>(
      s: s,
      load: () async => [for (final x in (await s.api.get('/api/people') as List)) Map<String, dynamic>.from(x as Map)],
      builder: (context, people, reload) => ListView(padding: const EdgeInsets.only(bottom: 40), children: [
        const PageHeader(
            title: 'People', subtitle: 'Voices Earmark recognises. Name a speaker in any conversation to add them.'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Readable(
            child: people.isEmpty
                ? Text('No voices yet. Open a conversation and click a speaker under “Who spoke” to name them.',
                    style: TextStyle(color: t.ink2))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Panel(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        for (final (i, p) in people.indexed) ...[
                          if (i > 0) const Divider(),
                          ListTile(
                            key: Key('person_${p['id']}'),
                            selected: chosen?['id'] == p['id'],
                            selectedTileColor: t.liveSoft,
                            leading: Avatar(p['is_me'] == true ? 'Me' : '${p['name']}', size: 32),
                            title: Text(p['is_me'] == true ? 'Me' : '${p['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                '${p['conversations'] ?? 0} conversation${p['conversations'] == 1 ? '' : 's'} · voice learnt from ${dur((p['seconds'] as num?) ?? 0)}',
                                style: Theme.of(context).textTheme.bodySmall),
                            onTap: () => setState(() => chosen = chosen?['id'] == p['id'] ? null : p),
                            trailing: PopupMenuButton<String>(
                              onSelected: (a) async {
                                if (a == 'rename') {
                                  final ctl = TextEditingController(text: '${p['name']}');
                                  final n = await showDialog<String>(
                                    context: context,
                                    builder: (d) => AlertDialog(
                                      title: const Text('Rename'),
                                      content: SizedBox(width: 360, child: TextField(controller: ctl, autofocus: true, onSubmitted: (x) => Navigator.pop(d, x))),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                                        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Save')),
                                      ],
                                    ),
                                  );
                                  if (n != null && n.trim().isNotEmpty) {
                                    await s.api.patch('/api/people/${p['id']}', {'name': n.trim()});
                                    await reload();
                                  }
                                } else if (a == 'forget') {
                                  await s.api.delete('/api/people/${p['id']}');
                                  setState(() => chosen = null);
                                  await reload();
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'rename', child: Text('Rename')),
                                PopupMenuItem(value: 'forget', child: Text('Forget this voice')),
                              ],
                            ),
                          ),
                        ],
                      ]),
                    ),
                    if (chosen != null) _PersonDetail(s: s, p: chosen!),
                  ]),
          ),
        ),
      ]),
    );
  }
}

class _PersonDetail extends StatelessWidget {
  final MacState s;
  final Map<String, dynamic> p;
  const _PersonDetail({required this.s, required this.p});

  @override
  Widget build(BuildContext context) {
    final name = p['is_me'] == true ? 'me' : '${p['name']}';
    return Load<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)>(
      s: s,
      reloadKey: p['id'],
      load: () async {
        final sessions = [for (final x in (await s.api.get('/api/sessions', {'limit': '600'}) as List)) Map<String, dynamic>.from(x as Map)];
        final mine = sessions.where((x) => (x['people'] as List? ?? []).map((e) => '$e'.toLowerCase()).contains(name.toLowerCase()) ||
            (x['speakers'] as List? ?? []).map((e) => '$e'.toLowerCase()).contains(name.toLowerCase())).toList();
        final tasks = [for (final x in (await s.api.get('/api/tasks', {'view': 'open'}) as List)) Map<String, dynamic>.from(x as Map)]
            .where((k) => '${k['owner']}'.toLowerCase() == name.toLowerCase())
            .toList();
        return (mine, tasks);
      },
      builder: (context, d, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (d.$2.isNotEmpty) ...[
          SectionLabel('Waiting on ${p['name']}'),
          for (final k in d.$2) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• ${k['text']}')),
        ],
        SectionLabel('Conversations with ${p['is_me'] == true ? 'you' : p['name']}'),
        if (d.$1.isEmpty) Text('None found.', style: TextStyle(color: context.t.ink2)),
        for (final x in d.$1.take(20)) SessionCard(x: x),
      ]),
    );
  }
}
