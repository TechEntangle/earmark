// What this phone remembers: which Mac it is paired with (address + device token, kept in
// the Keychain / Android Keystore), and which pendant it uses.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  Future<bool> paused() async => (await _s.read(key: 'paused')) == '1';
  Future<void> savePaused(bool p) => _s.write(key: 'paused', value: p ? '1' : '0');
}
