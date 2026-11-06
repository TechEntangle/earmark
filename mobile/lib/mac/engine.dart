// Earmark for Mac talks to two things:
//  - Earmark's engine on this Mac (http://127.0.0.1:8765): pendant, transcription, notes, tasks, search, Ask.
//    Requests from the Mac itself need no pairing.
//  - the app's own native side (channel "earmark/mac"): menu bar, starting the engine, open at login,
//    notifications and audio playback.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';

const enginePort = 8765;

class Native {
  static const _ch = MethodChannel('earmark/mac');

  /// Called when the menu bar asks for something (open, settings, pause, earmark).
  static void onMenu(void Function(String action) f) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'menu') f('${(call.arguments as Map?)?['action'] ?? ''}');
      return null;
    });
  }

  static Future<Map> _call(String m, [Map<String, Object?>? args]) async {
    try {
      return (await _ch.invokeMethod(m, args) as Map?) ?? const {};
    } on MissingPluginException {
      return const {};
    } on PlatformException catch (e) {
      return {'error': e.message};
    }
  }

  static Future<Map> ensureEngine() => _call('ensureEngine');
  static Future<bool> loginItem() async => (await _call('loginItem'))['on'] == true;
  static Future<Map> setLoginItem(bool on) => _call('setLoginItem', {'on': on});
  static Future<void> notify(String title, String body) => _call('notify', {'title': title, 'body': body});
  static Future<void> statusChanged() => _call('status');
  static Future<void> reveal(String path) => _call('reveal', {'path': path});
  static Future<Map> play(String url, {double? at, double? speed}) => _call('play', {'url': url, 'at': at, 'speed': speed});
  static Future<Map> pause() => _call('pause');
  static Future<Map> seek(double at) => _call('seek', {'at': at});
  static Future<Map> speed(double x) => _call('speed', {'speed': x});
  static Future<Map> stop() => _call('stop');
  static Future<Map> audioState() => _call('audioState');
  static Future<bool> hasUpdate() async => (await _call('hasUpdate'))['ready'] == true;
  static Future<Map> applyUpdate() => _call('applyUpdate');
}

/// The engine's state and the app's view of it, refreshed every few seconds.
class MacState extends ChangeNotifier {
  final Api api;
  MacState({Api? api}) : api = api ?? Api(Uri.parse('http://127.0.0.1:$enginePort'), null, timeout: const Duration(seconds: 120));

  Map<String, dynamic>? status;
  Map<String, dynamic>? settings; // config
  Map<String, dynamic> settingsInfo = {}; // local_models, ollama_models, intel, paths
  String? engineError;
  bool starting = false;
  /// a newer engine is waiting in ~/Applications/earmark/update
  bool updateReady = false;
  bool updating = false;
  int _ticks = 0;
  Timer? _poll;
  double _lastLog = 0;
  /// bumps when anything the pages show may have changed (new notes, a task added…)
  int revision = 0;

  bool get online => status != null;
  bool get paused => status?['paused'] == true;
  Map<String, dynamic> get pendant => Map<String, dynamic>.from(status?['pendant'] as Map? ?? {});
  String? get via => (pendant['via'] as String?)?.isNotEmpty == true ? pendant['via'] as String : null;
  bool get pendantHere => pendant['connected'] == true || via != null;
  int? get battery => (pendant['battery'] as num?)?.toInt();

  Future<void> start() async {
    starting = true;
    notifyListeners();
    await refresh();
    if (!online) {
      final r = await Native.ensureEngine();
      engineError = r['error'] as String?;
      await refresh();
    }
    starting = false;
    notifyListeners();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    unawaited(loadSettings());
  }

  Future<void> refresh() async {
    try {
      final s = Map<String, dynamic>.from(await api.get('/api/status') as Map);
      final firstTime = status == null;
      status = s;
      engineError = null;
      _notifyLog(s, quiet: firstTime);
    } on ApiError catch (e) {
      if (status != null) engineError = "Earmark's engine stopped answering: ${e.message}";
      status = null;
    }
    if (_ticks++ % 10 == 0) updateReady = await Native.hasUpdate();
    notifyListeners();
  }

  /// New "notes ready" lines in the engine's activity log become notifications (and refresh the pages).
  void _notifyLog(Map<String, dynamic> s, {bool quiet = false}) {
    final log = [for (final e in (s['log'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    var newest = _lastLog;
    var changed = false;
    for (final e in log) {
      final t = (e['t'] as num?)?.toDouble() ?? 0;
      if (t <= _lastLog) continue;
      if (t > newest) newest = t;
      final msg = '${e['msg'] ?? ''}';
      if (msg.startsWith('notes ready') || msg.contains('task') || msg.startsWith('Earmarked')) changed = true;
      if (!quiet && msg.startsWith('notes ready:')) {
        unawaited(Native.notify('Notes ready', msg.substring('notes ready:'.length).trim()));
      }
    }
    _lastLog = newest;
    if (changed && !quiet) revision++;
  }

  Future<void> loadSettings() async {
    try {
      final r = Map<String, dynamic>.from(await api.get('/api/settings') as Map);
      settings = Map<String, dynamic>.from(r['config'] as Map);
      settingsInfo = r;
      notifyListeners();
    } catch (_) {}
  }

  /// Change settings (only the keys given). Returns an error message, or null.
  Future<String?> saveSettings(Map<String, Object?> changes) async {
    try {
      final r = Map<String, dynamic>.from(await api.put('/api/settings', changes) as Map);
      settings = Map<String, dynamic>.from(r['config'] as Map);
      notifyListeners();
      return null;
    } on ApiError catch (e) {
      return e.message;
    }
  }

  Future<void> setPaused(bool p) async {
    try {
      await api.post('/api/pause', {'paused': p});
    } catch (_) {}
    await refresh();
    unawaited(Native.statusChanged());
  }

  Future<String?> earmark() async {
    try {
      final r = await api.post('/api/earmark') as Map;
      await refresh();
      return r['ok'] == true ? null : '${r['detail'] ?? 'Not earmarked'}';
    } on ApiError catch (e) {
      return e.message;
    }
  }

  /// Install the waiting engine update and restart it.
  Future<String?> applyUpdate() async {
    updating = true;
    notifyListeners();
    final r = await Native.applyUpdate();
    updating = false;
    updateReady = await Native.hasUpdate();
    await refresh();
    await loadSettings();
    return r['ok'] == true ? null : '${r['error'] ?? 'The update did not install'}';
  }

  void changed() {
    revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
