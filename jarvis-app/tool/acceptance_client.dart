// M6 验收脚本的客户端部分：用真实 service 走一遍首版闭环。
//
// 阶段一（配对与执行）：
//   dart run tool/acceptance_client.dart pair <base_url> <code> <state_file>
//   外部需在本机执行 `jarvis-service pair --approve <request_id>`。
//   脚本随后会：登录 → 问一句 → 建任务 → 等审批 → 自己批准（模拟点按钮）→ 等完成。
//
// 阶段二（重启后复查）：
//   dart run tool/acceptance_client.dart resume <state_file>
//   用保存的身份重新登录，确认任务与产物仍在——验证"重启不丢状态"。

import 'dart:convert';
import 'dart:io';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/base32_codec.dart';
import 'package:jarvis_app/src/core/device_identity.dart';
import 'package:jarvis_app/src/core/tls_pinning.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: pair <base_url> <code> <state_file> | resume <state_file>');
    exit(2);
  }

  switch (args.first) {
    case 'pair':
      await _pairAndRun(args);
    case 'resume':
      await _resume(args);
    default:
      stderr.writeln('未知子命令: ${args.first}');
      exit(2);
  }
}

Future<void> _pairAndRun(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('用法: pair <base_url> <code> <state_file>');
    exit(2);
  }

  final baseUrl = args[1];
  final code = args[2].replaceAll('-', '').toUpperCase();
  final stateFile = File(args[3]);
  // 模型模式下验收标准不同：回答不必标"未核实"，但产物必须来自模型。
  final modelMode = Platform.environment['ACCEPTANCE_MODEL'] == '1';

  final identity = await DeviceIdentity.generate();
  final publicKey = await identity.publicKeyBase32();
  final client = _api(baseUrl);

  try {
    // 1. 配对
    final pending = await client.postJson('/api/pair/request', <String, String>{
      'code': code,
      'device_name': 'm6-acceptance',
      'platform': 'macos',
      'client_pubkey': publicKey,
    });
    final requestId = pending['request_id'] as String;
    stdout.writeln('REQUEST_ID=$requestId');

    String? deviceId;
    for (var attempt = 0; attempt < 120; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final status = await client.getJson('/api/pair/requests/$requestId');
      final value = status['status'] as String? ?? 'pending';
      if (value == 'approved') {
        deviceId = status['device_id'] as String?;
        break;
      }
      if (value != 'pending' && value != 'awaiting_confirmation') {
        stderr.writeln('PAIR_FAILED=$value');
        exit(1);
      }
    }
    if (deviceId == null) {
      stderr.writeln('PAIR_TIMEOUT');
      exit(1);
    }
    stdout.writeln('PAIRED device=$deviceId');

    // 2. 登录
    final token = await _login(client, identity, deviceId);
    stdout.writeln('LOGIN_OK');

    final authed = _api(baseUrl, token: token);

    // 3. 未配对路径必须被拒（验收第 1 条的后半句）
    try {
      await _api(baseUrl).getJson('/api/conversations');
      stderr.writeln('UNPAIRED_ACCESS_ALLOWED');
      exit(1);
    } on ApiException catch (error) {
      if (error.code != 'unauthenticated') {
        stderr.writeln('UNEXPECTED_AUTH_ERROR=${error.code}');
        exit(1);
      }
      stdout.writeln('UNAUTHENTICATED_OK');
    }

    // 3.5 会话必须归属项目：验收环境还没有就就地建一个。
    final projectId = await _ensureProject(authed);
    stdout.writeln('PROJECT_ID=$projectId');

    // 4. 问一句：必须标注"未核实"（尚未接入检索/模型）
    final conversation = await authed.postJson('/api/conversations', <String, String>{
      'title': 'M6 验收',
      'project_id': projectId,
    });
    final conversationId = conversation['id'] as String;

    final buffer = StringBuffer();
    var suggestions = <Map<String, dynamic>>[];
    await for (final event in authed.postSse(
      '/api/conversations/$conversationId/messages',
      // 刻意用"要办"的语气：建议卡只在用户明确要办事时出现，
      // 只问判断时不该冒出"要不要我办"，这条也顺带被验收覆盖。
      <String, String>{
        'content': '下周三去上海出差，帮我安排一下行程',
        'client_msg_id': 'm6-1',
      },
    )) {
      if (event['type'] == 'message_delta') {
        buffer.write(event['text'] as String? ?? '');
      }
      if (event['type'] == 'message_completed') {
        final raw = event['task_suggestions'];
        if (raw is List) {
          suggestions = raw.whereType<Map<String, dynamic>>().toList();
        }
        break;
      }
    }
    final answer = buffer.toString();
    if (answer.trim().isEmpty) {
      stderr.writeln('ANSWER_EMPTY');
      exit(1);
    }

    if (!modelMode) {
      // 没有模型时，正确行为是明确标注"未核实"，而不是编一个来源。
      if (!answer.contains('未核实')) {
        stderr.writeln('ANSWER_WITHOUT_SOURCE_MARK=${jsonEncode(answer)}');
        exit(1);
      }
      stdout.writeln('ANSWER_MARKED_UNVERIFIED');
    } else {
      stdout.writeln('ANSWER_FROM_MODEL chars=${answer.length}');
    }

    // 5. 建任务：必须看到 plan 与审批，批准后完成并出产物
    final task = await authed.postJson('/api/tasks', <String, dynamic>{
      'conversation_id': conversationId,
      'type': 'skill:trip-plan',
      'skill': 'trip-plan',
      'input': <String, dynamic>{'submit': true, 'city': '上海', 'days': 3},
      'idempotency_key': 'm6-acceptance',
    });
    final taskId = task['id'] as String;
    stdout.writeln('TASK_ID=$taskId');

    var approvalId = '';
    var planSeen = false;
    var lastState = '';
    // 接模型后每步都有一次真实调用，整体耗时会到分钟级；轮询上限给到 120 秒。
    for (var attempt = 0; attempt < 480; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final current = await authed.getJson('/api/tasks/$taskId');
      final state = current['state'] as String? ?? '';
      final plan = current['plan'] as List<dynamic>? ?? const <dynamic>[];
      planSeen = planSeen || plan.isNotEmpty;

      if (state != lastState) {
        lastState = state;
        stdout.writeln('TASK_STATE=$state');
      }

      if (state == 'needs_approval') {
        final approval = current['pending_approval'] as Map<String, dynamic>?;
        approvalId = approval?['id'] as String? ?? '';
        if (approvalId.isEmpty) {
          stderr.writeln('APPROVAL_MISSING');
          exit(1);
        }
        stdout.writeln('APPROVAL_REQUIRED=$approvalId');

        // 模拟用户在审批卡片上点"批准并继续"
        await authed.postJson('/api/tasks/$taskId/approve', <String, String>{
          'approval_id': approvalId,
          'decision': 'approve',
        });
        continue;
      }

      if (state == 'succeeded') {
        if (!planSeen) {
          stderr.writeln('PLAN_EMPTY');
          exit(1);
        }
        final artifacts = current['artifacts'] as List<dynamic>? ?? const <dynamic>[];
        if (artifacts.isEmpty) {
          stderr.writeln('ARTIFACT_MISSING');
          exit(1);
        }
        stdout.writeln('TASK_SUCCEEDED artifacts=${artifacts.length}');

        // 产物必须有正文，而且能下载：只有元信息不算"产物可查"
        final first = artifacts.first as Map<String, dynamic>;
        final artifactId = first['id'] as String;
        final declaredSize = first['size'] as int;
        final download = await authed.getBytes('/api/artifacts/$artifactId/content');
        if (download.bytes.isEmpty || download.bytes.length != declaredSize) {
          stderr.writeln(
            'ARTIFACT_DOWNLOAD_BAD declared=$declaredSize actual=${download.bytes.length}',
          );
          exit(1);
        }
        stdout.writeln('ARTIFACT_DOWNLOAD_OK bytes=${download.bytes.length}');

        if (modelMode) {
          final text = utf8.decode(download.bytes, allowMalformed: true);

          // 接上模型后，产物不能再是"已完成：X"的模板回显。
          if (text.contains('已完成：')) {
            stderr.writeln('ARTIFACT_IS_TEMPLATE');
            exit(1);
          }

          // 有天气数据最好；拿不到就必须明说"未获取"，不许装作查过。
          final hasWeather = text.contains('天气') || text.contains('°C');
          final honest = text.contains('未获取');
          if (!hasWeather && !honest) {
            stderr.writeln('ARTIFACT_NO_DATA_AND_NO_DISCLAIMER');
            exit(1);
          }
          stdout.writeln('ARTIFACT_MODEL_OK weather=$hasWeather honest=$honest');

          // 建议卡：同一 message + 技能重复 POST 必须得到同一个任务。
          if (suggestions.isEmpty) {
            stderr.writeln('SUGGESTION_MISSING');
            exit(1);
          }
          final suggestion = suggestions.first;
          final skill = suggestion['skill'] as String? ?? '';
          final input = suggestion['input'] as Map<String, dynamic>? ?? <String, dynamic>{};
          final key = 'conv:$conversationId:msg:acceptance:skill:$skill';

          final first = await authed.postJson('/api/tasks', <String, dynamic>{
            'conversation_id': conversationId,
            'type': 'skill:$skill',
            'skill': skill,
            'input': input,
            'idempotency_key': key,
          });
          final second = await authed.postJson('/api/tasks', <String, dynamic>{
            'conversation_id': conversationId,
            'type': 'skill:$skill',
            'skill': skill,
            'input': input,
            'idempotency_key': key,
          });

          if (first['id'] != second['id']) {
            stderr.writeln('SUGGESTION_NOT_IDEMPOTENT');
            exit(1);
          }
          stdout.writeln('SUGGESTION_OK skill=$skill idempotent=1');
        }

        // 保存身份与任务，供重启后复查（0600，用完即删）
        await stateFile.writeAsString(
          jsonEncode(<String, String>{
            'base_url': baseUrl,
            'seed': base32Encode(await identity.exportSeed()),
            'device_id': deviceId,
            'task_id': taskId,
          }),
          flush: true,
        );
        if (!Platform.isWindows) {
          await Process.run('chmod', <String>['600', stateFile.path]);
        }

        authed.close();
        stdout.writeln('ACCEPTANCE_OK');
        return;
      }

      if (state == 'failed' || state == 'canceled') {
        stderr.writeln('TASK_TERMINATED=$state');
        exit(1);
      }
    }

    stderr.writeln('TASK_TIMEOUT');
    exit(1);
  } finally {
    client.close();
  }
}

Future<void> _resume(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: resume <state_file>');
    exit(2);
  }

  final stateFile = File(args[1]);
  final state = jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
  final baseUrl = state['base_url'] as String;
  final seed = base32Decode(state['seed'] as String);
  final deviceId = state['device_id'] as String;
  final taskId = state['task_id'] as String;

  final identity = await DeviceIdentity.fromSeed(seed);
  final client = _api(baseUrl);

  try {
    final token = await _login(client, identity, deviceId);
    final authed = _api(baseUrl, token: token);

    final task = await authed.getJson('/api/tasks/$taskId');
    final stateValue = task['state'] as String? ?? '';
    final artifacts = task['artifacts'] as List<dynamic>? ?? const <dynamic>[];

    if (stateValue != 'succeeded' || artifacts.isEmpty) {
      stderr.writeln('RESUME_STATE_LOST state=$stateValue artifacts=${artifacts.length}');
      exit(1);
    }

    stdout.writeln('RESUME_OK state=$stateValue artifacts=${artifacts.length}');
    authed.close();
  } finally {
    client.close();
  }
}

/// 会话必须归属项目。验收环境可能还没有任何项目：
/// 就地建一个 WORK 项目，目录取服务端允许浏览的第一个根目录。
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
    'name': '验收项目',
  });
  return created['id'] as String;
}

Future<String> _login(
  ApiClient client,
  DeviceIdentity identity,
  String deviceId,
) async {
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

  final token = verified['token'] as String?;
  if (token == null) {
    throw const ApiException(
      code: 'internal_error',
      message: 'missing token',
      retryable: false,
      hint: '服务返回了预期之外的数据',
    );
  }
  return token;
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
