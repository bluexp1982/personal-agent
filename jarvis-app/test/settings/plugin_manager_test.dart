import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/capability_revision.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/settings/plugin_manager_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 技能包卡片：列表、三态徽标、空态与待生效提示。
///
/// 不接真实服务：`/api/plugins` 用固定响应，卡片只负责把它渲染成可读的状态。

Map<String, dynamic> _skill({
  required String name,
  required String status,
  List<String> reasons = const <String>[],
  String riskLevel = 'read',
}) {
  return <String, dynamic>{
    'name': name,
    'version': '1.0.0',
    'source': 'third_party',
    'risk_level': riskLevel,
    'status': status,
    'reasons': reasons,
    'description': '$name 的说明',
  };
}

Map<String, dynamic> _page({
  bool pendingReload = false,
  List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
}) {
  return <String, dynamic>{
    'items': items,
    'pending_reload': pendingReload,
  };
}

Widget _harness(Map<String, dynamic> body) {
  final client = MockClient(
    (http.Request request) async =>
        http.Response(jsonEncode(body), 200, headers: <String, String>{
          'content-type': 'application/json',
        }),
  );

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
      home: Scaffold(body: SingleChildScrollView(child: PluginManagerCard())),
    ),
  );
}

/// 与 `_harness` 同一套客户端，但把 container 交给测试。
///
/// 断言"操作后能力清单被要求重新拉取"时需要读 provider，内部自建的
/// `ProviderScope` 拿不到 container。
ProviderContainer _container(Map<String, dynamic> body) {
  final client = MockClient(
    (http.Request request) async =>
        http.Response(jsonEncode(body), 200, headers: <String, String>{
          'content-type': 'application/json',
        }),
  );

  return ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
    ],
  );
}

void main() {
  testWidgets('没有插件时给出空态并说明内置技能不需要装', (tester) async {
    await tester.pumpWidget(_harness(_page()));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有安装技能包'), findsOneWidget);
    expect(find.textContaining('内置技能'), findsOneWidget);
  });

  testWidgets('插件与技能列表渲染出三态徽标', (tester) async {
    await tester.pumpWidget(
      _harness(
        _page(
          items: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'com.example.demo',
              'name': '演示包',
              'version': '1.0.0',
              'enabled': true,
              'skills': <Map<String, dynamic>>[
                _skill(name: 'ok-skill', status: 'supported'),
                _skill(name: 'warn-skill', status: 'degraded', reasons: <String>[
                  '正文提到脚本，可能无法完成',
                ]),
                _skill(
                  name: 'shell-skill',
                  status: 'unsupported',
                  reasons: <String>['依赖 Bash：本机没有通用 shell'],
                ),
              ],
            },
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('演示包'), findsOneWidget);
    expect(find.text('ok-skill'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('降级'), findsOneWidget);
    expect(find.text('不支持'), findsOneWidget);

    // 不支持的原因是用户唯一能看到的解释，不能被截断掉。
    expect(find.textContaining('本机没有通用 shell'), findsOneWidget);
  });

  testWidgets('待生效时提示要等任务结束', (tester) async {
    await tester.pumpWidget(_harness(_page(pendingReload: true)));
    await tester.pumpAndSettle();

    expect(find.textContaining('执行进程空闲后才会重新加载技能'), findsOneWidget);
  });

  testWidgets('停用开关会发 PATCH 并回到服务端状态', (tester) async {
    var patched = false;

    final client = MockClient((http.Request request) async {
      if (request.method == 'PATCH') {
        patched = true;
        return http.Response(
          jsonEncode(
            _page(
              items: <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'com.example.demo',
                  'name': '演示包',
                  'version': '1.0.0',
                  'enabled': false,
                  'skills': <Map<String, dynamic>>[],
                },
              ],
            ),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }

      return http.Response(
        jsonEncode(
          _page(
            items: <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'com.example.demo',
                'name': '演示包',
                'version': '1.0.0',
                'enabled': true,
                'skills': <Map<String, dynamic>>[],
              },
            ],
          ),
        ),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(
      ProviderScope(
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
          home: Scaffold(
            body: SingleChildScrollView(child: PluginManagerCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byType(Switch);
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(patched, isTrue, reason: '停用应发一次 PATCH');
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });

  /// 设置页改完技能包，必须让"技能清单"类 provider 重新拉一次。
  ///
  /// 少了这条，`@` 候选会一直停在首次加载的结果上——用户只看到
  /// "设置里装了，聊天里没有"，只能重启客户端。
  testWidgets('启停技能包后让技能清单失效', (tester) async {
    final container = _container(
      _page(
        items: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'com.example.demo',
            'name': '演示包',
            'version': '1.0.0',
            'enabled': true,
            'skills': <Map<String, dynamic>>[],
          },
        ],
      ),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PluginManagerCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = container.read(capabilityRevisionProvider);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      container.read(capabilityRevisionProvider),
      before + 1,
      reason: '改完技能包要让 `@` 候选重新拉清单，否则只能重启客户端',
    );
  });
}
