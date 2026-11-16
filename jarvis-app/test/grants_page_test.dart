import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/features/memory/grants_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定的"现在"，让剩余时间文案可断言。
const int _now = 1_800_000_000_000;

Grant _grant({
  String id = 'grt_1',
  String tool = 'code.write',
  GrantScope scope = GrantScope.task,
  GrantRisk risk = GrantRisk.reversibleWrite,
  int expiresInMs = 3_600_000,
  int hitCount = 2,
}) {
  return Grant(
    id: id,
    tool: tool,
    risk: risk,
    scope: scope,
    scopeId: 'scope_$id',
    approvedBy: 'apv_$id',
    createdAt: _now - 60_000,
    expiresAt: _now + expiresInMs,
    hitCount: hitCount,
  );
}

class _FakeApi extends MemoryApi {
  _FakeApi() : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));

  final List<String> revoked = <String>[];

  @override
  Future<void> revokeGrant(String id) async {
    revoked.add(id);
  }
}

Widget _app(List<Grant> grants, _FakeApi api) {
  return ProviderScope(
    overrides: [
      memoryApiProvider.overrideWith((ref) => api),
      memoryGrantsProvider.overrideWith((ref) async => grants),
    ],
    child: const MaterialApp(home: GrantsPage()),
  );
}

void main() {
  group('剩余时间文案', () {
    test('分秒 / 小时 / 天 / 已过期 四档', () {
      expect(
        _grant(expiresInMs: 90 * 1000).remaining(_now),
        '1 分 30 秒',
      );
      expect(_grant(expiresInMs: 3 * 3_600_000).remaining(_now), '3 小时');
      expect(_grant(expiresInMs: 5 * 86_400_000).remaining(_now), '5 天');
      expect(_grant(expiresInMs: -1000).remaining(_now), '已过期');
    });
  });

  testWidgets('按作用域分组，组头带条数', (tester) async {
    await tester.pumpWidget(
      _app(<Grant>[
        _grant(id: 'a'),
        _grant(id: 'b'),
        _grant(id: 'c', scope: GrantScope.project),
      ], _FakeApi()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('本任务 · 2 条'), findsOneWidget);
    expect(find.textContaining('本项目（7 天） · 1 条'), findsOneWidget);
    expect(find.text('code.write'), findsNWidgets(3));
  });

  testWidgets('撤销要二次确认，确认后调用接口', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(<Grant>[_grant()], api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这条授权？'), findsOneWidget);
    expect(find.text('下一次同类操作会重新询问你。'), findsOneWidget);

    // 先取消：不该发请求。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.revoked, isEmpty);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤销'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.revoked, <String>['grt_1'], reason: '确认后才真的撤销');
  });

  testWidgets('没有授权时说明怎么产生', (tester) async {
    await tester.pumpWidget(_app(const <Grant>[], _FakeApi()));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('没有生效中的授权'),
      findsOneWidget,
    );
  });
}
