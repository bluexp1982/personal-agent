import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/features/memory/memory_menu.dart';
import 'package:jarvis_app/src/features/memory/memory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Memory _memory(String id, String content, {bool pinned = false}) => Memory(
  id: id,
  kind: MemoryKind.preference,
  status: MemoryStatus.active,
  content: content,
  source: MemorySourceKind.explicit,
  sensitivity: MemorySensitivity.normal,
  pinned: pinned,
  conflicting: false,
  confidence: 1,
  importance: 0.6,
  useCount: 0,
  createdAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
);

const _state = MemoryStateView(
  enabled: true,
  counts: MemoryCounts(active: 2, candidate: 4),
  digest: DigestSummary(chars: 120, memoryItems: 2),
  extract: ExtractQuota(enabled: false, dailyLimit: 50, usedToday: 0),
  heartbeat: HeartbeatView(),
);

/// 记录手动整理 / 清空归档调用并按需返回状态快照的假接口。
class _FakeApi extends MemoryApi {
  _FakeApi() : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));

  int organizeCalls = 0;
  MemoryStateView stateAfter = _state;

  int purgeCalls = 0;
  MemoryKind? purgedKind;
  int purgeResult = 3;

  @override
  Future<int> organize() async {
    organizeCalls += 1;
    return 1000;
  }

  @override
  Future<MemoryStateView> state() async => stateAfter;

  @override
  Future<int> purgeArchived({MemoryKind? kind}) async {
    purgeCalls += 1;
    purgedKind = kind;
    return purgeResult;
  }
}

/// 有 3 条归档的快照：归档数 > 0 时「清空归档」才是可点的子菜单。
const _stateWithArchived = MemoryStateView(
  enabled: true,
  counts: MemoryCounts(active: 2, archived: 3),
  digest: DigestSummary(chars: 120, memoryItems: 2),
  extract: ExtractQuota(enabled: false, dailyLimit: 50, usedToday: 0),
  heartbeat: HeartbeatView(),
);

Widget _app({
  required Future<MemoryPage> Function(Ref ref, MemoryQuery key) list,
  MemoryStateView? state = _state,
  Future<MemoryStateView?> Function(Ref ref)? stateOverride,
  MemoryApi? api,
}) {
  return ProviderScope(
    overrides: [
      if (api != null) memoryApiProvider.overrideWith((ref) => api),
      memoryStateProvider.overrideWith(
        stateOverride ?? (ref) async => state,
      ),
      memoryListProvider.overrideWith(list),
    ],
    child: const MaterialApp(home: MemoryListPage()),
  );
}

void main() {
  testWidgets('空态给出下一步提示', (tester) async {
    await tester.pumpWidget(
      _app(list: (ref, key) async => const MemoryPage(items: <Memory>[])),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('还没有记忆。你可以直接说"记住…"，或在候选里确认'),
      findsOneWidget,
    );
  });

  testWidgets('服务不可达时说明记忆是服务端权威', (tester) async {
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => throw const ApiException(
          code: 'internal_error',
          message: 'offline',
          retryable: false,
          hint: '服务内部错误',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('连不上服务端，记忆是服务端权威，无法离线查看'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('列表行显示正文与元信息，置顶有图标', (tester) async {
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => MemoryPage(
          items: <Memory>[
            _memory('mem_1', '回答先给结论再给依据', pinned: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('回答先给结论再给依据'), findsOneWidget);
    expect(find.textContaining('偏好 · 用户设定'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
  });

  testWidgets('类型筛选把 kind 传给列表查询', (tester) async {
    final keys = <MemoryQuery>[];
    await tester.pumpWidget(
      _app(
        list: (ref, key) async {
          keys.add(key);
          return const MemoryPage(items: <Memory>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(keys.last.kind, isNull);

    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    expect(keys.last.kind, MemoryKind.event);
    expect(keys.last.status, MemoryStatus.active);
  });

  testWidgets('顶部显示候选数量与抽取额度', (tester) async {
    await tester.pumpWidget(
      _app(list: (ref, key) async => const MemoryPage(items: <Memory>[])),
    );
    await tester.pumpAndSettle();

    expect(find.text('生效 2 · 候选 4 · 已归档 0'), findsOneWidget);
    expect(find.text('自动抽取未开启'), findsOneWidget);
  });

  testWidgets('置顶超预算的告警显示在顶部', (tester) async {
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        state: const MemoryStateView(
          enabled: true,
          counts: MemoryCounts(active: 1),
          digest: DigestSummary(),
          extract: ExtractQuota(),
          heartbeat: HeartbeatView(),
          digestWarning: '置顶记忆共 320 字，超过摘要预算 300 字，请取消部分置顶',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('超过摘要预算'), findsOneWidget);
  });

  testWidgets('删除后会重新拉取列表（invalidate 不改坏页面）', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        list: (ref, key) async {
          calls += 1;
          return MemoryPage(items: <Memory>[_memory('mem_1', '不吃香菜')]);
        },
      ),
    );
    await tester.pumpAndSettle();
    // 进入页面会主动 invalidate 一次（记忆是后台写入的，不能复用上一次的缓存），
    // 所以首次加载至少会查一次，通常是两次。
    expect(calls, greaterThanOrEqualTo(1));
    expect(find.text('不吃香菜'), findsOneWidget);
  });

  testWidgets('点整理后进入忙碌态，轮询到结果后提示摘要', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        api: api,
      ),
    );
    await tester.pumpAndSettle();

    // 「整理」收在「⋯」菜单里。
    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整理'));
    await tester.pump();
    await tester.pump();

    expect(api.organizeCalls, 1);
    expect(find.textContaining('正在整理记忆'), findsOneWidget);

    // 服务端这一轮跑完：下一次轮询能读到结果与水位。
    api.stateAfter = const MemoryStateView(
      enabled: true,
      counts: MemoryCounts(active: 2),
      digest: DigestSummary(),
      extract: ExtractQuota(),
      heartbeat: HeartbeatView(),
      maintenance: MaintenanceView(
        lastOrganizedAt: 1000,
        lastReport: MaintenanceReportView(
          recomputed: 3,
          decayed: 2,
          consolidated: 1,
          modelAvailable: true,
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('重算 3 个主体 · 归并 1 条 · 归档 2 条'), findsOneWidget);

    // 完成后菜单项恢复可点。
    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();
    expect(find.text('整理'), findsOneWidget);
  });

  testWidgets('重新进入页面时仍在整理：显示状态条并接着轮询到完成', (tester) async {
    final api = _FakeApi();
    api.stateAfter = const MemoryStateView(
      enabled: true,
      counts: MemoryCounts(active: 1),
      digest: DigestSummary(),
      extract: ExtractQuota(),
      heartbeat: HeartbeatView(),
      maintenance: MaintenanceView(organizing: true),
    );

    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        api: api,
        stateOverride: (ref) async => api.stateAfter,
      ),
    );
    // 状态条与按钮里都有转圈动画：`pumpAndSettle` 永远等不到静止。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 忙碌态来自服务端快照，不是本页的临时状态：退出再进来同样看得到。
    expect(find.textContaining('正在整理记忆'), findsOneWidget);

    // 忙碌时菜单里的「整理中」置灰：同一时刻只允许一轮整理。
    // （状态条有转圈动画，开菜单只能用 pump 走完过场，不能 pumpAndSettle。）
    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final item = tester.widget<MenuItemButton>(
      find.ancestor(of: find.text('整理中'), matching: find.byType(MenuItemButton)),
    );
    expect(item.onPressed, isNull);

    // 服务端这一轮跑完：下一次轮询刷新状态并提示结果。
    api.stateAfter = const MemoryStateView(
      enabled: true,
      counts: MemoryCounts(active: 1),
      digest: DigestSummary(),
      extract: ExtractQuota(),
      heartbeat: HeartbeatView(),
      maintenance: MaintenanceView(
        lastOrganizedAt: 2000,
        lastReport: MaintenanceReportView(decayed: 1, modelAvailable: true),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('归档 1 条'), findsOneWidget);
    expect(find.textContaining('正在整理记忆'), findsNothing);
    // 菜单还开着：忙碌项变回可点的「整理」。
    expect(find.text('整理'), findsOneWidget);
  });

  testWidgets('provider 为空时按空态渲染（未登录）', (tester) async {
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        stateOverride: (ref) async => null,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有记忆'), findsOneWidget);
  });

  testWidgets('整理、候选、导出收进「⋯」菜单，子页面项带省略号', (tester) async {
    await tester.pumpWidget(
      _app(list: (ref, key) async => const MemoryPage(items: <Memory>[])),
    );
    await tester.pumpAndSettle();

    // 标题栏不再有文字按钮。
    expect(find.text('整理'), findsNothing);
    expect(find.text('导出'), findsNothing);

    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();

    expect(find.text('整理'), findsOneWidget);
    expect(find.text('候选…'), findsOneWidget);
    expect(find.text('导出…'), findsOneWidget);
    // 候选数以徽标形式跟在菜单项后面。
    expect(find.text('4'), findsOneWidget);

    // 没有归档可清时「清空归档」是不可点的普通行。
    final purge = tester.widget<MenuItemButton>(
      find.ancestor(of: find.text('清空归档'), matching: find.byType(MenuItemButton)),
    );
    expect(purge.onPressed, isNull);
  });

  testWidgets('清空归档：先弹确认框，取消不调用接口', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        state: _stateWithArchived,
        api: api,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(memoryPurgeMenuKey(null)));
    await tester.pumpAndSettle();

    expect(find.text('清空全部已归档的记忆？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.purgeCalls, 0);
  });

  testWidgets('清空归档：确认后清除全部并提示条数', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        state: _stateWithArchived,
        api: api,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(memoryPurgeMenuKey(null)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(api.purgeCalls, 1);
    expect(api.purgedKind, isNull, reason: '「全部」不带类别条件');
    expect(find.text('已清除 3 条归档记忆'), findsOneWidget);
  });

  testWidgets('清空归档：按类别清除时把类别传给接口', (tester) async {
    final api = _FakeApi();
    api.purgeResult = 1;
    await tester.pumpWidget(
      _app(
        list: (ref, key) async => const MemoryPage(items: <Memory>[]),
        state: _stateWithArchived,
        api: api,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kMemoryMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空归档'));
    await tester.pumpAndSettle();
    // 子菜单里的「偏好」和筛选行的「偏好」同名，按 Key 点才可靠。
    await tester.tap(find.byKey(memoryPurgeMenuKey(MemoryKind.preference)));
    await tester.pumpAndSettle();

    expect(find.text('清空已归档的「偏好」记忆？'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(api.purgedKind, MemoryKind.preference);
    expect(find.text('已清除 1 条归档记忆'), findsOneWidget);
  });
}

