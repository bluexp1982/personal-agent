import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/features/memory/entity_page.dart';
import 'package:jarvis_app/src/features/memory/memory_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Entity _entity({String snapshot = '这位是 A 公司的对接人，最近在谈续约。'}) => Entity(
  id: 'ent_1',
  entityType: EntityType.person,
  name: '王工',
  status: EntityStatus.active,
  aliases: const <String>['老王'],
  confidence: 0.8,
  evidenceCount: 2,
  createdAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 28).millisecondsSinceEpoch,
  snapshot: snapshot,
  snapshotAt: DateTime(2026, 10, 28).millisecondsSinceEpoch,
);

Memory _memory(String id, String content) => Memory(
  id: id,
  kind: MemoryKind.event,
  status: MemoryStatus.active,
  content: content,
  source: MemorySourceKind.session,
  sensitivity: MemorySensitivity.normal,
  pinned: false,
  conflicting: false,
  confidence: 0.9,
  importance: 0.6,
  useCount: 0,
  createdAt: DateTime(2026, 10, 24).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 24).millisecondsSinceEpoch,
);

class _FakeApi extends MemoryApi {
  _FakeApi() : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));
}

Widget _app(EntityDetail detail) {
  return ProviderScope(
    overrides: [
      memoryApiProvider.overrideWith((ref) => _FakeApi()),
      memoryEntityProvider.overrideWith((ref, id) async => detail),
      memoryEntitiesProvider.overrideWith(
        (ref, key) async => EntityPage(
          items: <Entity>[
            detail.entity,
            const Entity(
              id: 'ent_2',
              entityType: EntityType.person,
              name: '李经理',
              status: EntityStatus.active,
              aliases: <String>[],
              confidence: 0.8,
              evidenceCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          ],
        ),
      ),
      memoryStateProvider.overrideWith((ref) async => null),
      memoryDetailProvider.overrideWith((ref, id) async => null),
    ],
    child: const MaterialApp(home: EntityDetailPage(entityId: 'ent_1')),
  );
}

void main() {
  testWidgets('渲染快照、别名与时间线', (tester) async {
    await tester.pumpWidget(
      _app(
        EntityDetail(
          entity: _entity(),
          timeline: <Memory>[_memory('mem_1', '与王工确认了续约价格')],
          snapshots: const <EntitySnapshotItem>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('王工'), findsOneWidget);
    expect(find.textContaining('A 公司的对接人'), findsOneWidget);
    expect(find.text('别名：老王'), findsOneWidget);
    expect(find.text('与王工确认了续约价格'), findsOneWidget);
    expect(find.textContaining('更新于'), findsOneWidget);
  });

  testWidgets('没有快照时说明什么时候会有', (tester) async {
    await tester.pumpWidget(
      _app(
        EntityDetail(
          entity: _entity(snapshot: ''),
          timeline: const <Memory>[],
          snapshots: const <EntitySnapshotItem>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有快照。夜间整理会为它生成一句话状态。'), findsOneWidget);
  });

  testWidgets('点时间线进记忆详情', (tester) async {
    await tester.pumpWidget(
      _app(
        EntityDetail(
          entity: _entity(),
          timeline: <Memory>[_memory('mem_1', '与王工确认了续约价格')],
          snapshots: const <EntitySnapshotItem>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('与王工确认了续约价格'));
    await tester.pumpAndSettle();

    expect(find.byType(MemoryDetailPage), findsOneWidget);
  });

  testWidgets('合并确认文案写清后果', (tester) async {
    await tester.pumpWidget(
      _app(
        EntityDetail(
          entity: _entity(),
          timeline: const <Memory>[],
          snapshots: const <EntitySnapshotItem>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('合并到…'));
    await tester.pumpAndSettle();
    expect(find.text('合并到哪个实体？'), findsOneWidget);

    await tester.tap(find.text('李经理'));
    await tester.pumpAndSettle();

    expect(find.textContaining('记忆会全部转投到'), findsOneWidget);
    expect(find.textContaining('被合并方不再出现在列表里'), findsOneWidget);
  });
}
