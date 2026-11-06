// What this phone heard, transcribed on the phone itself.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../transcribe/heard.dart';
import 'theme.dart';

/// Home card: the latest words heard, or how the speech model is getting on.
class HeardCard extends StatelessWidget {
  final EarmarkController c;
  const HeardCard({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (!c.asrOn) return const SizedBox.shrink();
    final a = c.asr;
    if (!a.ready && (a.busy || (c.asrError == null && a.state == 'idle'))) {
      final pct = (a.progress * 100).clamp(0, 100).round();
      final label = a.state == 'loading' || a.onDisk
          ? 'Loading the speech model…'
          : 'Getting the speech model · ${pct > 0 ? '$pct%' : 'starting'}';
      return _panel(context, key: const Key('asrPreparing'), children: [
        Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: a.state == 'downloading' && a.progress > 0 ? a.progress : null, minHeight: 4,
              color: t.live, backgroundColor: t.line),
        ),
        const SizedBox(height: 8),
        Text(a.onDisk ? 'A few seconds.' : 'About 480 MB, once. Keep Earmark open until it finishes.',
            style: TextStyle(fontSize: 13, color: t.ink2)),
      ]);
    }
    if (!a.ready) {
      return _panel(context, key: const Key('asrError'), children: [
        Text("The speech model didn't load", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.due)),
        const SizedBox(height: 4),
        Text('${c.asrError ?? a.error ?? 'Unknown problem'}. Your Mac transcribes meanwhile.',
            maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.ink2)),
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: c.prepareAsr, child: const Text('Try again'))),
      ]);
    }
    final langs = a.languages;
    Widget? extra;
    if (langs != null && langs.busy) {
      final pct = (langs.progress * 100).clamp(0, 100).round();
      extra = _panel(context, key: const Key('langPreparing'), children: [
        Text(langs.state == 'loading' || langs.onDisk
            ? 'Loading the language check…'
            : 'Getting the language check · ${pct > 0 ? '$pct%' : 'starting'}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: langs.state == 'downloading' && langs.progress > 0 ? langs.progress : null,
              minHeight: 3, color: t.live, backgroundColor: t.line),
        ),
        const SizedBox(height: 6),
        Text('About 140 MB, once. It tells English from other languages, which your Mac translates.',
            style: TextStyle(fontSize: 12.5, color: t.ink2)),
      ]);
    } else if (langs != null && langs.state == 'error') {
      extra = _panel(context, key: const Key('langError'), children: [
        Text("The language check didn't load", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.due)),
        Text('${langs.error ?? ''} Your Mac checks the language meanwhile.', maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: t.ink2)),
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: c.retryLanguages, child: const Text('Try again'))),
      ]);
    }
    final s = c.heard?.latest();
    if (s == null) return extra ?? const SizedBox.shrink();
    final card = _heard(context, s);
    return extra == null ? card : Column(children: [extra, const SizedBox(height: 10), card]);
  }

  Widget _heard(BuildContext context, Stretch s) {
    final t = context.t;
    var text = s.text;
    if (text.length > 260) text = '…${text.substring(text.length - 260).replaceFirst(RegExp(r'^\S*\s'), '')}';
    return InkWell(
      key: const Key('heardCard'),
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HeardScreen(c: c))),
      child: _panel(context, children: [
        Row(children: [
          Text('HEARD', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: t.ink2)),
          const SizedBox(width: 8),
          Text('${DateFormat.Hm().format(s.startTime)}–${DateFormat.Hm().format(s.endTime)}',
              style: TextStyle(fontSize: 12.5, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()])),
          const Spacer(),
          Icon(Icons.chevron_right, size: 18, color: t.ink2),
        ]),
        const SizedBox(height: 8),
        Text(text, maxLines: 5, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17, height: 1.4)),
      ]),
    );
  }

  Widget _panel(BuildContext context, {Key? key, required List<Widget> children}) => Container(
        key: key,
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(color: context.t.surface, border: Border.all(color: context.t.line), borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

/// Everything heard on this phone, by day and stretch, newest first.
class HeardScreen extends StatelessWidget {
  final EarmarkController c;
  const HeardScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Heard on iPhone')),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final h = c.heard, t = context.t;
            final days = h?.days() ?? const <String>[];
            final rows = <Widget>[];
            for (final d in days) {
              final stretches = h!.stretches(d).where((s) => s.text.isNotEmpty).toList();
              if (stretches.isEmpty) continue;
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
                child: Text(DateFormat('EEEE, d MMM').format(DateTime.parse(d)).toUpperCase(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: t.ink2)),
              ));
              for (final s in stretches) {
                rows.add(_StretchTile(s: s));
              }
            }
            if (rows.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Nothing yet. What the pendant hears shows up here within a minute.',
                      textAlign: TextAlign.center, style: TextStyle(color: t.ink2)),
                ),
              );
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: rows);
          },
        ),
      );
}

class _StretchTile extends StatelessWidget {
  final Stretch s;
  const _StretchTile({required this.s});
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${DateFormat.Hm().format(s.startTime)}–${DateFormat.Hm().format(s.endTime)}  ·  ${dur(s.seconds)}',
            style: TextStyle(fontSize: 12.5, color: t.ink2, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 6),
        SelectableText(s.text, style: const TextStyle(fontFamily: 'Newsreader', fontSize: 17, height: 1.45)),
      ]),
    );
  }
}
