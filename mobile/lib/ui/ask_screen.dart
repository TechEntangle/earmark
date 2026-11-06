// Ask: questions about everything heard, answered on the phone with links to the moments.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import 'phone_lists.dart';
import 'theme.dart';

class AskScreen extends StatefulWidget {
  final EarmarkController c;
  const AskScreen({super.key, required this.c});
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  final List<AskAnswer> _answers = [];
  String? _asking;

  static const examples = [
    'What did I promise to do this week?',
    'What did we decide about the budget?',
    'What is Sam waiting on from me?',
    'Summarise yesterday',
  ];

  Future<void> _ask(String q) async {
    q = q.trim();
    if (q.isEmpty || _asking != null) return;
    _q.clear();
    setState(() => _asking = q);
    try {
      final a = await widget.c.ask(q, previous: _answers.lastOrNull);
      if (mounted) setState(() => _answers.add(a));
    } finally {
      if (mounted) setState(() => _asking = null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    widget.c.navRequest.addListener(_fromSiri);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fromSiri());
  }

  /// "Ask Earmark …" from Siri or a shortcut.
  void _fromSiri() {
    final q = widget.c.pendingQuestion;
    if (q == null || !mounted) return;
    widget.c.pendingQuestion = null;
    if (q.isNotEmpty) _ask(q);
  }

  @override
  void dispose() {
    widget.c.navRequest.removeListener(_fromSiri);
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t, c = widget.c;
    return Scaffold(
      appBar: AppBar(title: const Text('Ask')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => Column(children: [
          Expanded(
            child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
              if (_answers.isEmpty && _asking == null) ...[
                Text('Ask about anything you heard: decisions, promises, names, numbers. Answers come from this phone only.',
                    style: TextStyle(fontSize: 15, height: 1.45, color: t.ink2)),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in examples) ActionChip(key: Key('example_${examples.indexOf(e)}'), label: Text(e), onPressed: () => _ask(e)),
                ]),
                if (c.askPending > 0) ...[
                  const SizedBox(height: 16),
                  Text('Indexing ${c.askPending} conversation${c.askPending == 1 ? '' : 's'}…', style: TextStyle(fontSize: 13, color: t.ink2)),
                ],
                if (!c.notesOn) ...[
                  const SizedBox(height: 16),
                  Text('${notesHint(c)} Until then, Ask shows the closest moments without writing an answer.',
                      style: TextStyle(fontSize: 13, color: t.ink2)),
                ],
              ],
              for (final a in _answers) _AnswerCard(c: c, a: a),
              if (_asking != null) ...[
                _Bubble(text: _asking!),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text('Looking through what you heard…', style: TextStyle(color: t.ink2)),
                  ]),
                ),
              ],
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('askField'),
                    controller: _q,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _ask,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: 'Ask about your conversations'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('askSend'),
                  tooltip: 'Ask',
                  onPressed: _asking == null ? () => _ask(_q.text) : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  const _Bubble({required this.text});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 16, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: context.t.live.withValues(alpha: .18), borderRadius: BorderRadius.circular(16)),
          child: Text(text, style: const TextStyle(fontSize: 15)),
        ),
      );
}

class _AnswerCard extends StatelessWidget {
  final EarmarkController c;
  final AskAnswer a;
  const _AnswerCard({required this.c, required this.a});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // the passages the answer used, else the best few
    final idx = a.used.isNotEmpty ? [for (final i in a.used) i - 1] : [for (var i = 0; i < a.hits.length && i < 4; i++) i];
    final seen = <String>{};
    final sources = [
      for (final i in idx)
        if (i >= 0 && i < a.hits.length && seen.add('${a.hits[i].$1.conv}@${a.hits[i].$1.at}')) a.hits[i].$1,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Bubble(text: a.question),
      const SizedBox(height: 10),
      if (a.fromMac) ...[
        if (a.text != null)
          Text(a.text!, key: const Key('answerText'), style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17.5, height: 1.5)),
        const SizedBox(height: 6),
        Text('From your Mac', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ink3)),
        const SizedBox(height: 6),
        for (final p in [
          for (final u in (a.used.isNotEmpty ? a.used : [1, 2, 3]))
            if (u >= 1 && u <= a.macPassages.length) a.macPassages[u - 1],
        ])
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(DateFormat('EEE d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(((p['at'] as num) * 1000).round())),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.liveInk)),
              const SizedBox(height: 4),
              Text('${p['text']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.4, color: t.ink2)),
            ]),
          ),
      ] else if (a.hits.isEmpty)
        Text("I couldn't find anything about that on this phone${c.link == Link.online ? ' or your Mac' : ''}.",
            style: TextStyle(fontSize: 15, color: t.ink2))
      else ...[
        if (a.text != null)
          Text(a.text!.replaceAll(RegExp(r'\s*\[\d+(?:\s*,\s*\d+)*\]'), ''), key: const Key('answerText'), style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17.5, height: 1.5)),
        if (a.text == null)
          Text(a.error != null ? '${a.error}. The closest moments:' : 'The closest moments:',
              style: TextStyle(fontSize: 14, color: t.ink2)),
        const SizedBox(height: 10),
        for (final p in sources)
          if (c.convs?.byId(p.conv) case final v?)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PhoneConversationScreen(c: c, id: v.id, focusAt: p.kind == 'talk' ? p.at : null))),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      '${DateFormat('EEE d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(((v.start + p.at) * 1000).round()))}'
                      '  ·  ${c.convTitleText(v)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.liveInk)),
                  const SizedBox(height: 4),
                  Text(p.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.4, color: t.ink2)),
                ]),
              ),
            ),
      ],
    ]);
  }
}
