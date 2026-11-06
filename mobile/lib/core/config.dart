// What this phone remembers: which Mac it is paired with (address + device token, kept in
// the Keychain / Android Keystore), and which pendant it uses.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../pendant/prefs.dart';

class Pairing {
  final Uri server;
  final String token;
  const Pairing(this.server, this.token);
}

class ConfigStore {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  Future<Pairing?> pairing() async {
    final url = await _s.read(key: 'server');
    final tok = await _s.read(key: 'token');
    if (url == null || tok == null) return null;
    return Pairing(Uri.parse(url), tok);
  }

  Future<void> savePairing(Pairing p) async {
    await _s.write(key: 'server', value: p.server.toString());
    await _s.write(key: 'token', value: p.token);
  }

  Future<void> forget() async {
    await _s.delete(key: 'server');
    await _s.delete(key: 'token');
  }

  Future<String?> pendantId() => _s.read(key: 'pendant_id');
  Future<void> savePendantId(String? id) =>
      id == null ? _s.delete(key: 'pendant_id') : _s.write(key: 'pendant_id', value: id);

  /// When this phone last had the pendant (survives an app restart, so the Mac doesn't grab
  /// the pendant while the app is starting up again).
  Future<DateTime?> lastHeld() async {
    final v = int.tryParse(await _s.read(key: 'last_held') ?? '');
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> saveLastHeld(DateTime t) => _s.write(key: 'last_held', value: '${t.millisecondsSinceEpoch}');

  /// Transcribe on this phone (on unless turned off).
  Future<bool> transcribeHere() async => (await _s.read(key: 'transcribe_here')) != '0';
  Future<void> saveTranscribeHere(bool on) => _s.write(key: 'transcribe_here', value: on ? '1' : '0');

  /// Send my tasks to Apple Reminders (off unless turned on).
  Future<bool> reminders() async => (await _s.read(key: 'reminders')) == '1';
  Future<void> saveReminders(bool on) => _s.write(key: 'reminders', value: on ? '1' : '0');

  /// The pendant's light, microphone and button settings; [dirty] = changed here, not yet sent to the Mac.
  Future<(PendantPrefs, bool)> pendantPrefs() async {
    try {
      final m = jsonDecode(await _s.read(key: 'pendant_prefs') ?? '{}') as Map;
      return (PendantPrefs.fromJson(m), m['dirty'] == true);
    } catch (_) {
      return (const PendantPrefs(), false);
    }
  }

  Future<void> savePendantPrefs(PendantPrefs p, {bool dirty = false}) =>
      _s.write(key: 'pendant_prefs', value: jsonEncode({...p.toJson(), 'dirty': dirty}));

  /// Who writes notes and answers Ask: apple | openai | anthropic.
  Future<String?> aiProvider() => _s.read(key: 'ai_provider');
  Future<void> saveAiProvider(String p) => _s.write(key: 'ai_provider', value: p);
  Future<String> aiKey(String provider) async => await _s.read(key: 'ai_key_$provider') ?? '';
  Future<void> saveAiKey(String provider, String key) => _s.write(key: 'ai_key_$provider', value: key);
  Future<String> aiModel(String provider) async => await _s.read(key: 'ai_model_$provider') ?? '';
  Future<void> saveAiModel(String provider, String model) => _s.write(key: 'ai_model_$provider', value: model);

  /// A silence this long starts a new conversation (seconds); null = your Mac's setting.
  Future<int?> gapSeconds() async => int.tryParse(await _s.read(key: 'gap_seconds') ?? '');
  Future<void> saveGapSeconds(int? s) => s == null ? _s.delete(key: 'gap_seconds') : _s.write(key: 'gap_seconds', value: '$s');

  /// Days of audio kept on the phone for playing back.
  Future<int> keepDays() async => int.tryParse(await _s.read(key: 'keep_days') ?? '') ?? 30;
  Future<void> saveKeepDays(int d) => _s.write(key: 'keep_days', value: '$d');

  Future<bool> paused() async => (await _s.read(key: 'paused')) == '1';
  Future<void> savePaused(bool p) => _s.write(key: 'paused', value: p ? '1' : '0');
}
