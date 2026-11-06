// Today, Tasks and Conversations: read from Earmark on the Mac.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/api.dart';
import 'theme.dart';

/// Loads something from the Mac, with pull-to-refresh and friendly empty / offline states.
class MacData<T> extends StatefulWidget {
  final EarmarkController c;
  final Future<T> Function(Api api) load;
  final Widget Function(BuildContext, T data, Future<void> Function() reload) builder;
  const MacData({super.key, required this.c, required this.load, required this.builder});
  @override
  State<MacData<T>> createState() => _MacDataState<T>();
}

class _MacDataState<T> extends State<MacData<T>> {
  T? _data;
  Object? _err;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final api = widget.c.api;
    if (api == null) return;
    setState(() => _loading = _data == null);
    try {
      final d = await widget.load(api);
      if (mounted) {
        setState(() {
          _data = d;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_data == null) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 60),
          Icon(Icons.cloud_off_outlined, size: 36, color: context.t.ink3),
          const SizedBox(height: 12),
          Text("Can't reach your Mac", textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('${_err ?? ''}\nRecording still works: audio waits on this phone. Pull down to try again.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: widget.builder(context, _data as T, _reload));
  }
}

/// Which device turned a conversation into text: "iPhone", "Mac", or null (not yet / unknown).
String? transcribedOn(Map s) => switch (s['transcribed_by']) { 'iphone' => 'iPhone', 'mac' => 'Mac', _ => null };

String _hm(num epoch) => DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round()));

String _dueLabel(String? due) {
  if (due == null || due.isEmpty) return '';
  final d = DateTime.tryParse(due);
  if (d == null) return due;
  final today = DateTime.now();
  final t0 = DateTime(today.year, today.month, today.day);
  final diff = d.difference(t0).inDays;
  if (diff < 0) return 'Overdue';
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff < 7) return DateFormat.EEEE().format(d);
  return DateFormat.MMMd().format(d);
}

// ---------------------------------------------------------------- Today
class TodayScreen extends StatelessWidget {
  final EarmarkController c;
  const TodayScreen({super.key, required this.c});
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme, t = context.t;
    return Scaffold(
      appBar: AppBar(title: Text(DateFormat('EEEE, d MMMM').format(DateTime.now()))),
      body: MacData<Map<String, dynamic>>(
        c: c,
        load: (a) => a.day(),
        builder: (context, d, reload) {
          final brief = d['brief'] as Map?;
          final sessions = (d['sessions'] as List? ?? []).cast<Map>();
          final tasks = (d['tasks'] as List? ?? []).cast<Map>();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            if (brief != null) ...[
              Text('${brief['headline'] ?? ''}', style: tt.headlineMedium),
              const SizedBox(height: 8),
              Text('${brief['summary'] ?? ''}', style: tt.bodyLarge?.copyWith(fontFamily: 'Newsreader', fontSize: 17, color: t.ink)),
              const SizedBox(height: 18),
            ] else ...[
              Text(sessions.isEmpty ? 'Nothing recorded yet today' : 'Your day so far', style: tt.headlineMedium),
              const SizedBox(height: 6),
              Text(sessions.isEmpty ? 'Conversations appear here once the Mac has transcribed them.' : 'The day brief is written after a few conversations.',
                  style: tt.bodySmall),
              const SizedBox(height: 18),
            ],
            if (tasks.isNotEmpty) ...[
              _Section('To do'),
              Panel(padding: EdgeInsets.zero, child: Column(children: [for (final x in tasks.take(6)) TaskRow(c: c, task: x, onChanged: reload)])),
              const SizedBox(height: 18),
            ],
            if ((brief?['decisions'] as List?)?.isNotEmpty ?? false) ...[
              _Section('Decisions'),
              for (final x in (brief!['decisions'] as List)) Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.only(top: 8, right: 10), child: Container(width: 5, height: 5, decoration: BoxDecoration(color: t.ink3, shape: BoxShape.circle))),
                  Expanded(child: Text('$x', style: tt.bodyMedium)),
                ]),
              ),
              const SizedBox(height: 14),
            ],
            if (sessions.isNotEmpty) ...[
              _Section('Conversations'),
              for (final s in sessions) SessionTile(c: c, s: s),
            ],
          ]);
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 11.5, letterSpacing: .6, fontWeight: FontWeight.w600, color: context.t.ink3)),
      );
}

// ---------------------------------------------------------------- Tasks
class TasksScreen extends StatefulWidget {
  final EarmarkController c;
  const TasksScreen({super.key, required this.c});
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  bool mine = true;
  bool _isMine(Map x) => ['me', 'unknown', ''].contains('${x['owner'] ?? 'me'}'.toLowerCase());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Mine')), ButtonSegment(value: false, label: Text('Waiting on others'))],
              selected: {mine},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => mine = s.first),
            ),
          ),
        ),
      ),
      body: MacData<List<dynamic>>(
        c: widget.c,
        load: (a) => a.tasks(),
        builder: (context, all, reload) {
          final rows = all.cast<Map>().where((x) => _isMine(x) == mine).toList();
          if (rows.isEmpty) {
            return ListView(padding: const EdgeInsets.all(28), children: [
              const SizedBox(height: 40),
              Text('All caught up', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(mine ? 'Tasks appear when you commit to something in a conversation, or say "remind me to…" after a tap.'
                  : 'Nothing is waiting on anyone else.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ]);
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            Panel(padding: EdgeInsets.zero, child: Column(children: [for (final x in rows) TaskRow(c: widget.c, task: x, onChanged: reload)])),
          ]);
        },
      ),
    );
  }
}

class TaskRow extends StatefulWidget {
  final EarmarkController c;
  final Map task;
  final Future<void> Function() onChanged;
  const TaskRow({super.key, required this.c, required this.task, required this.onChanged});
  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    final x = widget.task, t = context.t;
    final due = _dueLabel(x['due'] as String?);
    final owner = '${x['owner'] ?? ''}';
    final looksDone = x['suggested_done'] == 1;
    return InkWell(
      onTap: () => _toggle(),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 14, 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Checkbox(value: _done, onChanged: (_) => _toggle()),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 11),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${x['text']}', style: TextStyle(fontSize: 15, height: 1.35, color: _done ? t.ink3 : t.ink,
                    decoration: _done ? TextDecoration.lineThrough : null)),
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  if (due.isNotEmpty) _Tag(due, due == 'Overdue' ? t.bad : (due == 'Today' ? t.due : t.ink2)),
                  if (!['me', 'unknown', ''].contains(owner.toLowerCase())) _Tag(owner, t.ink2),
                  if (looksDone) _Tag('Looks done', t.ok),
                  if (x['session_title'] != null) Text('${x['session_title']}', style: TextStyle(fontSize: 12, color: t.ink3)),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _toggle() async {
    final api = widget.c.api;
    if (api == null) return;
    setState(() => _done = !_done);
    final id = widget.task['id'] as int;
    try {
      await api.setTaskStatus(id, _done ? 'done' : 'open');
      if (_done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Marked done'),
          action: SnackBarAction(label: 'Undo', onPressed: () async {
            await api.setTaskStatus(id, 'open');
            await widget.onChanged();
          }),
        ));
        await Future.delayed(const Duration(milliseconds: 600));
        await widget.onChanged();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _done = !_done);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color);
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color));
}

// ---------------------------------------------------------------- Conversations
class ConversationsScreen extends StatelessWidget {
  final EarmarkController c;
  const ConversationsScreen({super.key, required this.c});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Conversations')),
        body: MacData<List<dynamic>>(
          c: c,
          load: (a) => a.sessions(),
          builder: (context, all, reload) {
            final rows = all.cast<Map>();
            final out = <Widget>[];
            String? day;
            for (final s in rows) {
              final d = DateFormat('EEEE, d MMM').format(DateTime.fromMillisecondsSinceEpoch((s['started_at'] as num).round() * 1000));
              if (d != day) {
                day = d;
                out.add(Padding(padding: const EdgeInsets.fromLTRB(2, 14, 0, 8), child: _Section(d)));
              }
              out.add(SessionTile(c: c, s: s));
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: out);
          },
        ),
      );
}

class SessionTile extends StatelessWidget {
  final EarmarkController c;
  final Map s;
  const SessionTile({super.key, required this.c, required this.s});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pending = s['status'] != 'done';
    final speakers = (s['speakers'] as List? ?? []).join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConversationScreen(c: c, id: s['id'] as int))),
        child: Panel(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(_hm(s['started_at'] as num), style: TextStyle(fontSize: 12.5, color: t.ink3, fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 8),
              Text(dur(s['duration_s'] as num? ?? 0), style: TextStyle(fontSize: 12.5, color: t.ink3)),
              if (transcribedOn(s) != null) ...[
                const SizedBox(width: 8),
                Text('· ${transcribedOn(s)}', key: const Key('transcribedOn'), style: TextStyle(fontSize: 12.5, color: t.ink2)),
              ] else if (s['source'] == 'phone') ...[const SizedBox(width: 8), Icon(Icons.smartphone, size: 13, color: t.ink3)],
              const Spacer(),
              if ((s['task_count'] as int? ?? 0) > 0) Text('${s['task_count']} tasks', style: TextStyle(fontSize: 12, color: t.liveInk, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Text(pending ? 'Transcribing…' : '${s['title'] ?? 'Conversation'}',
                style: TextStyle(fontFamily: 'Newsreader', fontSize: 18, height: 1.25, color: pending ? t.ink3 : t.ink)),
            if (speakers.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text('with $speakers', style: TextStyle(fontSize: 12.5, color: t.ink2))),
            if ((s['gist'] as String?)?.isNotEmpty ?? false) ...[
              const SizedBox(height: 4),
              Text('${s['gist']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: t.ink2, height: 1.4)),
            ],
          ]),
        ),
      ),
    );
  }
}

class ConversationScreen extends StatefulWidget {
  final EarmarkController c;
  final int id;
  const ConversationScreen({super.key, required this.c, required this.id});
  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  bool transcript = false;
  @override
  Widget build(BuildContext context) {
    final t = context.t, tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversation'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Notes')), ButtonSegment(value: true, label: Text('Transcript'))],
              selected: {transcript},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => transcript = s.first),
            ),
          ),
        ),
      ),
      body: MacData<Map<String, dynamic>>(
        c: widget.c,
        load: (a) => a.session(widget.id),
        builder: (context, s, reload) {
          final n = (s['notes'] as Map?) ?? {};
          final speakers = {for (final x in (s['speakers'] as List? ?? []).cast<Map>()) x['label']: x};
          final head = <Widget>[
            Text('${s['title'] ?? 'Conversation'}', style: tt.headlineMedium),
            const SizedBox(height: 6),
            Text('${DateFormat('EEE d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch((s['started_at'] as num).round() * 1000))}  ·  ${dur(s['duration_s'] as num? ?? 0)}'
                '${transcribedOn(s) != null ? '  ·  Transcribed on ${transcribedOn(s)}' : ''}',
                style: tt.bodySmall),
            const SizedBox(height: 16),
          ];
          if (transcript) {
            final segs = (s['segments'] as List? ?? []).cast<Map>();
            String? last;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              ...head,
              for (final g in segs) ...[
                if (g['spk'] != null && g['spk'] != last) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Text(_speakerName(speakers[last = g['spk'] as String]), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.liveInk)),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 46, child: Text(clock(g['start'] as num? ?? 0), style: TextStyle(fontSize: 12, color: t.ink3, height: 1.7))),
                    Expanded(child: Text('${g['text']}', style: const TextStyle(fontFamily: 'Newsreader', fontSize: 16.5, height: 1.45))),
                  ]),
                ),
              ],
            ]);
          }
          List<String> list(String k) => ((n[k] as List?) ?? []).map((e) => '$e').toList();
          final tasks = (s['tasks'] as List? ?? []).cast<Map>().where((x) => x['status'] != 'dismissed').toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            ...head,
            if (n['summary'] != null) Text('${n['summary']}', style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17, height: 1.5)),
            if (s['status'] != 'done') Text('Being transcribed on your Mac…', style: tt.bodyMedium?.copyWith(color: t.ink2)),
            for (final (title, key) in [('Key points', 'key_points'), ('Decisions', 'decisions')])
              if (list(key).isNotEmpty) ...[
                const SizedBox(height: 18),
                _Section(title),
                for (final x in list(key)) Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(padding: const EdgeInsets.only(top: 8, right: 10), child: Container(width: 5, height: 5, decoration: BoxDecoration(color: t.ink3, shape: BoxShape.circle))),
                    Expanded(child: Text(x, style: tt.bodyMedium)),
                  ]),
                ),
              ],
            if (tasks.isNotEmpty) ...[
              const SizedBox(height: 18),
              _Section('Tasks'),
              Panel(padding: EdgeInsets.zero, child: Column(children: [for (final x in tasks) TaskRow(c: widget.c, task: x, onChanged: reload)])),
            ],
          ]);
        },
      ),
    );
  }

  String _speakerName(Map? sp) {
    if (sp == null) return 'Speaker';
    final named = sp['name'] != null && (sp['state'] == 'confirmed' || sp['state'] == 'auto');
    if (named) return sp['is_me'] == true ? 'Me' : '${sp['name']}';
    final n = int.tryParse('${sp['label']}'.replaceAll(RegExp(r'\D'), '')) ?? 1;
    return 'Speaker $n';
  }
}
