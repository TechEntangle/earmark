// Custom vocabulary: names and terms you use, spelled the way you want (the same rules as the Mac's
// earmark/vocab.py). One entry per line:
//   RAKBANK                         a term: fixes its case ("rakbank") and split spellings ("rak bank")
//   rack bank, rag bank = RAKBANK   what the speech model writes instead, and the right spelling
// The transcript is corrected word by word (timings kept), and the terms go to the notes model.

const _punct = '.,!?;:"\'”“’)(';

String _strip(String w) {
  var a = 0, b = w.length;
  while (a < b && _punct.contains(w[a])) {
    a++;
  }
  while (b > a && _punct.contains(w[b - 1])) {
    b--;
  }
  return w.substring(a, b);
}

String _norm(String w) => _strip(w).toLowerCase();
List<String> _normWords(String s) => s.split(RegExp(r'\s+')).map(_norm).where((x) => x.isNotEmpty).toList();
String _letters(List<String> ws) => ws.join().replaceAll(RegExp(r'[^a-z0-9]'), '');

class Vocabulary {
  final List<(List<List<String>>, String)> entries;
  Vocabulary._(this.entries);

  factory Vocabulary.parse(String text) {
    final out = <(List<List<String>>, String)>[];
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      var right = line, heard = <String>[];
      final eq = line.indexOf('=');
      if (eq >= 0) {
        right = line.substring(eq + 1).trim();
        heard = line.substring(0, eq).split(',').map((h) => h.trim()).where((h) => h.isNotEmpty).toList();
      }
      if (right.isEmpty) continue;
      out.add(([for (final h in [...heard, right]) if (_normWords(h).isNotEmpty) _normWords(h)], right));
    }
    return Vocabulary._(out);
  }

  bool get isEmpty => entries.isEmpty;

  List<String> get terms {
    final seen = <String>{};
    return [for (final (_, r) in entries) if (seen.add(r.toLowerCase())) r];
  }

  /// For the notes model.
  String get promptLine => terms.isEmpty ? '' : 'Names and terms the wearer uses (spell them exactly like this): ${terms.join(', ')}.';

  bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Corrected tokens, each with the span of original tokens it replaces.
  (List<String>, List<(int, int)>) fixTokens(List<String> tokens) {
    final out = <String>[], spans = <(int, int)>[];
    final norm = tokens.map(_norm).toList();
    var i = 0;
    while (i < tokens.length) {
      (int, String)? hit;
      for (final (variants, right) in entries) {
        final want = _letters(_normWords(right));
        for (final k in [3, 2, 1]) {
          if (i + k > tokens.length) continue;
          final span = norm.sublist(i, i + k);
          if (variants.any((v) => _same(v, span)) || (want.length >= 4 && _letters(span) == want)) {
            hit = (k, right);
            break;
          }
        }
        if (hit != null) break;
      }
      if (hit != null) {
        final (k, right) = hit;
        final first = tokens[i], last = tokens[i + k - 1];
        final lead = first.substring(0, first.length - first.replaceFirst(RegExp('^[${RegExp.escape(_punct)}]+'), '').length);
        final core = last.replaceFirst(RegExp('[${RegExp.escape(_punct)}]+\$'), '');
        out.add('$lead$right${last.substring(core.length)}');
        spans.add((i, i + k));
        i += k;
      } else {
        out.add(tokens[i]);
        spans.add((i, i + 1));
        i++;
      }
    }
    return (out, spans);
  }

  /// Text and [start, end, word] words, corrected.
  (String, List<List<Object>>) fix(String text, List<List<Object>> words) {
    if (isEmpty) return (text, words);
    if (words.isNotEmpty) {
      final (toks, spans) = fixTokens([for (final w in words) '${w[2]}']);
      final ws = [for (final (j, t) in toks.indexed) <Object>[words[spans[j].$1][0], words[spans[j].$2 - 1][1], t]];
      return (toks.join(' '), ws);
    }
    return (fixTokens(text.split(' ')).$1.join(' '), words);
  }
}
