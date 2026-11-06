// Today: the day's brief, its conversations in order, what's due, earmarked moments.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../mac_app.dart';
import '../widgets.dart';
import 'tasks_page.dart';

class TodayPage extends StatefulWidget {
  final MacState s;
  const TodayPage({super.key, required this.s});
  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  String? day; // yyyy-mm-dd; null = today

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Load<Map<String, dynamic>>(
      s: s,
      reloadKey: day,
      load: () async => Map<String, dynamic>.from(await s.api.get('/api/day', {'d': ?day}) as Map),
      builder: (context, d, reload) {
        final t = context.t;
        final date = DateTime.parse('${d['day']}');
        final brief = d['brief'] is Map ? Map<String, dynamic>.from(d['brief'] as Map) : null;
        final sessions = [for (final x in (d['sessions'] as List? ?? [])) Map<String, dynamic>.from(x as Map)];
        final tasks = [for (final x in (d['tasks'] as List? ?? [])) Map<String, dynamic>.from(x as Map)];
        final marks = (d['earmarks'] as List? ?? []);
        final captured = (d['captured_s'] as num?)?.toDouble() ?? 0;
        return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          PageHeader(
            title: d['is_today'] == true ? 'Today' : DateFormat('EEEE d MMMM').format(date),
            subtitle: [
              if (d['is_today'] == true) DateFormat('EEEE d MMMM').format(date),
              if (captured > 0) '${dur(captured)} recorded',
              if (sessions.isNotEmpty) '${sessions.length} conversation${sessions.length == 1 ? '' : 's'}',
            ].join(' · '),
            actions: [
              IconButton(
                tooltip: 'Previous day',
                onPressed: d['prev'] == null ? null : () => setState(() => day = '${d['prev']}'),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Next day',
                onPressed: d['next'] == null ? null : () => setState(() => day = d['next'] == DateFormat('yyyy-MM-dd').format(DateTime.now()) ? null : '${d['next']}'),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Readable(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (brief != null && '${brief['headline'] ?? ''}'.isNotEmpty)
                  Panel(
                    key: const Key('brief'),
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${brief['headline']}', style: Theme.of(context).textTheme.headlineMedium),
                      if ('${brief['summary'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('${brief['summary']}', style: TextStyle(fontSize: 15.5, height: 1.55, color: t.ink2)),
                      ],
                      for (final dec in (brief['decisions'] as List? ?? [])) ...[
                        const SizedBox(height: 8),
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.gavel_rounded, size: 15, color: t.ok)),
                          const SizedBox(width: 8),
                          Expanded(child: Text('$dec', style: const TextStyle(fontSize: 14))),
                        ]),
                      ],
                      if ((brief['people'] as List? ?? []).isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(spacing: 6, runSpacing: 6, children: [for (final p in brief['people'] as List) Chip2('$p')]),
                      ],
                    ]),
                  )
                else if (d['brief_status'] == 'pending' || d['brief_status'] == 'running')
                  Text('Writing the brief of the day…', style: TextStyle(color: t.ink2)),
                if (tasks.isNotEmpty) ...[
                  const SectionLabel('Due and open'),
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      for (final (i, k) in tasks.take(8).indexed) ...[
                        if (i > 0) const Divider(),
                        TaskTile(s: widget.s, task: k, onChanged: reload),
                      ],
                    ]),
                  ),
                ],
                const SectionLabel('Conversations'),
                if (sessions.isEmpty)
                  Text(d['is_today'] == true ? 'Nothing recorded yet today.' : 'Nothing recorded that day.',
                      style: TextStyle(color: t.ink2)),
                for (final x in sessions) SessionCard(x: x),
                if (marks.isNotEmpty) ...[
                  const SectionLabel('Earmarked moments'),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final m in marks)
                      if (m is List && m.isNotEmpty)
                        ActionChip(
                          avatar: Icon(Icons.bookmark, size: 15, color: t.due),
                          label: Text(hm(m[0] as num)),
                          onPressed: m.length < 2 || m[1] == null
                              ? null
                              : () {
                                  final sid = m[1] as int;
                                  final st = sessions.where((x) => x['id'] == sid).firstOrNull?['started_at'] as num?;
                                  NavScope.of(context).open(sid, at: st == null ? null : ((m[0] as num) - st).toDouble());
                                },
                        ),
                  ]),
                ],
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

/// A conversation in a list: time, title, gist, people, counts.
class SessionCard extends StatelessWidget {
  final Map<String, dynamic> x;
  final bool selected;
  final VoidCallback? onTap;
  const SessionCard({super.key, required this.x, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final start = x['started_at'] as num;
    final busy = x['status'] != 'done' || (x['intel_status'] != null && x['intel_status'] != 'done' && x['intel_status'] != 'off');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? t.liveSoft : t.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? t.live.withValues(alpha: .5) : t.line)),
        child: InkWell(
          key: Key('session_${x['id']}'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap ?? () => NavScope.of(context).open(x['id'] as int),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 54,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(hm(start), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  Text(dur((x['duration_s'] as num?) ?? 0), style: TextStyle(fontSize: 12, color: t.ink3)),
                ]),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text('${x['title'] ?? 'Conversation'}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    if (busy) Chip2(x['status'] != 'done' ? 'Transcribing' : 'Writing notes', color: t.liveInk, bg: t.liveSoft),
                  ]),
                  if ('${x['gist'] ?? ''}'.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text('${x['gist']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, height: 1.4, color: t.ink2)),
                  ],
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final p in (x['people'] as List? ?? []).take(4)) Chip2('$p'),
                    if ((x['task_count'] as num? ?? 0) > 0) Chip2('${x['task_count']} task${x['task_count'] == 1 ? '' : 's'}'),
                    if ((x['earmark_count'] as num? ?? 0) > 0) Chip2('${x['earmark_count']} earmark${x['earmark_count'] == 1 ? '' : 's'}', color: t.due),
                    if (x['transcribed_by'] == 'iphone') Chip2('iPhone'),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
