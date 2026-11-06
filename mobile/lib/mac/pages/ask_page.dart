// Ask: questions about everything recorded, answered on this Mac with links to the moments.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../ui/theme.dart';
import '../engine.dart';
import '../mac_app.dart';
import '../widgets.dart';

class AskPage extends StatefulWidget {
  final MacState s;
  const AskPage({super.key, required this.s});
  @override
  State<AskPage> createState() => _AskPageState();
}

class _Answer {
  final String q;
  final String? text, error;
  final List<Map<String, dynamic>> passages;
  final List<int> used;
  _Answer(this.q, this.text, this.passages, this.used, this.error);
}

class _AskPageState extends State<AskPage> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<_Answer> _answers = [];
  String? _asking;

  static const examples = [
    'What did I promise to do this week?',
    'What did we decide about the budget?',
    'Summarise yesterday',
    'What is Rahul waiting on from me?',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String q) async {
    q = q.trim();
    if (q.isEmpty || _asking != null) return;
    _q.clear();
    setState(() => _asking = q);
    try {
      final r = Map<String, dynamic>.from(await widget.s.api.post('/api/ask', {'q': q}) as Map);
      _answers.add(_Answer(
        q,
        r['answer'] as String?,
        [for (final p in (r['passages'] as List? ?? [])) Map<String, dynamic>.from(p as Map)],
        [for (final u in (r['used'] as List? ?? [])) (u as num).toInt()],
        r['error'] as String?,
      ));
    } catch (e) {
      _answers.add(_Answer(q, null, const [], const [], '$e'));
    } finally {
      if (mounted) setState(() => _asking = null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PageHeader(title: 'Ask', subtitle: 'About anything you recorded. Answered on this Mac; nothing leaves it unless you chose a cloud model.'),
      Expanded(
        child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(32, 0, 32, 20), children: [
          Readable(
            max: 780,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_answers.isEmpty && _asking == null)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (i, e) in examples.indexed) ActionChip(key: Key('example_$i'), label: Text(e), onPressed: () => _ask(e)),
                ]),
              for (final a in _answers) _AnswerView(a: a),
              if (_asking != null) ...[
                _Bubble(_asking!),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text('Looking through your conversations…', style: TextStyle(color: t.ink2)),
                  ]),
                ),
              ],
            ]),
          ),
        ]),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(32, 10, 32, 18),
        child: Readable(
          max: 780,
          child: Row(children: [
            Expanded(
              child: TextField(
                key: const Key('askField'),
                controller: _q,
                focusNode: _focus,
                onSubmitted: _ask,
                decoration: const InputDecoration(hintText: 'Ask about your conversations   (⌘K)', prefixIcon: Icon(Icons.auto_awesome_outlined, size: 19)),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(onPressed: _asking == null ? () => _ask(_q.text) : null, icon: const Icon(Icons.arrow_upward)),
          ]),
        ),
      ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  const _Bubble(this.text);
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 18, left: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: context.t.liveSoft, borderRadius: BorderRadius.circular(14)),
          child: Text(text, style: const TextStyle(fontSize: 14.5)),
        ),
      );
}

class _AnswerView extends StatelessWidget {
  final _Answer a;
  const _AnswerView({required this.a});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final idx = a.used.isNotEmpty ? [for (final u in a.used) u - 1] : [for (var i = 0; i < a.passages.length && i < 4; i++) i];
    final seen = <String>{};
    final sources = [
      for (final i in idx)
        if (i >= 0 && i < a.passages.length && seen.add('${a.passages[i]['sid']}@${a.passages[i]['t']}')) a.passages[i],
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Bubble(a.q),
      const SizedBox(height: 12),
      if (a.passages.isEmpty)
        Text(a.error ?? "I couldn't find anything about that in your conversations.", style: TextStyle(color: t.ink2))
      else ...[
        if (a.text != null)
          SelectableText(a.text!.replaceAll(RegExp(r'\s*\[\d+(?:\s*,\s*\d+)*\]'), ''),
              key: const Key('answerText'), style: const TextStyle(fontFamily: 'Newsreader', fontSize: 18, height: 1.5))
        else
          Text(a.error != null ? 'No written answer (${a.error}). The closest moments:' : 'The closest moments:', style: TextStyle(color: t.ink2)),
        const SizedBox(height: 10),
        for (final p in sources)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: t.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.line)),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: p['sid'] == null ? null : () => NavScope.of(context).open(p['sid'] as int, at: (p['t'] as num?)?.toDouble()),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${DateFormat('EEE d MMM, HH:mm').format(epoch(p['at'] as num))} · ${p['kind']}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.liveInk)),
                    const SizedBox(height: 3),
                    Text('${p['text']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, height: 1.4, color: t.ink2)),
                  ]),
                ),
              ),
            ),
          ),
      ],
    ]);
  }
}
