// Voices this phone knows, by name. Each is the running (duration-weighted) sum of the voice
// signatures of every stretch that was named as that person, so it gets better as you name more.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class Voice {
  String name;
  List<double> sum;
  double weight; // seconds of speech behind it
  Voice(this.name, this.sum, this.weight);

  List<double> get vector => unit(sum);

  Map<String, Object> toJson() => {'name': name, 'sum': sum, 'weight': weight};
  static Voice fromJson(Map m) =>
      Voice('${m['name']}', [for (final x in (m['sum'] as List? ?? [])) (x as num).toDouble()], (m['weight'] as num?)?.toDouble() ?? 0);
}

List<double> unit(List<double> v) {
  final n = sqrt(v.fold<double>(0, (a, x) => a + x * x));
  return n == 0 ? v : [for (final x in v) x / n];
}

double cosine(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  final ua = unit(a), ub = unit(b);
  var s = 0.0;
  for (var i = 0; i < ua.length; i++) {
    s += ua[i] * ub[i];
  }
  return s;
}

class VoiceBook {
  /// Named automatically at or above this similarity; suggested ("Rahul?") from [suggest].
  static const auto = 0.68, suggest = 0.55;

  final File file;
  final List<Voice> voices = [];

  VoiceBook(this.file) {
    if (file.existsSync()) {
      try {
        voices.addAll([for (final m in jsonDecode(file.readAsStringSync()) as List) Voice.fromJson(m as Map)]);
      } catch (_) {}
    }
  }

  void save() {
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode([for (final v in voices) v.toJson()]), flush: true);
    tmp.renameSync(file.path);
  }

  Voice? byName(String name) {
    for (final v in voices) {
      if (v.name.toLowerCase() == name.toLowerCase()) return v;
    }
    return null;
  }

  /// The closest known voice and how close (cosine similarity), or null when none.
  (Voice, double)? closest(List<double> embedding) {
    (Voice, double)? best;
    for (final v in voices) {
      final s = cosine(v.sum, embedding);
      if (best == null || s > best.$2) best = (v, s);
    }
    return best;
  }

  /// Learn a voice: [embedding] of [seconds] of speech is [name].
  void learn(String name, List<double> embedding, double seconds) {
    if (embedding.isEmpty) return;
    final u = unit(embedding);
    final w = seconds.clamp(1, 120).toDouble();
    final v = byName(name);
    if (v == null) {
      voices.add(Voice(name, [for (final x in u) x * w], w));
    } else if (v.sum.length == u.length) {
      for (var i = 0; i < u.length; i++) {
        v.sum[i] += u[i] * w;
      }
      v.weight += w;
    }
    save();
  }

  void forget(String name) {
    voices.removeWhere((v) => v.name.toLowerCase() == name.toLowerCase());
    save();
  }

  void rename(String from, String to) {
    final v = byName(from);
    if (v == null) return;
    final other = byName(to);
    if (other != null && other != v && other.sum.length == v.sum.length) {
      for (var i = 0; i < v.sum.length; i++) {
        other.sum[i] += v.sum[i];
      }
      other.weight += v.weight;
      voices.remove(v);
    } else {
      v.name = to;
    }
    save();
  }
}
