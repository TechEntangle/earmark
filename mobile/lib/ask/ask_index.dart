// Ask: everything heard on this phone, searchable by meaning and by words.
//
// Each conversation becomes passages: its notes, each task, and the transcript in windows of about
// 70 words (with speaker names). Each passage gets a sentence vector from Apple's built-in
// embedding, kept on the phone (ask/passages.json + ask/vectors.bin, float32). A question is
// matched both by meaning (cosine) and by its words, and the best passages go to the answer.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../notes/conversations.dart';
import '../transcribe/heard.dart';

class Passage {
  final int conv;
  final double at; // seconds from the conversation's start
  final String kind; // notes | task | talk
  final String text;
  const Passage(this.conv, this.at, this.kind, this.text);

  Map<String, Object> toJson() => {'c': conv, 'at': at, 'k': kind, 't': text};
  static Passage fromJson(Map m) =>
      Passage(m['c'] as int, (m['at'] as num).toDouble(), '${m['k']}', '${m['t']}');
}

typedef Embed = Future<List<List<double>>> Function(List<String> texts);

const _stop = {
  'the', 'and', 'for', 'with', 'that', 'this', 'what', 'when', 'where', 'who', 'did', 'does', 'was', 'were',
  'are', 'you', 'your', 'about', 'from', 'have', 'has', 'had', 'will', 'would', 'should', 'could', 'can',
  'how', 'why', 'which', 'there', 'their', 'they', 'them', 'any', 'all', 'our', 'out', 'into', 'over',
  'tell', 'say', 'said', 'just', 'like', 'get', 'got', 'than', 'then', 'also', 'its', "it's", 'his', 'her',
};

List<String> terms(String s) => s
    .toLowerCase()
    .split(RegExp(r"[^a-z0-9']+"))
    .where((w) => w.length >= 3 && !_stop.contains(w))
    .toList();

class AskIndex {
  final Directory dir;
  final List<Passage> passages = [];
  final List<Float32List> vectors = [];
  /// conversation id → what it looked like when indexed (re-index when it changes)
  final Map<int, String> indexed = {};
  int dim = 0;

  AskIndex(this.dir) {
    dir.createSync(recursive: true);
    try {
      final m = jsonDecode(File('${dir.path}/passages.json').readAsStringSync()) as Map;
      dim = m['dim'] as int;
      passages.addAll([for (final p in m['passages'] as List) Passage.fromJson(p as Map)]);
      indexed.addAll({for (final e in (m['indexed'] as Map).entries) int.parse('${e.key}'): '${e.value}'});
      final bytes = File('${dir.path}/vectors.bin').readAsBytesSync();
      final all = bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
      for (var i = 0; i < passages.length; i++) {
        vectors.add(Float32List.fromList(all.sublist(i * dim, (i + 1) * dim)));
      }
      if (vectors.length != passages.length) throw const FormatException('mismatch');
    } catch (_) {
      passages.clear();
      vectors.clear();
      indexed.clear();
      dim = 0;
    }
  }

  void save() {
    final b = BytesBuilder(copy: false);
    for (final v in vectors) {
      b.add(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes));
    }
    final vf = File('${dir.path}/vectors.bin.tmp')..writeAsBytesSync(b.takeBytes(), flush: true);
    final pf = File('${dir.path}/passages.json.tmp')
      ..writeAsStringSync(jsonEncode({
        'dim': dim,
        'passages': [for (final p in passages) p.toJson()],
        'indexed': {for (final e in indexed.entries) '${e.key}': e.value},
      }), flush: true);
    vf.renameSync('${dir.path}/vectors.bin');
    pf.renameSync('${dir.path}/passages.json');
  }

  static String signature(Conversation c) => [
        c.status, c.words, c.spk, c.userTitle ?? c.title, c.tasks.length, c.edits.length,
        c.voices.values.map((v) => v['name'] ?? '').join(','),
      ].join('|');

  /// The passages of one conversation.
  static List<Passage> passagesOf(Conversation c, Heard heard) {
    final out = <Passage>[];
    if (c.status == 'ready') {
      final notes = [
        if ((c.userTitle ?? c.title ?? '').isNotEmpty) c.userTitle ?? c.title!,
        if ((c.summary ?? '').isNotEmpty) c.summary!,
        ...c.keyPoints,
        if (c.decisions.isNotEmpty) 'Decided: ${c.decisions.join('; ')}',
      ].join('\n');
      if (notes.trim().isNotEmpty) out.add(Passage(c.id, 0, 'notes', notes));
      for (final t in c.tasks) {
        out.add(Passage(c.id, 0, 'task',
            'Task${t.mine ? ' for me' : ' for ${t.owner}'}${t.due.isNotEmpty ? ' (${t.due})' : ''}: ${t.text}${t.done ? ' (done)' : ''}'));
      }
    }
    final lines = Conversations.lines(c, heard).where((l) => !l.pending).toList();
    var i = 0;
    while (i < lines.length) {
      final buf = StringBuffer();
      var n = 0, j = i;
      String? last;
      while (j < lines.length && n < 70) {
        final l = lines[j];
        final who = l.speaker == null ? null : c.label(l.speaker!, guesses: false);
        buf.write(who != null && who != last ? '${buf.isEmpty ? '' : '\n'}$who: ${l.text}' : '${buf.isEmpty ? '' : ' '}${l.text}');
        last = who ?? last;
        n += l.text.split(' ').length;
        j++;
      }
      out.add(Passage(c.id, lines[i].at, 'talk', buf.toString()));
      i = j > i + 1 ? j - 1 : j; // one line of overlap
      if (j >= lines.length) break;
    }
    return out;
  }

  /// Index conversations that are new or changed (at most [limit] per call). True when anything changed.
  Future<bool> update(List<Conversation> convs, Heard heard, Embed embed, {int limit = 3}) async {
    var changed = false;
    final ids = {for (final c in convs) c.id};
    // gone from the phone
    final gone = indexed.keys.where((id) => !ids.contains(id)).toList();
    for (final id in gone) {
      _drop(id);
      changed = true;
    }
    var done = 0;
    for (final c in convs) {
      if (done >= limit) break;
      if (c.status == 'open' || c.status == 'empty' || Conversations.awaitingMac(c, heard)) continue;
      final sig = signature(c);
      if (indexed[c.id] == sig) continue;
      final ps = passagesOf(c, heard);
      var vecs = <List<double>>[];
      if (ps.isNotEmpty) {
        try {
          vecs = await embed([for (final p in ps) p.text]);
        } catch (_) {/* words only */}
      }
      _drop(c.id);
      for (var k = 0; k < ps.length; k++) {
        // without a vector (the phone's sentence model isn't available) a passage is still found by its words
        final v = k < vecs.length ? vecs[k] : const <double>[];
        if (v.isNotEmpty && dim == 0) {
          dim = v.length;
          for (var i = 0; i < vectors.length; i++) {
            vectors[i] = Float32List(dim);
          }
        }
        passages.add(ps[k]);
        vectors.add(v.isNotEmpty && v.length == dim ? Float32List.fromList(_unit(v)) : Float32List(dim));
      }
      indexed[c.id] = sig;
      done++;
      changed = true;
    }
    if (changed) save();
    return changed;
  }

  int pending(List<Conversation> convs, Heard heard) => convs
      .where((c) => c.status != 'open' && c.status != 'empty' && !Conversations.awaitingMac(c, heard))
      .where((c) => indexed[c.id] != signature(c))
      .length;

  void _drop(int id) {
    for (var i = passages.length - 1; i >= 0; i--) {
      if (passages[i].conv == id) {
        passages.removeAt(i);
        vectors.removeAt(i);
      }
    }
    indexed.remove(id);
  }

  static List<double> _unit(List<double> v) {
    final n = sqrt(v.fold<double>(0, (a, x) => a + x * x));
    return n == 0 ? v : [for (final x in v) x / n];
  }

  /// The passages of conversations between [from] and [to] (epoch seconds): notes first.
  List<Passage> during(List<Conversation> convs, double from, double to, {int k = 10}) {
    final inside = {for (final c in convs) if (c.start < to && c.end > from) c.id};
    final ps = passages.where((p) => inside.contains(p.conv)).toList()
      ..sort((a, b) => (a.kind == 'notes' ? 0 : 1).compareTo(b.kind == 'notes' ? 0 : 1));
    final per = <int, int>{};
    return [
      for (final p in ps)
        if ((per[p.conv] = (per[p.conv] ?? 0) + 1) <= 2) p,
    ].take(k).toList();
  }

  /// The best passages for a question: meaning (cosine) and words together.
  List<(Passage, double)> search(String question, List<double> qvec, {int k = 8}) {
    final q = qvec.isEmpty || qvec.length != dim ? null : _unit(qvec);
    final qt = terms(question).toSet();
    // rarer words count more
    final df = <String, int>{};
    final pts = [for (final p in passages) terms(p.text).toSet()];
    for (final s in pts) {
      for (final w in s.intersection(qt)) {
        df[w] = (df[w] ?? 0) + 1;
      }
    }
    final n = max(1, passages.length);
    final wsum = qt.fold<double>(0, (a, w) => a + log(1 + n / (1 + (df[w] ?? 0))));
    final scored = <(Passage, double)>[];
    for (var i = 0; i < passages.length; i++) {
      var cos = 0.0;
      if (q != null && vectors[i].length == dim) {
        final v = vectors[i];
        for (var d = 0; d < dim; d++) {
          cos += q[d] * v[d];
        }
      }
      var kw = 0.0;
      if (wsum > 0) {
        for (final w in pts[i].intersection(qt)) {
          kw += log(1 + n / (1 + (df[w] ?? 0)));
        }
        kw /= wsum;
      }
      final s = (q == null ? 0 : 0.6 * cos) + (q == null ? 1.0 : 0.4) * kw + (passages[i].kind == 'notes' ? 0.02 : 0);
      scored.add((passages[i], s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    if (scored.isEmpty) return const [];
    final top = scored.first.$2;
    scored.removeWhere((x) => x.$2 < top * 0.5 || x.$2 <= 0.03); // only what's close to the best match
    // at most three passages from one conversation, so answers can draw on several
    final per = <int, int>{};
    final out = <(Passage, double)>[];
    for (final x in scored) {
      if ((per[x.$1.conv] ?? 0) >= 3) continue;
      per[x.$1.conv] = (per[x.$1.conv] ?? 0) + 1;
      out.add(x);
      if (out.length >= k) break;
    }
    return out;
  }
}

/// The stretch of time a question is about, if it names one ("today", "yesterday", "on Monday",
/// "this week", "last week"): (from, to).
(DateTime, DateTime)? askSpan(String question, DateTime now) {
  final q = question.toLowerCase();
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int back) => today.subtract(Duration(days: back));
  if (RegExp(r'\b(today|this morning|this afternoon|tonight|this evening)\b').hasMatch(q)) return (today, now);
  if (RegExp(r'\byesterday\b').hasMatch(q)) return (day(1), today);
  if (RegExp(r'\bthis week\b').hasMatch(q)) return (day(today.weekday - 1), now);
  if (RegExp(r'\blast week\b').hasMatch(q)) {
    final mon = day(today.weekday - 1);
    return (mon.subtract(const Duration(days: 7)), mon);
  }
  const names = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
  for (var i = 0; i < 7; i++) {
    if (RegExp('\\b(on |last )?${names[i]}\\b').hasMatch(q)) {
      var back = (today.weekday - (i + 1)) % 7;
      if (back == 0) back = 7; // "on Monday" said on a Monday: last week's
      final d = day(back);
      return (d, d.add(const Duration(days: 1)));
    }
  }
  return null;
}
