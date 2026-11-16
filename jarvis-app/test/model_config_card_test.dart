import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/settings/model_config_card.dart';

/// 一份模型配置的 JSON（字段名与服务端 `ProfileView` 一致）。
Map<String, dynamic> _profile({
  String id = 'default',
  String name = '默认',
  bool builtin = true,
  bool active = false,
  bool available = true,
  String? reason,
  String model = 'deepseek-chat',
  String modelName = '',
  String baseUrl = 'https://api.example.com',
  String apiPath = '/v1',
  String keySource = 'secrets',
  String? keyHint = '…9f2a',
}) {
  return <String, dynamic>{
    'id': id,
    'name': name,
    'builtin': builtin,
    'active': active,
    'enabled': true,
    'base_url': baseUrl,
    'api_path': apiPath,
    'model': model,
    'model_name': modelName,
    'vision': false,
    'available': available,
    'reason': reason,
    'api_key_source': keySource,
    'api_key_hint': keyHint,
  };
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Widget _harness(http.Client client) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ModelConfigCard())),
    ),
  );
}

void main() {
  testWidgets('列表标出当前生效项与不可用原因', (tester) async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/models');
      return _json(<String, dynamic>{
        'active_id': 'third',
        'persisted': true,
        'models': <Map<String, dynamic>>[
          _profile(available: false, reason: '缺少密钥', keyHint: null),
          _profile(
            id: 'third',
            name: '第三方',
            builtin: false,
            active: true,
            model: 'qwen-max',
            baseUrl: 'https://dashscope.example.com',
          ),
        ],
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    expect(find.text('第三方'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget, reason: '只有生效项挂「当前」徽标');
    expect(find.text('缺少密钥'), findsOneWidget, reason: '不可用必须给出原因');
    expect(
      find.textContaining('当前：第三方 · qwen-max'),
      findsOneWidget,
      reason: '卡头摘要要说明现在用的是哪个配置',
    );
  });

  testWidgets('没有配置时给出空态说明', (tester) async {
    final client = MockClient((request) async {
      return _json(<String, dynamic>{
        'active_id': 'default',
        'persisted': true,
        'models': <Map<String, dynamic>>[],
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    expect(find.text('还没有可用的模型配置'), findsOneWidget);
    expect(find.text('新增配置'), findsOneWidget);
  });

  testWidgets('未连接服务端时说明原因', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(null)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelConfigCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没连上服务端'), findsOneWidget);
  });

  testWidgets('新增表单在空白提交时给出字段级错误', (tester) async {
    var posted = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return _json(<String, dynamic>{
          'active_id': 'default',
          'persisted': true,
          'models': <Map<String, dynamic>>[],
        });
      }
      posted += 1;
      return _json(<String, dynamic>{'model': _profile(), 'persisted': true});
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增配置'));
    await tester.pumpAndSettle();

    expect(find.text('新增配置'), findsWidgets, reason: '弹窗标题与入口同名');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('填一个名字，方便在列表里区分'), findsOneWidget);
    expect(find.text('必填，例如 https://api.deepseek.com'), findsOneWidget);
    expect(posted, 0, reason: '校验不通过时不该发请求');
  });

  testWidgets('新增弹窗与「新建项目」同一形态：居中对话框 + 右上角关闭', (tester) async {
    final client = MockClient((request) async {
      return _json(<String, dynamic>{
        'active_id': 'default',
        'persisted': true,
        'models': <Map<String, dynamic>>[_profile(active: true)],
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增配置'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget, reason: '与新建项目一致，用居中窗口而非底部弹层');
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byTooltip('关闭'), findsOneWidget, reason: '右上角要有稳定的关闭落点');

    // Dialog 本身铺满全屏（内层另有 AnimatedPadding），量它里面的面板才有意义。
    final surface = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(surface.top, greaterThan(screen.top), reason: '不是铺满屏幕的抽屉');
    expect(surface.width, lessThanOrEqualTo(520));
    expect(
      (surface.center.dy - screen.center.dy).abs() < 1,
      isTrue,
      reason: '窗口垂直居中，不贴着屏幕底边',
    );

    // 与「新建项目」一样左右各 20，输入框不能歪向另一边。
    final field = tester.getRect(find.widgetWithText(TextField, '名称'));
    expect(
      field.left - surface.left,
      closeTo(surface.right - field.right, 0.5),
      reason: '左右边距必须相同',
    );

    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '测试连接'));
    expect(find.widgetWithText(OutlinedButton, '测试连接'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsOneWidget);

    // 整个表单在滚动区里，滚动到底后标题行会被卷走——先滚回顶部再点关闭。
    await tester.ensureVisible(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('新增配置'),
      ),
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing, reason: '关闭按钮应直接收起弹窗');
  });

  testWidgets('测试连接失败时把原因留在弹窗里', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/models') {
        return _json(<String, dynamic>{
          'active_id': 'default',
          'persisted': true,
          'models': <Map<String, dynamic>>[_profile(active: true)],
        });
      }
      return _json(<String, dynamic>{
        'ok': false,
        'error_code': 'auth_failed',
        'status': 401,
        'hint': '密钥无效或没有该模型的权限：重新填写 API Key 后再试',
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增配置'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '名称'), '测试');
    await tester.enterText(
      find.widgetWithText(TextField, '网关地址'),
      'https://api.example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, '模型ID'), 'm');
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '测试连接'));
    await tester.tap(find.widgetWithText(OutlinedButton, '测试连接'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('密钥无效'),
      findsOneWidget,
      reason: '失败原因要就地显示，不能只弹一个「失败」',
    );
  });

  testWidgets('模型名与模型ID分别保存，列表优先显示模型名', (tester) async {
    Map<String, dynamic>? posted;
    var models = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return _json(<String, dynamic>{
          'active_id': 'default',
          'persisted': true,
          'models': models,
        });
      }
      posted = jsonDecode(request.body) as Map<String, dynamic>;
      models = <Map<String, dynamic>>[
        _profile(
          id: 'model_1',
          name: 'DeepSeek',
          builtin: false,
          active: true,
          model: 'deepseek-flash',
          modelName: 'DeepSeek V3.2 Flash',
        ),
      ];
      return _json(<String, dynamic>{
        'model': models.first,
        'persisted': true,
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增配置'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, '模型名'),
      findsOneWidget,
      reason: '人可读的模型名',
    );
    expect(
      find.widgetWithText(TextField, '模型ID'),
      findsOneWidget,
      reason: '发给上游的 model 字段改叫模型ID',
    );

    await tester.enterText(find.widgetWithText(TextField, '名称'), 'DeepSeek');
    await tester.enterText(
      find.widgetWithText(TextField, '模型名'),
      'DeepSeek V3.2 Flash',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '模型ID'),
      'deepseek-flash',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '网关地址'),
      'https://api.example.com',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(
      posted?['model'],
      'deepseek-flash',
      reason: '模型ID仍走 model 字段',
    );
    expect(
      posted?['model_name'],
      'DeepSeek V3.2 Flash',
      reason: '模型名单独保存，不能覆盖模型ID',
    );
    expect(
      find.text('当前：DeepSeek · DeepSeek V3.2 Flash'),
      findsOneWidget,
      reason: '卡头摘要优先显示模型名',
    );
    expect(
      find.textContaining('DeepSeek V3.2 Flash'),
      findsWidgets,
      reason: '列表行副标题也跟着显示模型名',
    );
  });

  testWidgets('模型名留空时列表回退显示模型ID', (tester) async {
    final client = MockClient((request) async {
      return _json(<String, dynamic>{
        'active_id': 'default',
        'persisted': true,
        'models': <Map<String, dynamic>>[
          _profile(active: true, name: 'DeepSeek', model: 'deepseek-flash'),
        ],
      });
    });

    await tester.pumpWidget(_harness(client));
    await tester.pumpAndSettle();

    expect(
      find.text('当前：DeepSeek · deepseek-flash'),
      findsOneWidget,
      reason: '没填模型名时观感保持现状',
    );
    expect(find.textContaining('deepseek-flash'), findsWidgets);
  });
}
