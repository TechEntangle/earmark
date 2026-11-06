// What this phone heard: the on-device transcript of every recording chunk, kept on the phone
// (one JSON line per chunk, one file per day, 30 days of history).
import 'dart:convert';
import 'dart:io';

class HeardChunk {
  final int seq;
  final double start; // epoch seconds
  final double seconds;
  final String text;
  final List<List<Object>> words; // [start, end, word], seconds from [start]
  /// "en", another language (heard on the phone; your Mac transcribes and translates it), or "" (unknown)
  final String lang;
  /// whether the language was checked on the phone
  final bool checked;
  /// the text came from your Mac (its English translation of another language)
  final bool fromMac;
  const HeardChunk(this.seq, this.start, this.seconds, this.text, this.words,
      {this.lang = '', this.checked = false, this.fromMac = false});

  /// Speech in another language.
  bool get foreign => lang.isNotEmpty && lang != 'en';
  /// Another language, still waiting for your Mac's translation.
  bool get awaitingMac => foreign && !fromMac;
  /// Another language, translated by your Mac.
  bool get translated => foreign && fromMac && text.isNotEmpty;

  HeardChunk copyAt(double at) => HeardChunk(seq, at, seconds, text, words, lang: lang, checked: checked, fromMac: fromMac);

  HeardChunk withMacText(String t, List<List<Object>> w) =>
      HeardChunk(seq, start, seconds, t, w, lang: lang, checked: checked, fromMac: true);

  double get end => start + seconds;
  DateTime get startTime => DateTime.fromMillisecondsSinceEpoch((start * 1000).round());
  DateTime get endTime => DateTime.fromMillisecondsSinceEpoch((end * 1000).round());

  Map<String, Object> toJson() =>
      {'seq': seq, 'start': start, 'seconds': seconds, 'text': text, 'words': words, 'lang': lang, 'checked': checked,
       'fromMac': fromMac};
  static HeardChunk? fromJson(Map m) {
    final seq = m['seq'], start = m['start'];
    if (seq is! int || start is! num) return null;
    return HeardChunk(seq, start.toDouble(), (m['seconds'] as num?)?.toDouble() ?? 0, '${m['text'] ?? ''}',
        [for (final w in (m['words'] as List? ?? [])) if (w is List && w.length == 3) [w[0] as Object, w[1] as Object, '${w[2]}']],
        lang: '${m['lang'] ?? ''}', checked: m['checked'] == true, fromMac: m['fromMac'] == true);
  }
}

/// Chunks that follow each other without a gap, read as one stretch of conversation.
class Stretch {
  final List<HeardChunk> chunks;
  Stretch(this.chunks);
  DateTime get startTime => chunks.first.startTime;
  DateTime get endTime => chunks.last.endTime;
  double get seconds => chunks.last.end - chunks.first.start;
  String get text => chunks
      .map((c) => c.awaitingMac ? pendingLabel : c.text)
      .where((t) => t.isNotEmpty)
      .fold<List<String>>([], (l, t) => l.isNotEmpty && l.last == t && t == pendingLabel ? l : (l..add(t)))
      .join(' ');
}

/// Shown where speech in another language waits for your Mac.
const pendingLabel = '[Non-English · translating on your Mac]';

class Heard {
  final Directory dir;
  final int keepDays;
  final Set<int> _seqs = {};
  final Map<String, List<HeardChunk>> _days = {};

  Heard(this.dir, {this.keepDays = 30}) {
    dir.createSync(recursive: true);
    _prune();
    for (final f in _files()) {
      final day = _dayOf(f);
      final list = _read(f);
      _days[day] = list;
      _seqs.addAll(list.map((c) => c.seq));
    }
  }

  bool has(int seq) => _seqs.contains(seq);

  HeardChunk? bySeq(int seq) {
    for (final l in _days.values) {
      for (final c in l) {
        if (c.seq == seq) return c;
      }
    }
    return null;
  }

  /// Replace a chunk's record (e.g. with your Mac's translation).
  void replace(HeardChunk c) {
    final day = _key(c.startTime);
    final list = _days[day];
    if (list == null) return;
    final i = list.indexWhere((x) => x.seq == c.seq);
    if (i < 0) return;
    list[i] = c;
    final f = File('${dir.path}/$day.jsonl');
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(list.map((x) => '${jsonEncode(x.toJson())}\n').join(), flush: true);
    tmp.renameSync(f.path);
  }

  void add(HeardChunk c) {
    if (_seqs.contains(c.seq)) return;
    final day = _key(c.startTime);
    final f = File('${dir.path}/$day.jsonl');
    f.writeAsStringSync('${jsonEncode(c.toJson())}\n', mode: FileMode.append, flush: true);
    (_days[day] ??= []).add(c);
    _days[day]!.sort((a, b) => a.start.compareTo(b.start));
    _seqs.add(c.seq);
  }

  /// Every chunk, oldest first.
  List<HeardChunk> all() {
    final out = <HeardChunk>[];
    for (final d in (_days.keys.toList()..sort())) {
      out.addAll(_days[d]!);
    }
    return out;
  }

  /// Days with anything heard, newest first.
  List<String> days() => (_days.keys.toList()..sort()).reversed.toList();

  /// The stretches of one day ("yyyy-mm-dd"), newest first.
  List<Stretch> stretches(String day, {double gapSeconds = 3}) {
    final out = <Stretch>[];
    List<HeardChunk>? cur;
    for (final c in _days[day] ?? const <HeardChunk>[]) {
      if (cur != null && c.start - cur.last.end <= gapSeconds) {
        cur.add(c);
      } else {
        cur = [c];
        out.add(Stretch(cur));
      }
    }
    return out.reversed.toList();
  }

  /// The most recent stretch with words in it, if any (today or yesterday).
  Stretch? latest() {
    for (final d in days().take(2)) {
      for (final s in stretches(d)) {
        if (s.text.isNotEmpty) return s;
      }
    }
    return null;
  }

  static String _key(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  static String dayKey(DateTime t) => _key(t);

  Iterable<File> _files() => dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'));
  String _dayOf(File f) => f.uri.pathSegments.last.replaceAll('.jsonl', '');

  List<HeardChunk> _read(File f) {
    final out = <HeardChunk>[];
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final c = HeardChunk.fromJson(jsonDecode(line) as Map);
        if (c != null) out.add(c);
      } catch (_) {/* a half-written last line after a crash */}
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  void _prune() {
    final cutoff = _key(DateTime.now().subtract(Duration(days: keepDays)));
    for (final f in _files()) {
      if (_dayOf(f).compareTo(cutoff) < 0) f.deleteSync();
    }
  }
}
