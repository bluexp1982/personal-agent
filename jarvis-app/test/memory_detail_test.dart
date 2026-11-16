import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/features/memory/memory_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryDetail _detail({bool pinned = false, bool conflicting = false}) {
  return MemoryDetail(
    memory: Memory(
      id: 'mem_1',
      kind: MemoryKind.preference,
      status: MemoryStatus.active,
      content: '回答先给结论再给依据',
      source: MemorySourceKind.explicit,
      sensitivity: MemorySensitivity.normal,
      pinned: pinned,
      conflicting: conflicting,
      confidence: 0.92,
      importance: 0.7,
      useCount: 2,
      createdAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
      updatedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
    ),
    evidence: const <MemoryEvidence>[
      MemoryEvidence(
        id: 'ev_1',
        sourceKind: EvidenceSourceKind.explicit,
        sourceId: 'bat_1',
        quote: '我一般周三下午有空',
        supportSpan: '周三下午',
        createdAt: 1700000000000,
      ),
    ],
    recallCount: 3,
  );
}

/// 记录写操作的假接口。
class _FakeApi extends MemoryApi {
  _FakeApi() : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));

  final List<String> updates = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<MemoryDetail> update(
    String id, {
    String? content,
    bool? pinned,
    MemoryStatus? status,
    MemoryKind? kind,
    MemorySensitivity? sensitivity,
  }) async {
    updates.add('$id:pinned=$pinned:content=$content');
    return _detail(pinned: pinned ?? false);
  }

  @override
  Future<void> delete(String id) async {
    deletes.add(id);
  }
}

Widget _app(MemoryDetail detail, _FakeApi api) {
  return ProviderScope(
    overrides: [
      memoryDetailProvider.overrideWith((ref, id) async => detail),
      memoryApiProvider.overrideWith((ref) => api),
      memoryStateProvider.overrideWith((ref) async => null),
      memoryListProvider.overrideWith(
        (ref, key) async => const MemoryPage(items: <Memory>[]),
      ),
    ],
    child: const MaterialApp(home: MemoryDetailPage(memoryId: 'mem_1')),
  );
}

void main() {
  testWidgets('展示正文、元信息与依据', (tester) async {
    await tester.pumpWidget(_app(_detail(), _FakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('回答先给结论再给依据'), findsOneWidget);
    expect(find.textContaining('置信度 0.92'), findsOneWidget);
    expect(find.text('依据'), findsOneWidget);
    expect(find.text('被召回 3 次'), findsOneWidget);
  });

  testWidgets('support_span 在原文里高亮', (tester) async {
    await tester.pumpWidget(_app(_detail(), _FakeApi()));
    await tester.pumpAndSettle();

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    final span = selectable.textSpan!;
    final pieces = <String>[
      for (final child in span.children ?? const <InlineSpan>[])
        (child as TextSpan).text ?? '',
    ];

    expect(pieces, contains('周三下午'), reason: '支撑片段要单独成段才能上色');
    expect(pieces.join(), '我一般周三下午有空');
  });

  testWidgets('置顶按钮把 pinned 取反并写回服务端', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(_detail(), api));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();

    expect(api.updates, hasLength(1));
    expect(api.updates.first, contains('pinned=true'));
  });

  testWidgets('冲突时显示存在分歧', (tester) async {
    await tester.pumpWidget(_app(_detail(conflicting: true), _FakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('存在分歧：另有同主体的不同说法'), findsOneWidget);
  });

  testWidgets('删除前必须确认，文案写清后果', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(_detail(), api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除后，它不会再出现在回答里。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.deletes, isEmpty);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '删除'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.deletes, <String>['mem_1']);
  });

  testWidgets('记忆已删除时给出明确提示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryDetailProvider.overrideWith((ref, id) async => null),
          memoryApiProvider.overrideWith((ref) => _FakeApi()),
        ],
        child: const MaterialApp(home: MemoryDetailPage(memoryId: 'mem_x')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这条记忆不存在或已被删除'), findsOneWidget);
  });
}
