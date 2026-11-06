// On-device speech to text (iOS: Parakeet via FluidAudio). See ios/earmark_asr/Sources.
import 'dart:io';

import 'package:flutter/services.dart';

class AsrStatus {
  /// idle | downloading | loading | ready | error | unsupported
  final String state;
  final double progress;
  final bool onDisk;
  final String? error;
  const AsrStatus(this.state, {this.progress = 0, this.onDisk = false, this.error});
  bool get ready => state == 'ready';
  bool get busy => state == 'downloading' || state == 'loading';
  static const unsupported = AsrStatus('unsupported');
}

class AsrWord {
  final double start, end;
  final String word;
  const AsrWord(this.start, this.end, this.word);
  List<Object> toJson() => [start, end, word];
}

class AsrResult {
  final String text;
  final List<AsrWord> words;
  final double seconds;
  const AsrResult(this.text, this.words, this.seconds);
}

class EarmarkAsr {
  static const _ch = MethodChannel('earmark/asr');

  /// Only iOS has an engine for now.
  static bool get supported => Platform.isIOS;

  static Future<AsrStatus> status() async {
    if (!supported) return AsrStatus.unsupported;
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
      return AsrStatus('${m['state']}',
          progress: (m['progress'] as num?)?.toDouble() ?? 0, onDisk: m['onDisk'] == true, error: m['error'] as String?);
    } on MissingPluginException {
      return AsrStatus.unsupported;
    }
  }

  /// Download (once) and load the model. Completes when it is ready.
  static Future<void> prepare() => _ch.invokeMethod('prepare');

  /// Transcribe one recording chunk. [prev] is the chunk just before it, when the audio runs on.
  static Future<AsrResult> transcribe(String path, {String? prev}) async {
    final m = Map<String, dynamic>.from(await _ch.invokeMethod('transcribe', {'path': path, 'prev': ?prev}) as Map);
    final words = [
      for (final w in (m['words'] as List? ?? []))
        AsrWord((w[0] as num).toDouble(), (w[1] as num).toDouble(), '${w[2]}'),
    ];
    return AsrResult('${m['text'] ?? ''}'.trim(), words, (m['seconds'] as num?)?.toDouble() ?? 0);
  }

  static Future<void> unload() => _ch.invokeMethod('unload');
  static Future<void> deleteModels() => _ch.invokeMethod('deleteModels');
}

/// Notes and tasks with Apple's on-device model (Foundation Models, iOS 26, Apple Intelligence).
class NotesError implements Exception {
  /// unsupported | context | guardrail | busy | language | failed
  final String code;
  final String message;
  const NotesError(this.code, this.message);
  bool get retryLater => code == 'busy';
  @override
  String toString() => message;
}

class EarmarkNotes {
  static const _ch = MethodChannel('earmark/notes');

  /// available | notEligible | notEnabled | notReady | unsupported
  static Future<String> availability() async {
    if (!Platform.isIOS) return 'unsupported';
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod('availability') as Map);
      return '${m['state']}';
    } on MissingPluginException {
      return 'unsupported';
    }
  }

  /// [lines]: "[mm:ss] text", optionally starting with ★ (earmarked) or ◆ (asked to save a task).
  static Future<Map<String, dynamic>> notes(List<String> lines, {String header = ''}) async {
    try {
      return Map<String, dynamic>.from(await _ch.invokeMethod('notes', {'lines': lines, 'header': header}) as Map);
    } on PlatformException catch (e) {
      throw NotesError(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw const NotesError('unsupported', 'Notes on the phone are not available here');
    }
  }
}
