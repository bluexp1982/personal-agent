import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/api_error.dart';

void main() {
  test('getBytes 把 query 拼进 URL 并透传 contentType', () async {
    late Uri seen;
    final client = ApiClient(
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token-1',
      httpClient: MockClient((request) async {
        seen = request.url;
        expect(request.headers['authorization'], 'Bearer token-1');
        return http.Response.bytes(
          <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'image/png'},
        );
      }),
    );

    final result = await client.getBytes(
      '/api/projects/ws_1/raw',
      query: <String, String>{'path': '/tmp/照片 1.png', 'download': 'true'},
    );

    expect(seen.path, '/api/projects/ws_1/raw');
    expect(seen.queryParameters['path'], '/tmp/照片 1.png');
    expect(seen.queryParameters['download'], 'true');
    expect(result.bytes, <int>[1, 2, 3]);
    expect(result.contentType, 'image/png');
  });

  test('getBytes 的非 2xx 走统一错误体，不是"响应不是 JSON 对象"', () async {
    final client = ApiClient(
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token-1',
      httpClient: MockClient(
        (request) async => http.Response(
          '{"code":"invalid_request","message":"too large",'
          '"retryable":false,"hint":"文件超过上限，请先另存"}',
          400,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      client.getBytes('/api/projects/ws_1/raw'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'invalid_request')
            .having(
              (error) => error.hint,
              'hint',
              contains('另存'),
            ),
      ),
    );
  });
}
