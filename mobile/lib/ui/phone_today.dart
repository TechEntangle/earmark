// Today, from this iPhone alone: a brief of the day, what's due, the day's conversations, earmarked
// moments and who you talked to. Swipe back through earlier days.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../notes/due.dart';
import 'phone_lists.dart';
import 'theme.dart';

class PhoneTodayScreen extends StatefulWidget {
  final EarmarkController c;
  const PhoneTodayScreen({super.key, required this.c});
  @override
  State<PhoneTodayScreen> createState() => _PhoneTodayScreenState();
}

class _PhoneTodayScreenState extends State<PhoneTodayScreen> {
  DateTime day = DateTime.now();
  bool _asked = false;

  bool get isToday {
    final n = DateTime.now();
    return day.year == n.year && day.month == n.month && day.day == n.day;
  }

  void _move(int d) => setState(() {
        day = day.add(Duration(days: d));
        _asked = false;
      });

  @override
  Widget build(BuildContext context) {
    final c = widget.c, t = context.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(isToday ? 'Today' : DateFormat('EEEE d MMMM').format(day)),
        actions: [
          IconButton(tooltip: 'Day before', onPressed: () => _move(-1), icon: const Icon(Icons.chevron_left)),
          IconButton(tooltip: 'Day after', onPressed: isToday ? null : () => _move(1), icon: const Icon(Icons.chevron_right)),
        ],
      ),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final list = c.dayConversations(day);
          final ready = list.where((v) => v.status == 'ready').toList();
          final brief = c.briefFor(day);
          if (brief == null && ready.isNotEmpty && c.notesOn && !_asked) {
            _asked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => c.writeBrief(day));
          }
          final secs = list.fold<double>(0, (a, v) => a + v.seconds);
          final a = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch / 1000;
          final marks = c.earmarks.where((m) => m >= a && m < a + 86400).toList();
          final people = <String>{for (final v in list) ...v.people};
          for (final v in list) {
            for (final x in v.voices.values) {
              final n = '${x['name'] ?? ''}';
              if (n.isNotEmpty && n.toLowerCase() != 'me') people.add(n);
            }
          }
          // my open tasks due by the end of this day (or overdue), across all conversations
          final end = DateTime(day.year, day.month, day.day, 23, 59);
          final due = [
            for (final k in c.convs?.tasks ?? const [])
              if (!k.done && k.mine)
                if (parseDue(k.due, DateTime.fromMillisecondsSinceEpoch((k.at * 1000).round())) case final d? when !d.at.isAfter(end)) (k, d),
          ]..sort((x, y) => x.$2.at.compareTo(y.$2.at));
          final head = TextStyle(fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w600, color: t.ink3);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Text(
              list.isEmpty
                  ? (isToday ? 'Nothing recorded yet today.' : 'Nothing recorded that day.')
                  : '${dur(secs)} recorded · ${list.length} conversation${list.length == 1 ? '' : 's'}'
                      '${marks.isEmpty ? '' : ' · ${marks.length} earmark${marks.length == 1 ? '' : 's'}'}',
              style: TextStyle(color: t.ink2),
            ),
            if (ready.isNotEmpty) ...[
              const SizedBox(height: 14),
              Panel(
                key: const Key('dayBrief'),
                child: brief != null
                    ? Text(brief, style: const TextStyle(fontFamily: 'Newsreader', fontSize: 18, height: 1.5))
                    : c.writingBrief
                        ? Row(children: [
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 10),
                            Text('Writing the brief of the day…', style: TextStyle(color: t.ink2)),
                          ])
                        : Text(c.notesOn ? 'No brief yet.' : notesHint(c), style: TextStyle(color: t.ink2)),
              ),
            ],
            if (due.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text(isToday ? 'DUE TODAY AND OVERDUE' : 'DUE BY THEN', style: head),
              const SizedBox(height: 8),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (final (i, (k, _)) in due.indexed) ...[
                    if (i > 0) const Divider(),
                    PhoneTaskRow(c: c, task: k),
                  ],
                ]),
              ),
            ],
            if (list.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text('CONVERSATIONS', style: head),
              const SizedBox(height: 8),
              for (final v in list.reversed) ConvRow(c: c, v: v),
            ],
            if (marks.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text('EARMARKED MOMENTS', style: head),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in marks)
                  ActionChip(
                    avatar: Icon(Icons.bookmark, size: 15, color: t.due),
                    label: Text(DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch((m * 1000).round()))),
                    onPressed: () {
                      final v = list.where((v) => m >= v.start - 5 && m <= v.end + 15).firstOrNull;
                      if (v != null) {
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PhoneConversationScreen(c: c, id: v.id, focusAt: m - v.start)));
                      }
                    },
                  ),
              ]),
            ],
            if (people.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text('PEOPLE', style: head),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final p in people) Chip(label: Text(p))]),
            ],
          ]);
        },
      ),
    );
  }
}
