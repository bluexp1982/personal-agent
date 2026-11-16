// 客户端链路冒烟：用真实 service 验证 配对 → 登录 → 对话流式。
//
// 用途：Flutter 界面无法在 CI 里点，但客户端最容易出错的部分（base32 编码、
// 挑战签名、SSE 解析）是纯 Dart 逻辑，可以用这个脚本对着真实服务跑一遍。
//
// 用法（需要外部在本机批准配对）：
//   dart run tool/smoke_client.dart http://127.0.0.1:8799 <12位配对码>
//
// 脚本会先打印 `REQUEST_ID=...`，外部据此执行 `jarvis-service pair --approve <id>`。

import 'dart:convert';
import 'dart:io';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/base32_codec.dart';
import 'package:jarvis_app/src/core/device_identity.dart';
import 'package:jarvis_app/src/core/pairing_code.dart';
import 'package:jarvis_app/src/core/tls_pinning.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/smoke_client.dart <base_url> <pairing_code>');
    exit(2);
  }

  final baseUrl = args[0];
  // 与界面共用同一套归一化：CLI 打印的 `77JJ-VQ3F-2YZK` 可以直接粘进来。
  final code = normalizePairingCode(args[1]);
  // 可选：自定义提问，默认只验证链路。
  final question = args.length > 2 ? args[2] : '冒烟测试：能不能听到我';

  final identity = await DeviceIdentity.generate();
  final publicKey = await identity.publicKeyBase32();
  final client = _api(baseUrl);

  try {
    // 1. 提交配对码
    final pending = await client.postJson('/api/pair/request', <String, String>{
      'code': code,
      'device_name': 'm5-smoke',
      'platform': 'macos',
      'client_pubkey': publicKey,
    });
    final requestId = pending['request_id'] as String;
    stdout.writeln('REQUEST_ID=$requestId');
    stdout.writeln('PUBKEY_LEN=${publicKey.length}');

    // 2. 等本机批准（最多 60 秒）
    String? deviceId;
    for (var attempt = 0; attempt < 120; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final status = await client.getJson('/api/pair/requests/$requestId');
      final value = status['status'] as String? ?? 'pending';
      if (value == 'approved') {
        deviceId = status['device_id'] as String?;
        stdout.writeln('FINGERPRINT=${status['server_fingerprint']}');
        break;
      }
      if (value == 'rejected' || value == 'expired' || value == 'locked') {
        stderr.writeln('PAIR_FAILED=$value');
        exit(1);
      }
    }

    if (deviceId == null) {
      stderr.writeln('PAIR_TIMEOUT');
      exit(1);
    }
    stdout.writeln('DEVICE_ID=$deviceId');

    // 3. challenge → 签名 → 换令牌
    final challenge = await client.postJson('/api/auth/challenge', <String, String>{
      'device_id': deviceId,
    });
    final challengeValue = challenge['challenge'] as String;

    final signature = await identity.sign(base32Decode(challengeValue));
    final verified = await client.postJson('/api/auth/verify', <String, String>{
      'device_id': deviceId,
      'challenge': challengeValue,
      'signature': base32Encode(signature),
    });
    final token = verified['token'] as String;
    stdout.writeln('LOGIN_OK token_len=${token.length}');

    // 4. 带令牌访问受保护端点
    final authed = _api(baseUrl, token: token);
    final me = await authed.getJson('/api/auth/me');
    stdout.writeln('ME=${me['name']}');

    // 5. 建会话并收流式回答（会话必须归属项目）
    final projectId = await _ensureProject(authed);
    final conversation = await authed.postJson('/api/conversations', <String, String>{
      'title': 'M5 冒烟',
      'project_id': projectId,
    });
    final conversationId = conversation['id'] as String;

    final buffer = StringBuffer();
    var completed = false;
    final events = authed.postSse(
      '/api/conversations/$conversationId/messages',
      <String, String>{'content': question, 'client_msg_id': 'smoke-1'},
    );

    await for (final event in events) {
      switch (event['type']) {
        case 'message_delta':
          buffer.write(event['text'] as String? ?? '');
        case 'message_completed':
          completed = true;
        case 'error':
          stderr.writeln('STREAM_ERROR=${event['hint']}');
          exit(1);
      }
      if (completed) {
        break;
      }
    }

    if (!completed) {
      stderr.writeln('STREAM_INCOMPLETE');
      exit(1);
    }

    stdout.writeln('ANSWER=${jsonEncode(buffer.toString())}');

    // 6. 历史可查（验证"收到 completed 即已落库"）
    final history = await authed.getJson(
      '/api/conversations/$conversationId/messages',
      query: <String, String>{'limit': '10'},
    );
    final items = (history['items'] as List<dynamic>? ?? const <dynamic>[]).length;
    stdout.writeln('HISTORY_COUNT=$items');

    authed.close();
    stdout.writeln('SMOKE_OK');
  } finally {
    client.close();
  }
}

/// 会话必须归属项目。冒烟环境还没有就就地建一个 WORK 项目，
/// 目录取服务端允许浏览的第一个根目录。
Future<String> _ensureProject(ApiClient client) async {
  final existing = await client.getJsonArray(
    '/api/projects',
    query: <String, String>{'mode': 'work'},
  );
  for (final item in existing) {
    final id = item['id'] as String?;
    if (id != null && id.isNotEmpty) {
      return id;
    }
  }

  final listing = await client.getJson(
    '/api/fs/dirs',
    query: <String, String>{'mode': 'work'},
  );
  final roots = (listing['roots'] as List<dynamic>? ?? const <dynamic>[])
      .whereType<String>()
      .toList(growable: false);
  if (roots.isEmpty) {
    stderr.writeln('PROJECT_ROOT_MISSING');
    exit(1);
  }

  final created = await client.postJson('/api/projects', <String, String>{
    'mode': 'work',
    'path': roots.first,
    'name': '冒烟项目',
  });
  return created['id'] as String;
}

/// 统一构造客户端：证书指纹从 `AGENT_TLS_FINGERPRINT` 读取。
///
/// 脚本没有交互界面，无法让人工核对；不提供基准时按 TOFU 接受，
/// 需要严格校验时由调用方把服务端打印的指纹放进环境变量。
ApiClient _api(String baseUrl, {String? token}) => ApiClient(
  baseUrl: baseUrl,
  token: token,
  httpClient: createPinnedClient(
    baseUrl: baseUrl,
    pinned: Platform.environment['AGENT_TLS_FINGERPRINT'],
  ),
);
