// Conversations, notes and tasks made on the iPhone.
//
// What the phone heard (see transcribe/heard.dart) is grouped into conversations: chunks with less
// than [gap] seconds of silence between them belong together, as on the Mac. When a conversation
// has been quiet for longer than that it is closed, and Apple's on-device model writes its title,
// summary and tasks. Everything is kept on the phone (conversations.json, 30 days).
import 'dart:convert';
import 'dart:io';

import '../transcribe/heard.dart';

class ConvTask {
  final String id;
  String text;
  String owner;
  String due;
  bool done;
  final double at; // epoch seconds of the conversation it came from
  ConvTask({required this.id, required this.text, this.owner = 'me', this.due = '', this.done = false, required this.at});

  bool get mine => ['me', 'unknown', ''].contains(owner.toLowerCase());

  Map<String, Object> toJson() => {'id': id, 'text': text, 'owner': owner, 'due': due, 'done': done, 'at': at};
  static ConvTask fromJson(Map m) => ConvTask(
      id: '${m['id']}', text: '${m['text'] ?? ''}', owner: '${m['owner'] ?? 'me'}', due: '${m['due'] ?? ''}',
      done: m['done'] == true, at: (m['at'] as num?)?.toDouble() ?? 0);
}

class Conversation {
  final int id; // the first chunk's sequence number
  double start, end;
  List<int> seqs;
  /// open (still going) | pending (waiting for notes) | ready | failed | empty (no words)
  String status;
  String? title, kind, summary, error;
  List<String> keyPoints, decisions, people, topics;
  List<ConvTask> tasks;
  int attempts;
  int words;

  Conversation(this.id, this.start, this.end, this.seqs,
      {this.status = 'open', this.title, this.kind, this.summary, this.error, List<String>? keyPoints, List<String>? decisions,
      List<String>? people, List<String>? topics, List<ConvTask>? tasks, this.attempts = 0, this.words = 0})
      : keyPoints = keyPoints ?? [],
        decisions = decisions ?? [],
        people = people ?? [],
        topics = topics ?? [],
        tasks = tasks ?? [];

  double get seconds => end - start;
  DateTime get startTime => DateTime.fromMillisecondsSinceEpoch((start * 1000).round());
  bool get visible => status != 'empty';
  int get openTasks => tasks.where((t) => !t.done).length;

  Map<String, Object?> toJson() => {
        'id': id, 'start': start, 'end': end, 'seqs': seqs, 'status': status, 'title': title, 'kind': kind,
        'summary': summary, 'error': error, 'keyPoints': keyPoints, 'decisions': decisions, 'people': people,
        'topics': topics, 'tasks': [for (final t in tasks) t.toJson()], 'attempts': attempts, 'words': words,
      };

  static Conversation fromJson(Map m) {
    List<String> strs(Object? v) => [for (final x in (v as List? ?? [])) '$x'];
    return Conversation(m['id'] as int, (m['start'] as num).toDouble(), (m['end'] as num).toDouble(),
        [for (final s in (m['seqs'] as List? ?? [])) s as int],
        status: '${m['status'] ?? 'open'}', title: m['title'] as String?, kind: m['kind'] as String?,
        summary: m['summary'] as String?, error: m['error'] as String?, keyPoints: strs(m['keyPoints']),
        decisions: strs(m['decisions']), people: strs(m['people']), topics: strs(m['topics']),
        tasks: [for (final t in (m['tasks'] as List? ?? [])) ConvTask.fromJson(t as Map)],
        attempts: (m['attempts'] as num?)?.toInt() ?? 0, words: (m['words'] as num?)?.toInt() ?? 0);
  }
}

const languageNames = {
  'hi': 'Hindi', 'mr': 'Marathi', 'ur': 'Urdu', 'gu': 'Gujarati', 'bn': 'Bengali', 'ta': 'Tamil', 'te': 'Telugu',
  'kn': 'Kannada', 'ml': 'Malayalam', 'pa': 'Punjabi', 'ar': 'Arabic', 'fa': 'Persian', 'de': 'German', 'fr': 'French',
  'es': 'Spanish', 'it': 'Italian', 'ru': 'Russian', 'zh': 'Chinese', 'ja': 'Japanese', 'ko': 'Korean', 'tr': 'Turkish',
  'pt': 'Portuguese', 'nl': 'Dutch', 'ne': 'Nepali', 'si': 'Sinhala',
};

/// Spoken requests to Earmark itself ("remind me to…", "add a task…"), as on the Mac.
final commandPattern = RegExp(
    r"\b(remind me|set (a|me a) reminder|create (a |an )?(task|reminder|to-?do)|make (a |an )?(task|reminder|to-?do|note)|"
    r"add (a |an |this |it |that )?(task|reminder|to-?do|note)?\s*(to|in|on)?\s*(my|our|the)?\s*(tasks?|to-?dos?|list|reminders?)|"
    r"add (a |an )?(task|reminder|to-?do)|note to self|put (it|this|that) on (my|our|the) (list|tasks?))\b",
    caseSensitive: false);

final _sentenceEnd = RegExp(r'''[.?!…]['")\]]*$''');

class Line {
  final double at; // seconds from the conversation's start
  final String text;
  const Line(this.at, this.text);
}

class Conversations {
  final File file;
  final int keepDays;
  final List<Conversation> all = [];

  Conversations(this.file, {this.keepDays = 30}) {
    if (file.existsSync()) {
      try {
        all.addAll([for (final m in (jsonDecode(file.readAsStringSync()) as List)) Conversation.fromJson(m as Map)]);
      } catch (_) {/* start again rather than fail */}
    }
    final cutoff = DateTime.now().subtract(Duration(days: keepDays)).millisecondsSinceEpoch / 1000;
    all.removeWhere((c) => c.end < cutoff);
    all.sort((a, b) => b.start.compareTo(a.start));
  }

  void save() {
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode([for (final c in all) c.toJson()]), flush: true);
    tmp.renameSync(file.path);
  }

  List<Conversation> get visible => all.where((c) => c.visible).toList();

  /// Every task, newest conversation first.
  List<ConvTask> get tasks => [for (final c in all) ...c.tasks];

  Conversation? byId(int id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Group what was heard into conversations and close the ones that have gone quiet.
  /// Returns true when anything changed.
  bool sync(Heard heard, {required double gap, required double now}) {
    var changed = false;
    final chunks = heard.all();
    final groups = <List<HeardChunk>>[];
    for (final ch in chunks) {
      if (groups.isNotEmpty && ch.start - groups.last.last.end <= gap) {
        groups.last.add(ch);
      } else {
        groups.add([ch]);
      }
    }
    for (final g in groups) {
      final id = g.first.seq;
      final start = g.first.start, end = g.last.end;
      final seqs = [for (final ch in g) ch.seq];
      final words = g.fold<int>(
          0, (n, ch) => n + (ch.words.isNotEmpty ? ch.words.length : (ch.text.isEmpty ? 0 : ch.text.split(RegExp(r'\s+')).length)));
      var c = byId(id);
      if (c == null) {
        // a closed conversation that later chunks have joined (a late upload) is reopened under its first id
        c = Conversation(id, start, end, seqs, words: words);
        all.add(c);
        changed = true;
      } else if (c.seqs.length != seqs.length) {
        c
          ..end = end
          ..seqs = seqs
          ..words = words;
        if (c.status != 'open') c.status = 'open';
        changed = true;
      }
      if (c.status == 'open' && now - end > gap + 15) {
        c.status = words >= 3 ? 'pending' : 'empty';
        changed = true;
      }
    }
    // conversations whose chunks were merged into an earlier one
    final ids = {for (final g in groups) g.first.seq};
    final before = all.length;
    all.removeWhere((c) => !ids.contains(c.id) && c.end >= (chunks.isEmpty ? 0 : chunks.first.start));
    if (all.length != before) changed = true;
    all.sort((a, b) => b.start.compareTo(a.start));
    return changed;
  }

  /// The conversation as transcript lines (sentences), with times from its start.
  static List<Line> lines(Conversation c, Heard heard) {
    final out = <Line>[];
    final cur = StringBuffer();
    double? at;
    double lastEnd = -1;
    void flush() {
      final t = cur.toString().trim();
      if (t.isNotEmpty && at != null) out.add(Line(at!, t));
      cur.clear();
      at = null;
    }

    for (final seq in c.seqs) {
      final ch = heard.bySeq(seq);
      if (ch == null) continue;
      final base = ch.start - c.start;
      if (ch.words.isEmpty) {
        if (ch.text.isNotEmpty) {
          flush();
          out.add(Line(base, ch.text));
        }
        continue;
      }
      for (final w in ch.words) {
        final s = base + (w[0] as num).toDouble(), e = base + (w[1] as num).toDouble();
        final word = '${w[2]}';
        if (at != null && (s - lastEnd > 1.2 || s - at! > 30)) flush();
        at ??= s;
        cur.write(cur.isEmpty ? word : ' $word');
        lastEnd = e;
        if (_sentenceEnd.hasMatch(word)) flush();
      }
    }
    flush();
    return out;
  }

  static String clockText(double s) {
    final t = s.round();
    return '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
  }

  /// Languages translated into English in this conversation (names, e.g. "Hindi").
  static List<String> translatedFrom(Conversation c, Heard heard) {
    final out = <String>[];
    for (final seq in c.seqs) {
      final ch = heard.bySeq(seq);
      if (ch == null || !ch.translated) continue;
      final name = languageNames[ch.lang] ?? ch.lang;
      if (!out.contains(name)) out.add(name);
    }
    return out;
  }

  /// What the on-device model reads: "[mm:ss] text", ◆ for spoken requests, ★ near an earmark.
  static List<String> promptLines(Conversation c, Heard heard, List<double> earmarks) {
    return [
      for (final l in lines(c, heard))
        '${commandPattern.hasMatch(l.text) ? '◆ ' : ''}'
        '${earmarks.any((m) => c.start + l.at >= m - 20 && c.start + l.at <= m + 30) ? '★ ' : ''}'
        '[${clockText(l.at)}] ${l.text}',
    ];
  }

  /// Apply what the model wrote.
  static void applyNotes(Conversation c, Map<String, dynamic> n) {
    List<String> strs(Object? v) => [for (final x in (v as List? ?? [])) '$x'.trim()].where((x) => x.isNotEmpty).toList();
    c
      ..title = '${n['title'] ?? ''}'.trim()
      ..kind = n['kind'] as String?
      ..summary = '${n['summary'] ?? ''}'.trim()
      ..keyPoints = strs(n['keyPoints'])
      ..decisions = strs(n['decisions'])
      ..people = strs(n['people'])
      ..topics = strs(n['topics'])
      ..status = 'ready'
      ..error = null;
    final old = {for (final t in c.tasks) t.text.toLowerCase(): t};
    var k = 0;
    c.tasks = [
      for (final t in (n['tasks'] as List? ?? []))
        if ('${(t as Map)['task'] ?? ''}'.trim().isNotEmpty)
          ConvTask(
            id: '${c.id}-${k++}',
            text: '${t['task']}'.trim(),
            owner: '${t['owner'] ?? 'me'}'.trim(),
            due: '${t['dueText'] ?? ''}'.trim(),
            done: t['done'] == true || (old['${t['task']}'.trim().toLowerCase()]?.done ?? false),
            at: c.start,
          ),
    ];
  }
}
