// Talks to Earmark on the Mac, over the private Tailscale link, with the paired-device token.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  bool get unauthorized => status == 401;
  @override
  String toString() => message;
}

class Api {
  final Uri base;
  final String? token;
  final http.Client client;
  final Duration timeout;

  Api(this.base, this.token, {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : client = client ?? http.Client();

  /// "mac.tail1234.ts.net", "https://mac.tail1234.ts.net/", "192.168.1.5:8765" -> a base URL.
  static Uri normalise(String input) {
    var s = input.trim();
    if (s.isEmpty) throw const FormatException('Enter the address shown on your Mac');
    if (!s.contains('://')) {
      s = (s.endsWith('.ts.net') || s.contains('.ts.net/') ? 'https://' : 'http://') + s;
    }
    final u = Uri.parse(s);
    if (u.host.isEmpty) throw const FormatException('That is not a valid address');
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null);
  }

  Map<String, String> get _headers => {
        if (token != null) 'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  Uri _u(String path, [Map<String, String>? q]) => base.replace(path: path, queryParameters: q);

  Future<dynamic> _json(Future<http.Response> f) async {
    late http.Response r;
    try {
      r = await f.timeout(timeout);
    } on SocketException {
      throw ApiError(0, "Can't reach your Mac. Check that Tailscale is on and the Mac is awake.");
    } on HandshakeException {
      throw ApiError(0, "Secure connection to your Mac failed.");
    } on http.ClientException catch (e) {
      throw ApiError(0, "Can't reach your Mac: ${e.message}");
    }
    dynamic body;
    try {
      body = r.body.isEmpty ? null : jsonDecode(r.body);
    } catch (_) {
      body = null;
    }
    if (r.statusCode >= 400) {
      final msg = body is Map && body['detail'] != null ? '${body['detail']}' : 'Error ${r.statusCode}';
      throw ApiError(r.statusCode, msg);
    }
    return body;
  }

  Future<dynamic> get(String path, [Map<String, String>? q]) =>
      _json(client.get(_u(path, q), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) => _json(client.post(_u(path),
      headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})));

  Future<dynamic> patch(String path, Object body) => _json(client.patch(_u(path),
      headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)));

  // ---- app endpoints (mac/earmark/appsync.py)
  Future<String> pair(String code, String deviceName, String platform) async {
    final r = await post('/api/app/pair', {'code': code, 'name': deviceName, 'platform': platform});
    return r['token'] as String;
  }

  Future<Map<String, dynamic>> heartbeat(Map<String, dynamic> state) async =>
      Map<String, dynamic>.from(await post('/api/app/heartbeat', state) as Map);

  Future<Map<String, dynamic>> uploadChunk(Uint8List body, {required double start, required int seq, int codec = 21}) async {
    final r = await _json(client.post(_u('/api/app/audio'),
        headers: {
          ..._headers,
          'Content-Type': 'application/octet-stream',
          'X-Earmark-Start': start.toStringAsFixed(3),
          'X-Earmark-Seq': '$seq',
          'X-Earmark-Codec': '$codec',
        },
        body: body));
    return Map<String, dynamic>.from(r as Map);
  }

  /// Raw records copied from the pendant's own memory (444-byte records, see mac/earmark/pendant.py).
  Future<Map<String, dynamic>> uploadRing(Uint8List body, {required int start, required int next}) async {
    final r = await _json(client.post(_u('/api/app/ring'),
        headers: {..._headers, 'Content-Type': 'application/octet-stream', 'X-Earmark-Ring-Start': '$start', 'X-Earmark-Ring-Next': '$next'},
        body: body));
    return Map<String, dynamic>.from(r as Map);
  }

  /// This phone's transcript of one chunk (sent just before the chunk's audio).
  Future<void> uploadTranscript({required int seq, required double start, required double seconds, required String text,
          required List<List<Object>> words}) =>
      post('/api/app/transcript', {'seq': seq, 'start': start, 'seconds': seconds, 'text': text, 'words': words, 'engine': 'parakeet-v2-coreml'});

  Future<void> event(String type, {DateTime? at}) => post('/api/app/event',
      {'type': type, 'at': (at ?? DateTime.now()).millisecondsSinceEpoch / 1000});

  // ---- the same endpoints the Mac's own page uses
  Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(await get('/api/status') as Map);
  Future<Map<String, dynamic>> day([String? date]) async =>
      Map<String, dynamic>.from(await get('/api/day', date == null ? null : {'d': date}) as Map);
  Future<List<dynamic>> tasks() async => (await get('/api/tasks')) as List<dynamic>;
  Future<void> setTaskStatus(int id, String status) => patch('/api/tasks/$id', {'status': status});
  Future<List<dynamic>> sessions() async => (await get('/api/sessions')) as List<dynamic>;
  Future<Map<String, dynamic>> session(int id) async =>
      Map<String, dynamic>.from(await get('/api/sessions/$id') as Map);
  Uri audioUrl(int id) => _u('/api/sessions/$id/audio');
}
