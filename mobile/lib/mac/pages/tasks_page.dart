// Tasks: mine, what I'm waiting on from others, and done. Tick off, add, edit, jump to where it was said.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../mac_app.dart';
import '../widgets.dart';

class TasksPage extends StatefulWidget {
  final MacState s;
  const TasksPage({super.key, required this.s});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String view = 'mine'; // mine | others | done
  final _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _create(Future<void> Function() reload) async {
    final text = _add.text.trim();
    if (text.isEmpty) return;
    // "for Sam: send the deck" → owner Sam
    final m = RegExp(r'^(?:for|@)\s*([A-Z][\w-]*)\s*[:,-]\s*(.+)$').firstMatch(text);
    await widget.s.api.post('/api/tasks', {'text': m?[2] ?? text, 'owner': m?[1] ?? 'me'});
    _add.clear();
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s, t = context.t;
    return Load<List<Map<String, dynamic>>>(
      s: s,
      reloadKey: view,
      load: () async => [
        for (final x in (await s.api.get('/api/tasks', {'view': view == 'done' ? 'done' : 'open'}) as List))
          Map<String, dynamic>.from(x as Map),
      ],
      builder: (context, all, reload) {
        final list = switch (view) {
          'mine' => all.where((k) => (k['owner'] ?? 'me') == 'me').toList(),
          'others' => all.where((k) => (k['owner'] ?? 'me') != 'me').toList(),
          _ => all,
        };
        final looksDone = list.where((k) => (k['suggested_done'] ?? 0) == 1).length;
        return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          PageHeader(
            title: 'Tasks',
            subtitle: 'From your conversations, and ones you add.',
            actions: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'mine', label: Text('Mine')),
                  ButtonSegment(value: 'others', label: Text('Waiting on others')),
                  ButtonSegment(value: 'done', label: Text('Done')),
                ],
                selected: {view},
                onSelectionChanged: (v) => setState(() => view = v.first),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Readable(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (view != 'done')
                  TextField(
                    key: const Key('addTask'),
                    controller: _add,
                    onSubmitted: (_) => _create(reload),
                    decoration: InputDecoration(
                      hintText: view == 'mine' ? 'Add a task and press Return' : 'For Sam: send the deck',
                      prefixIcon: const Icon(Icons.add, size: 20),
                    ),
                  ),
                if (looksDone > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('$looksDone look${looksDone == 1 ? 's' : ''} done from what was said later. Confirm below.',
                        style: TextStyle(fontSize: 13, color: t.ok)),
                  ),
                const SizedBox(height: 14),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 30),
                    child: Text(
                        switch (view) {
                          'mine' => 'Nothing on your list. Say "remind me to…" after an earmark, or add one above.',
                          'others' => "Nobody owes you anything right now.",
                          _ => 'Nothing done yet.',
                        },
                        style: TextStyle(color: t.ink2)),
                  )
                else
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (final (i, k) in list.indexed) ...[
                        if (i > 0) const Divider(),
                        TaskTile(s: s, task: k, onChanged: reload),
                      ],
                    ]),
                  ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

class TaskTile extends StatefulWidget {
  final MacState s;
  final Map<String, dynamic> task;
  final Future<void> Function() onChanged;
  const TaskTile({super.key, required this.s, required this.task, required this.onChanged});
  @override
  State<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<TaskTile> {
  bool? _done;

  Future<void> _set(String status) async {
    setState(() => _done = status == 'done');
    try {
      await widget.s.api.patch('/api/tasks/${widget.task['id']}', {'status': status});
    } catch (_) {}
    await widget.onChanged();
    widget.s.changed();
  }

  Future<void> _edit() async {
    final k = widget.task;
    final text = TextEditingController(text: '${k['text']}');
    final owner = TextEditingController(text: '${k['owner'] ?? 'me'}');
    DateTime? due = DateTime.tryParse('${k['due'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Edit task'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: text, autofocus: true, decoration: const InputDecoration(labelText: 'Task')),
              const SizedBox(height: 10),
              TextField(controller: owner, decoration: const InputDecoration(labelText: 'Who ("me" for you)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text(due == null ? 'No due date' : 'Due ${DateFormat('EEE d MMM').format(due!)}')),
                TextButton(
                  onPressed: () async {
                    final p = await showDatePicker(
                        context: d, initialDate: due ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
                    if (p != null) set(() => due = p);
                  },
                  child: const Text('Pick date'),
                ),
                if (due != null) TextButton(onPressed: () => set(() => due = null), child: const Text('Clear')),
              ]),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await widget.s.api.delete('/api/tasks/${k['id']}');
                if (d.mounted) Navigator.pop(d, true);
              },
              child: Text('Delete', style: TextStyle(color: context.t.bad)),
            ),
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.s.api.patch('/api/tasks/${k['id']}', {
          'text': text.text.trim(),
          'owner': owner.text.trim().isEmpty ? 'me' : owner.text.trim(),
          'due': due == null ? null : DateFormat('yyyy-MM-dd').format(due!),
        });
      } catch (_) {}
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t, k = widget.task;
    final done = _done ?? k['status'] == 'done';
    final due = DateTime.tryParse('${k['due'] ?? ''}');
    final today = DateTime.now();
    final overdue = !done && due != null && due.isBefore(DateTime(today.year, today.month, today.day));
    final mine = (k['owner'] ?? 'me') == 'me';
    final looksDone = (k['suggested_done'] ?? 0) == 1 && !done;
    return InkWell(
      onTap: _edit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Checkbox(value: done, onChanged: (v) => _set(v == true ? 'done' : 'open')),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${k['text']}',
                    style: TextStyle(fontSize: 14.5, decoration: done ? TextDecoration.lineThrough : null, color: done ? t.ink3 : t.ink)),
                const SizedBox(height: 3),
                Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (!mine) Text(k['owner'] == null ? '' : '${k['owner']}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ink2)),
                  if (due != null)
                    Text(
                        '${overdue ? 'Overdue · ' : ''}${DateFormat('EEE d MMM').format(due)}${(k['due_text'] ?? '').toString().isNotEmpty ? ' (“${k['due_text']}”)' : ''}',
                        style: TextStyle(fontSize: 12.5, color: overdue ? t.bad : t.due)),
                  if (k['session_id'] != null)
                    InkWell(
                      onTap: () => NavScope.of(context).open(k['session_id'] as int, at: (k['t'] as num?)?.toDouble()),
                      child: Text('from ${k['session_title'] ?? 'a conversation'}',
                          style: TextStyle(fontSize: 12.5, color: t.liveInk, decoration: TextDecoration.underline, decorationColor: t.line2)),
                    ),
                ]),
                if (looksDone)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      Icon(Icons.check_circle_outline, size: 15, color: t.ok),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('Looks done${k['done_evidence'] != null ? ': “${k['done_evidence']}”' : ''}',
                            style: TextStyle(fontSize: 12.5, color: t.ok)),
                      ),
                      TextButton(onPressed: () => _set('done'), child: const Text('Mark done')),
                      TextButton(
                        onPressed: () async {
                          await widget.s.api.patch('/api/tasks/${k['id']}', {'suggested_done': false});
                          await widget.onChanged();
                        },
                        child: const Text('Not yet'),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
