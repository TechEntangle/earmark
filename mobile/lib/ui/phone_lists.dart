// Conversations and tasks made on the iPhone (see notes/conversations.dart).
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../notes/conversations.dart';
import 'theme.dart';

String _hm(DateTime t) => DateFormat.Hm().format(t);

/// What to call a conversation before (or without) notes.
String convTitle(EarmarkController c, Conversation v) {
  if (v.status == 'ready' && (v.title ?? '').isNotEmpty) return v.title!;
  if (v.status == 'open') return 'Listening…';
  if (v.status == 'pending' && c.notesOn) return 'Writing notes…';
  final h = c.heard;
  if (h == null) return 'Conversation';
  final first = Conversations.lines(v, h).map((l) => l.text).join(' ').split(RegExp(r'\s+'));
  return first.isEmpty || first.first.isEmpty ? 'Conversation' : '${first.take(8).join(' ')}${first.length > 8 ? '…' : ''}';
}

bool _working(EarmarkController c, Conversation v) => v.status == 'open' || (v.status == 'pending' && c.notesOn);

void openConversation(BuildContext context, EarmarkController c, Conversation v) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhoneConversationScreen(c: c, id: v.id)));

/// Home: the three latest conversations on this phone.
class PhoneLatest extends StatelessWidget {
  final EarmarkController c;
  const PhoneLatest({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rows = (c.convs?.visible ?? const <Conversation>[]).take(3).toList();
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Text('Conversations show up here a minute or so after they end.', style: TextStyle(fontSize: 14, color: t.ink2)),
      );
    }
    return Container(
      key: const Key('latest'),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: t.line),
          ConvRow(c: c, v: rows[i]),
        ],
      ]),
    );
  }
}

class ConvRow extends StatelessWidget {
  final EarmarkController c;
  final Conversation v;
  const ConvRow({super.key, required this.c, required this.v});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final working = _working(c, v);
    final n = v.openTasks;
    return InkWell(
      onTap: () => openConversation(context, c, v),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            SizedBox(width: 48, child: Text(_hm(v.startTime),
                style: TextStyle(fontSize: 13, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()]))),
            Expanded(
              child: Text(convTitle(c, v), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Newsreader', fontSize: 17, color: working ? t.ink2 : t.ink,
                      fontStyle: working ? FontStyle.italic : FontStyle.normal)),
            ),
            if (n > 0) ...[
              const SizedBox(width: 10),
              Text('$n task${n == 1 ? '' : 's'}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.liveInk)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Talks: every conversation on this phone, by day.
class PhoneTalksScreen extends StatelessWidget {
  final EarmarkController c;
  const PhoneTalksScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Conversations')),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final t = context.t;
            final all = c.convs?.visible ?? const <Conversation>[];
            if (all.isEmpty) {
              return Center(child: Padding(padding: const EdgeInsets.all(32),
                  child: Text('Nothing yet. Conversations show up here a minute or so after they end.',
                      textAlign: TextAlign.center, style: TextStyle(color: t.ink2))));
            }
            final out = <Widget>[];
            String? day;
            var group = <Widget>[];
            void close() {
              if (group.isNotEmpty) {
                out.add(Container(
                  decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(18)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: group),
                ));
              }
            }
            for (final v in all) {
              final d = DateFormat('EEEE, d MMM').format(v.startTime);
              if (d != day) {
                close();
                day = d;
                group = [];
                out.add(Padding(
                  padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
                  child: Text(d.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: t.ink2)),
                ));
              } else {
                group.add(Divider(height: 1, color: t.line));
              }
              group.add(ConvRow(c: c, v: v));
            }
            close();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: out);
          },
        ),
      );
}

/// One conversation: notes, tasks and the transcript, all from this phone.
class PhoneConversationScreen extends StatelessWidget {
  final EarmarkController c;
  final int id;
  const PhoneConversationScreen({super.key, required this.c, required this.id});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final v = c.convs?.byId(id);
            final h = c.heard;
            if (v == null || h == null) return const Center(child: Text('This conversation is no longer on the phone.'));
            final t = context.t, tt = Theme.of(context).textTheme;
            final lines = Conversations.lines(v, h);
            final from = Conversations.translatedFrom(v, h);
            return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
              Text(convTitle(c, v), style: tt.headlineMedium),
              const SizedBox(height: 6),
              Text('${DateFormat('EEE d MMM, HH:mm').format(v.startTime)}  ·  ${dur(v.seconds)}  ·  On iPhone'
                  '${from.isEmpty ? '' : '  ·  Translated from ${from.join(', ')}'}', style: tt.bodySmall),
              const SizedBox(height: 16),
              if (v.status == 'ready') ...[
                if ((v.summary ?? '').isNotEmpty)
                  Text(v.summary!, style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17, height: 1.5)),
                if (v.tasks.isNotEmpty) ...[
                  _head(context, 'TASKS'),
                  for (final k in v.tasks) PhoneTaskRow(c: c, task: k, showSource: false),
                ],
                if (v.keyPoints.isNotEmpty) ...[_head(context, 'KEY POINTS'), for (final p in v.keyPoints) _bullet(context, p)],
                if (v.decisions.isNotEmpty) ...[_head(context, 'DECISIONS'), for (final p in v.decisions) _bullet(context, p)],
              ] else if (v.status == 'failed') ...[
                Text("Notes couldn't be written on the iPhone: ${v.error ?? 'unknown problem'}.",
                    style: TextStyle(fontSize: 14, color: t.due)),
                Align(alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () => c.retryNotes(v), child: const Text('Try again'))),
              ] else if (v.status == 'pending' && !c.notesOn) ...[
                Text(notesHint(c), style: TextStyle(fontSize: 14, color: t.ink2)),
              ] else if (_working(c, v)) ...[
                Text(v.status == 'open' ? 'Still listening. Notes follow when the conversation ends.' : 'Writing notes on the iPhone…',
                    style: TextStyle(fontSize: 14, color: t.ink2)),
              ],
              _head(context, 'TRANSCRIPT'),
              if (lines.isEmpty) Text('No words.', style: TextStyle(color: t.ink2)),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 50, child: Text(Conversations.clockText(l.at),
                        style: TextStyle(fontSize: 12, color: t.ink2, height: 1.7, fontFeatures: const [FontFeature.tabularFigures()]))),
                    Expanded(child: SelectableText(l.text, style: const TextStyle(fontFamily: 'Newsreader', fontSize: 16.5, height: 1.45))),
                  ]),
                ),
            ]);
          },
        ),
      );

  Widget _head(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 22, 0, 8),
        child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: context.t.ink2)),
      );

  Widget _bullet(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(2, 8, 10, 0),
              child: Container(width: 5, height: 5, decoration: BoxDecoration(color: context.t.ink2, shape: BoxShape.circle))),
          Expanded(child: Text(s, style: const TextStyle(fontSize: 15, height: 1.45))),
        ]),
      );
}

/// Why notes aren't being written on the phone.
String notesHint(EarmarkController c) => switch (c.notesState) {
      'notEnabled' => 'Turn on Apple Intelligence (Settings → Apple Intelligence & Siri) for notes and tasks on the iPhone.',
      'notReady' => "Apple Intelligence is still getting ready on this iPhone. Notes follow when it's done.",
      'notEligible' => "This iPhone can't run Apple's on-device model. Your Mac writes the notes.",
      _ => 'Notes and tasks for this conversation come from your Mac.',
    };

class PhoneTaskRow extends StatelessWidget {
  final EarmarkController c;
  final ConvTask task;
  final bool showSource;
  const PhoneTaskRow({super.key, required this.c, required this.task, this.showSource = true});

  @override
  Widget build(BuildContext context) {
    final t = context.t, k = task;
    final src = showSource ? c.convs?.all.where((v) => v.start == k.at).firstOrNull : null;
    return InkWell(
      onTap: src == null ? null : () => openConversation(context, c, src),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Checkbox(value: k.done, onChanged: (v) => c.setTaskDone(k, v ?? false), visualDensity: VisualDensity.compact),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(k.text, style: TextStyle(fontSize: 15, height: 1.35, color: k.done ? t.ink2 : t.ink,
                    decoration: k.done ? TextDecoration.lineThrough : null)),
                if (k.due.isNotEmpty || !k.mine || src != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text([
                      if (k.due.isNotEmpty) k.due,
                      if (!k.mine) k.owner,
                      if (src != null) convTitle(c, src),
                    ].join('  ·  '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: t.ink2)),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Tasks from conversations on this phone.
class PhoneTasksScreen extends StatefulWidget {
  final EarmarkController c;
  const PhoneTasksScreen({super.key, required this.c});
  @override
  State<PhoneTasksScreen> createState() => _PhoneTasksScreenState();
}

class _PhoneTasksScreenState extends State<PhoneTasksScreen> {
  int tab = 0; // mine, others, done

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tasks')),
        body: ListenableBuilder(
          listenable: widget.c,
          builder: (context, _) {
            final t = context.t;
            final all = widget.c.convs?.tasks ?? const <ConvTask>[];
            final rows = switch (tab) {
              0 => all.where((k) => !k.done && k.mine).toList(),
              1 => all.where((k) => !k.done && !k.mine).toList(),
              _ => all.where((k) => k.done).toList(),
            };
            return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 16, 32), children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Mine')),
                    ButtonSegment(value: 1, label: Text('Others')),
                    ButtonSegment(value: 2, label: Text('Done')),
                  ],
                  selected: {tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => tab = s.first),
                ),
              ),
              if (rows.isEmpty)
                Padding(padding: const EdgeInsets.all(24),
                    child: Text(tab == 2 ? 'Nothing done yet.' : 'Nothing to do.', textAlign: TextAlign.center, style: TextStyle(color: t.ink2))),
              for (final k in rows) PhoneTaskRow(c: widget.c, task: k),
            ]);
          },
        ),
      );
}
