// Conversations: a list on the left, the chosen one on the right with its notes, tasks, who spoke,
// the transcript and the recording (click a line to play from there).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../mac_app.dart';
import '../widgets.dart';
import 'tasks_page.dart';
import 'today_page.dart';

class ConversationsPage extends StatefulWidget {
  final MacState s;
  const ConversationsPage({super.key, required this.s});
  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  final _q = TextEditingController();
  String query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _q.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s, t = context.t, nav = NavScope.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 360,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 30, 18, 10),
            child: Text('Conversations', style: Theme.of(context).textTheme.headlineMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: TextField(
              key: const Key('convSearch'),
              controller: _q,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () => setState(() => query = v.trim()));
              },
              decoration: const InputDecoration(hintText: 'Search titles and transcripts', prefixIcon: Icon(Icons.search, size: 19)),
            ),
          ),
          Expanded(
            child: Load<List<Map<String, dynamic>>>(
              s: s,
              reloadKey: query,
              load: () async => [
                for (final x in (await s.api.get('/api/sessions', {if (query.isNotEmpty) 'q': query, 'limit': '400'}) as List))
                  Map<String, dynamic>.from(x as Map),
              ],
              builder: (context, list, _) {
                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(query.isEmpty ? 'No conversations yet.' : 'Nothing matches “$query”.', style: TextStyle(color: t.ink2)),
                  );
                }
                if (nav.conversation == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (nav.conversation == null && mounted) nav.open(list.first['id'] as int);
                  });
                }
                final rows = <Widget>[];
                String? last;
                for (final x in list) {
                  final d = dayLabel(x['started_at'] as num);
                  if (d != last) {
                    rows.add(Padding(
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                      child: Text(d, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.ink3)),
                    ));
                    last = d;
                  }
                  rows.add(SessionCard(x: x, selected: nav.conversation == x['id'], onTap: () => nav.open(x['id'] as int)));
                }
                return ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: rows);
              },
            ),
          ),
        ]),
      ),
      VerticalDivider(width: 1, color: t.line),
      Expanded(
        child: nav.conversation == null
            ? Center(child: Text('Choose a conversation', style: TextStyle(color: t.ink3)))
            : ConversationDetail(key: ValueKey('conv_${nav.conversation}'), s: s, id: nav.conversation!, at: nav.at),
      ),
    ]);
  }
}

class ConversationDetail extends StatefulWidget {
  final MacState s;
  final int id;
  final double? at;
  const ConversationDetail({super.key, required this.s, required this.id, this.at});
  @override
  State<ConversationDetail> createState() => _ConversationDetailState();
}

class _ConversationDetailState extends State<ConversationDetail> {
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  bool playing = false;
  double position = 0, duration = 0, speed = 1;
  Timer? _poll;
  bool _jumped = false;

  String get _url => 'http://127.0.0.1:$enginePort/api/sessions/${widget.id}/audio';

  @override
  void dispose() {
    _poll?.cancel();
    Native.stop();
    _scroll.dispose();
    super.dispose();
  }

  void _apply(Map m) {
    if (!mounted) return;
    setState(() {
      playing = m['playing'] == true;
      position = (m['position'] as num?)?.toDouble() ?? position;
      final d = (m['duration'] as num?)?.toDouble() ?? 0;
      if (d > 0) duration = d;
    });
  }

  Future<void> _play([double? at]) async {
    _apply(await Native.play(_url, at: at, speed: speed));
    _poll ??= Timer.periodic(const Duration(milliseconds: 300), (_) async => _apply(await Native.audioState()));
  }

  Future<void> _toggle() async {
    if (playing) {
      _apply(await Native.pause());
    } else {
      await _play(position > 0 && position < duration - .5 ? null : 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Load<Map<String, dynamic>>(
      s: s,
      load: () async => Map<String, dynamic>.from(await s.api.get('/api/sessions/${widget.id}') as Map),
      builder: (context, v, reload) {
        final t = context.t;
        final notes = v['notes'] is Map ? Map<String, dynamic>.from(v['notes'] as Map) : <String, dynamic>{};
        final segs = [for (final g in (v['segments'] as List? ?? [])) Map<String, dynamic>.from(g as Map)];
        final speakers = [for (final x in (v['speakers'] as List? ?? [])) Map<String, dynamic>.from(x as Map)];
        final tasks = [for (final x in (v['tasks'] as List? ?? [])) Map<String, dynamic>.from(x as Map)];
        final marks = [for (final m in (v['earmarks'] as List? ?? [])) (m as num).toDouble()];
        String who(String? label) {
          if (label == null) return '';
          final i = speakers.indexWhere((x) => x['label'] == label);
          if (i < 0) return label;
          final x = speakers[i];
          if ((x['name'] ?? '').toString().isNotEmpty) return '${x['name']}';
          if (x['is_me'] == true) return 'Me';
          if (x['guess_me'] == true) return 'Me?';
          return 'Speaker ${i + 1}';
        }

        final current = playing || position > 0 ? segs.lastIndexWhere((g) => (g['start'] as num) <= position + .05) : -1;
        if (!_jumped && widget.at != null) {
          _jumped = true;
          final i = segs.lastIndexWhere((g) => (g['start'] as num) <= widget.at! + .5);
          if (i >= 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _lineKeys[i]?.currentContext;
              if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .3, duration: const Duration(milliseconds: 300));
            });
          }
        }
        final start = v['started_at'] as num;
        final total = duration > 0 ? duration : ((v['duration_s'] as num?)?.toDouble() ?? 0);
        return ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(36, 30, 36, 48), children: [
          Readable(
            max: 820,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${v['title'] ?? 'Conversation'}', key: const Key('convTitle'), style: Theme.of(context).textTheme.headlineLarge),
                    const SizedBox(height: 6),
                    Text(
                      [
                        DateFormat('EEEE d MMMM, HH:mm').format(epoch(start)),
                        dur((v['duration_s'] as num?) ?? 0),
                        if (v['kind'] != null) '${v['kind']}',
                        if (v['transcribed_by'] == 'iphone') 'transcribed on iPhone',
                        if ('${v['language'] ?? ''}'.contains(',') || ('${v['language'] ?? 'en'}' != 'en' && '${v['language'] ?? ''}'.isNotEmpty))
                          'translated to English',
                      ].join(' · '),
                      style: TextStyle(fontSize: 13.5, color: t.ink2),
                    ),
                  ]),
                ),
                _Menu(s: s, v: v, reload: reload),
              ]),
              const SizedBox(height: 16),
              _Player(
                playing: playing,
                position: position,
                total: total,
                speed: speed,
                marks: marks,
                onToggle: _toggle,
                onSeek: (x) => _play(x),
                onSpeed: () async {
                  speed = const [1.0, 1.25, 1.5, 2.0][([1.0, 1.25, 1.5, 2.0].indexOf(speed) + 1) % 4];
                  _apply(await Native.speed(speed));
                },
              ),
              if (v['status'] != 'done')
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(v['status'] == 'error' ? 'Transcription failed: ${v['error'] ?? ''}' : 'Transcribing…',
                      style: TextStyle(color: v['status'] == 'error' ? t.bad : t.ink2)),
                ),
              if ('${notes['summary'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('${notes['summary']}', style: const TextStyle(fontFamily: 'Newsreader', fontSize: 19, height: 1.5)),
              ] else if (v['intel_status'] == 'pending' || v['intel_status'] == 'running')
                Padding(padding: const EdgeInsets.only(top: 18), child: Text('Writing notes…', style: TextStyle(color: t.ink2))),
              if (tasks.isNotEmpty) ...[
                const SectionLabel('Tasks'),
                Panel(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (final (i, k) in tasks.indexed) ...[
                      if (i > 0) const Divider(),
                      TaskTile(s: s, task: {...k, 'session_id': null}, onChanged: reload),
                    ],
                  ]),
                ),
              ],
              if ((notes['key_points'] as List? ?? []).isNotEmpty) ...[
                const SectionLabel('Key points'),
                for (final p in notes['key_points'] as List) _Bullet('$p'),
              ],
              if ((notes['decisions'] as List? ?? []).isNotEmpty) ...[
                const SectionLabel('Decisions'),
                for (final p in notes['decisions'] as List) _Bullet('$p', icon: Icons.gavel_rounded, color: t.ok),
              ],
              if (speakers.isNotEmpty) ...[
                const SectionLabel('Who spoke'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (i, x) in speakers.indexed)
                    ActionChip(
                      key: Key('speaker_${x['label']}'),
                      avatar: Avatar(who(x['label'] as String), size: 22),
                      label: Text('${who(x['label'] as String)} · ${dur((x['seconds'] as num?) ?? 0)}'),
                      tooltip: 'Name this voice; Earmark recognises it next time',
                      onPressed: () => _nameSpeaker(x, i, who(x['label'] as String), reload),
                    ),
                ]),
              ],
              const SectionLabel('Transcript'),
              if (segs.isEmpty) Text('No words in this recording.', style: TextStyle(color: t.ink2)),
              for (final (i, g) in segs.indexed)
                _Line(
                  key: _lineKeys.putIfAbsent(i, () => GlobalKey()),
                  at: (g['start'] as num).toDouble(),
                  who: i > 0 && segs[i - 1]['spk'] == g['spk'] ? null : who(g['spk'] as String?),
                  text: '${g['text']}',
                  current: i == current,
                  marked: marks.any((m) => m >= (g['start'] as num) - 2 && m <= (g['end'] as num? ?? g['start'] as num) + 2),
                  onTap: () => _play((g['start'] as num).toDouble()),
                ),
            ]),
          ),
        ]);
      },
    );
  }

  Future<void> _nameSpeaker(Map<String, dynamic> x, int i, String current, Future<void> Function() reload) async {
    final ctl = TextEditingController(text: current.startsWith('Speaker ') || current == 'Me?' ? '' : current);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Who is ${current.startsWith('Speaker') ? current.toLowerCase() : current}?'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'A name, or "me"'),
              onSubmitted: (v) => Navigator.pop(d, v),
            ),
            const SizedBox(height: 10),
            Text('Earmark learns the voice and names it in future conversations.', style: Theme.of(d).textTheme.bodySmall),
          ]),
        ),
        actions: [
          if (x['guess_me'] == true) TextButton(onPressed: () => Navigator.pop(d, 'me'), child: const Text("Yes, it's me")),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.s.api.post('/api/sessions/${widget.id}/speakers/${x['label']}', {'name': name.trim()});
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    await reload();
  }
}

class _Menu extends StatelessWidget {
  final MacState s;
  final Map<String, dynamic> v;
  final Future<void> Function() reload;
  const _Menu({required this.s, required this.v, required this.reload});

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Icon(Icons.more_horiz),
        onSelected: (a) async {
          switch (a) {
            case 'rename':
              final ctl = TextEditingController(text: '${v['title'] ?? ''}');
              final title = await showDialog<String>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('Rename'),
                  content: SizedBox(
                      width: 380,
                      child: TextField(controller: ctl, autofocus: true, onSubmitted: (x) => Navigator.pop(d, x))),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Save')),
                  ],
                ),
              );
              if (title != null && title.trim().isNotEmpty) {
                await s.api.patch('/api/sessions/${v['id']}', {'title': title.trim()});
                s.changed();
              }
            case 'copy':
              final segs = (v['segments'] as List? ?? []).map((g) => '[${mmss((g as Map)['start'] as num)}] ${g['text']}').join('\n');
              await Clipboard.setData(ClipboardData(text: '${v['title'] ?? 'Conversation'}\n\n$segs'));
              if (context.mounted) toast(context, 'Transcript copied');
            case 'notes':
              await Clipboard.setData(ClipboardData(text: '${v['summary_md'] ?? ''}'));
              if (context.mounted) toast(context, 'Notes copied (Markdown)');
            case 'reveal':
              if (v['note_path'] != null) await Native.reveal('${v['note_path']}');
            case 'renotes':
              await s.api.post('/api/sessions/${v['id']}/renotes');
              if (context.mounted) toast(context, 'Writing the notes again');
              await reload();
            case 'delete':
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('Delete this conversation?'),
                  content: const Text('Its recording, transcript, notes and tasks are removed from this Mac.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                    FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: context.t.bad),
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await s.api.delete('/api/sessions/${v['id']}');
                if (context.mounted) {
                  final nav = NavScope.of(context);
                  nav.conversation = null;
                  nav.go(Section.conversations);
                }
                s.changed();
              }
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'copy', child: Text('Copy transcript')),
          const PopupMenuItem(value: 'notes', child: Text('Copy notes')),
          if (v['note_path'] != null) const PopupMenuItem(value: 'reveal', child: Text('Show notes file in Finder')),
          const PopupMenuItem(value: 'renotes', child: Text('Write the notes again')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'delete', child: Text('Delete…')),
        ],
      );
}

class _Player extends StatelessWidget {
  final bool playing;
  final double position, total, speed;
  final List<double> marks;
  final VoidCallback onToggle, onSpeed;
  final ValueChanged<double> onSeek;
  const _Player({
    required this.playing, required this.position, required this.total, required this.speed, required this.marks,
    required this.onToggle, required this.onSeek, required this.onSpeed,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final max = total <= 0 ? 1.0 : total;
    return Panel(
      key: const Key('player'),
      padding: const EdgeInsets.fromLTRB(6, 2, 10, 2),
      child: Row(children: [
        IconButton(
          key: const Key('playBtn'),
          tooltip: playing ? 'Pause' : 'Play',
          onPressed: onToggle,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => Stack(alignment: Alignment.center, children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: Slider(value: position.clamp(0, max).toDouble(), max: max, onChanged: onSeek),
              ),
              for (final m in marks)
                if (m >= 0 && m <= max)
                  Positioned(
                    left: 24 + (box.maxWidth - 48) * (m / max) - 3,
                    top: 4,
                    child: IgnorePointer(child: Icon(Icons.bookmark, size: 12, color: t.due)),
                  ),
            ]),
          ),
        ),
        Text('${mmss(position)} / ${mmss(total)}',
            style: TextStyle(fontSize: 12.5, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()])),
        TextButton(
          onPressed: onSpeed,
          child: Text('${speed == speed.roundToDouble() ? speed.round() : speed}×',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.ink2)),
        ),
      ]),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? color;
  const _Bullet(this.text, {this.icon, this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(icon ?? Icons.circle, size: icon == null ? 6 : 15, color: color ?? context.t.ink3),
          ),
          SizedBox(width: icon == null ? 12 : 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14.5, height: 1.45))),
        ]),
      );
}

class _Line extends StatelessWidget {
  final double at;
  final String? who;
  final String text;
  final bool current, marked;
  final VoidCallback onTap;
  const _Line({super.key, required this.at, required this.who, required this.text, required this.current, required this.marked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: EdgeInsets.only(top: who != null ? 10 : 0),
      child: Material(
        color: current ? t.liveSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(mmss(at), style: TextStyle(fontSize: 12, color: current ? t.liveInk : t.ink3, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (who != null && who!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(who!, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ink2)),
                    ),
                  Text(text, style: const TextStyle(fontFamily: 'Newsreader', fontSize: 16.5, height: 1.5)),
                ]),
              ),
              if (marked) Padding(padding: const EdgeInsets.only(left: 6, top: 3), child: Icon(Icons.bookmark, size: 15, color: t.due)),
            ]),
          ),
        ),
      ),
    );
  }
}
