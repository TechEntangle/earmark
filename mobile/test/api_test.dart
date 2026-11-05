import 'dart:convert';
import 'dart:typed_data';

import 'package:earmark/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('addresses are normalised', () {
    expect(Api.normalise('mac.tail1234.ts.net').toString(), 'https://mac.tail1234.ts.net');
    expect(Api.normalise(' https://mac.tail1234.ts.net/#/today ').toString(), 'https://mac.tail1234.ts.net');
    expect(Api.normalise('192.168.1.5:8765').toString(), 'http://192.168.1.5:8765');
    expect(() => Api.normalise(''), throwsFormatException);
  });

  test('uploads carry the token, start time, sequence and codec', () async {
    late http.Request seen;
    final api = Api(Uri.parse('https://mac.ts.net'), 'tok123', client: MockClient((r) async {
      seen = r;
      return http.Response(jsonEncode({'ok': true, 'last_seq': 7}), 200);
    }));
    final r = await api.uploadChunk(Uint8List.fromList([0, 1, 9]), start: 1800000000.5, seq: 7, codec: 21);
    expect(r['last_seq'], 7);
    expect(seen.url.path, '/api/app/audio');
    expect(seen.headers['Authorization'], 'Bearer tok123');
    expect(seen.headers['X-Earmark-Start'], '1800000000.500');
    expect(seen.headers['X-Earmark-Seq'], '7');
    expect(seen.headers['X-Earmark-Codec'], '21');
    expect(seen.bodyBytes, [0, 1, 9]);
  });

  test('errors carry the Mac message and recognise unpairing', () async {
    final api = Api(Uri.parse('https://mac.ts.net'), 'x',
        client: MockClient((r) async => http.Response(jsonEncode({'detail': 'This device is not paired with Earmark.'}), 401)));
    try {
      await api.status();
      fail('should throw');
    } on ApiError catch (e) {
      expect(e.unauthorized, isTrue);
      expect(e.message, contains('not paired'));
    }
  });
}
