// Notes and Ask with your own OpenAI or Anthropic key, for when you'd rather use a bigger model
// than Apple's on-device one (or this iPhone doesn't have Apple Intelligence).
// Only text is sent (the transcript lines or Ask's excerpts), never audio, and only when you chose it.
import 'dart:convert';

import 'package:earmark_asr/earmark_asr.dart';
import 'package:http/http.dart' as http;

enum AiProvider {
  apple('On this iPhone'),
  openai('OpenAI'),
  anthropic('Anthropic');

  final String label;
  const AiProvider(this.label);
  bool get cloud => this != apple;
  String get defaultModel => switch (this) { openai => 'gpt-4.1-mini', anthropic => 'claude-haiku-5-5', apple => '' };
  static AiProvider parse(String? s) => AiProvider.values.where((p) => p.name == s).firstOrNull ?? apple;
}

const _notesRules = '''You turn transcripts from a wearable voice recorder into precise notes. The person wearing the recorder is "me".
Lines are [mm:ss] timestamps followed by speech (sometimes "Name:" first); work out who is speaking from the back-and-forth.
Tasks: only real commitments or requests (someone agrees to do something, is asked to, or says they will), not ideas or wishes.
Write each task so it makes sense on its own a week later, starting with a verb. Inside task text refer to the wearer as "me".
The owner is "me" when the speaker commits and you cannot tell it is someone else; otherwise a first name, or "unknown".
Copy deadline words as said ("by Thursday"); do not calculate dates. If something was reported as finished, mark it done.
Lines starting with ◆ are the wearer asking to save a task or reminder: always make a task owned by "me".
Lines starting with ★ were earmarked by the wearer as important: always cover them in the key points.
Never invent tasks, names or dates. Empty lists are fine. Use kind "ambient" for background talk with nothing to act on.
Reply with JSON only, exactly this shape:
{"title": "specific, at most 8 words, no date", "kind": "meeting|call|conversation|note_to_self|ambient",
 "summary": "2 to 5 sentences", "keyPoints": ["at most 8"], "decisions": ["agreed decisions, at most 5"],
 "tasks": [{"task": "...", "owner": "me", "dueText": "", "done": false}], "people": ["first names"], "topics": ["2 to 5 tags"]}''';

class CloudModel {
  final AiProvider provider;
  final String key, model;
  final http.Client client;
  CloudModel(this.provider, this.key, {String? model, http.Client? client})
      : model = (model == null || model.trim().isEmpty) ? provider.defaultModel : model.trim(),
        client = client ?? http.Client();

  Future<String> _complete(String system, String user, {int maxTokens = 2000}) async {
    if (key.trim().isEmpty) throw NotesError('key', 'Add your ${provider.label} key in Settings');
    late http.Response r;
    try {
      if (provider == AiProvider.openai) {
        r = await client
            .post(Uri.parse('https://api.openai.com/v1/chat/completions'),
                headers: {'Authorization': 'Bearer ${key.trim()}', 'Content-Type': 'application/json'},
                body: jsonEncode({
                  'model': model,
                  'temperature': 0.2,
                  'response_format': {'type': 'json_object'},
                  'messages': [
                    {'role': 'system', 'content': system},
                    {'role': 'user', 'content': user},
                  ],
                }))
            .timeout(const Duration(seconds: 120));
      } else {
        r = await client
            .post(Uri.parse('https://api.anthropic.com/v1/messages'),
                headers: {'x-api-key': key.trim(), 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json'},
                body: jsonEncode({
                  'model': model,
                  'max_tokens': maxTokens,
                  'temperature': 0.2,
                  'system': system,
                  'messages': [
                    {'role': 'user', 'content': user},
                  ],
                }))
            .timeout(const Duration(seconds: 120));
      }
    } catch (e) {
      throw NotesError('busy', "Couldn't reach ${provider.label}: $e");
    }
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode == 401 || r.statusCode == 403) throw NotesError('key', '${provider.label} did not accept the key');
    if (r.statusCode == 429 || r.statusCode >= 500) throw NotesError('busy', '${provider.label} is busy (${r.statusCode})');
    if (r.statusCode >= 400) throw NotesError('failed', '${provider.label}: ${_err(body) ?? r.statusCode}');
    final j = jsonDecode(body) as Map;
    if (provider == AiProvider.openai) return '${((j['choices'] as List).first as Map)['message']['content']}';
    return [for (final b in (j['content'] as List? ?? [])) if (b is Map && b['type'] == 'text') '${b['text']}'].join();
  }

  static String? _err(String body) {
    try {
      final e = (jsonDecode(body) as Map)['error'];
      return e is Map ? '${e['message']}' : '$e';
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> parseJson(String text) {
    var s = text.trim();
    final a = s.indexOf('{'), b = s.lastIndexOf('}');
    if (a >= 0 && b > a) s = s.substring(a, b + 1);
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      throw const NotesError('failed', 'The model did not reply with notes');
    }
  }

  /// Notes for one conversation (same shape as Apple's on-device notes).
  Future<Map<String, dynamic>> notes(List<String> lines, {String header = ''}) async {
    // a very long day is cut to what fits comfortably (~60k words)
    var words = 0;
    final keep = <String>[];
    for (final l in lines) {
      words += l.split(' ').length;
      if (words > 60000) break;
      keep.add(l);
    }
    return parseJson(await _complete(_notesRules, '$header\n\nTranscript:\n${keep.join('\n')}', maxTokens: 3000));
  }

  /// Ask: an answer from numbered excerpts, with the numbers it used.
  Future<(String, List<int>)> answer(String question, List<String> excerpts, {String today = ''}) async {
    final numbered = [for (final (i, e) in excerpts.indexed) '[${i + 1}] $e'].join('\n\n');
    final j = parseJson(await _complete(
        'You answer questions about the user\'s own recorded conversations, using only the numbered excerpts. '
        'The user wore the recorder and is "me"/"Me" in the excerpts. Today is $today. Be direct and specific: names, '
        'numbers, dates and who promised what, in 1 to 5 sentences. If the excerpts don\'t answer it, say you couldn\'t find it. '
        'Never invent anything. Reply with JSON only: {"answer": "...", "sources": [excerpt numbers used]}',
        'Question: $question\n\nExcerpts:\n$numbered',
        maxTokens: 700));
    return (
      '${j['answer'] ?? ''}',
      [for (final x in (j['sources'] as List? ?? [])) if (x is num && x >= 1 && x <= excerpts.length) x.toInt()],
    );
  }

  /// A tiny request to check the key works.
  Future<String?> check() async {
    try {
      await _complete('Reply with JSON only: {"ok": true}', 'ping', maxTokens: 20);
      return null;
    } on NotesError catch (e) {
      return e.message;
    }
  }
}
