import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/message_bubble.dart';
import 'package:jarvis_app/src/features/memory/memory_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MessageSource _memorySource(String id) => MessageSource(
  url: 'memory://$id',
  fetchedAt: DateTime(2026, 10, 24).millisecondsSinceEpoch,
  kind: MessageSourceKind.memory,
  memoryId: id,
);

Widget _app(List<MessageSource> sources) {
  return ProviderScope(
    overrides: [
      memoryDetailProvider.overrideWith(
        (ref, id) async => MemoryDetail(
          memory: Memory(
            id: id,
            kind: MemoryKind.preference,
            status: MemoryStatus.active,
            content: '这条记忆的正文',
            source: MemorySourceKind.explicit,
            sensitivity: MemorySensitivity.normal,
            pinned: false,
            conflicting: false,
            confidence: 1,
            importance: 0.6,
            useCount: 0,
            createdAt: 0,
            updatedAt: 0,
          ),
          evidence: const <MemoryEvidence>[],
          recallCount: 0,
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(body: SourceChips(sources: sources)),
    ),
  );
}

void main() {
  testWidgets('记忆来源显示「来自记忆」而不是域名', (tester) async {
    await tester.pumpWidget(_app(<MessageSource>[_memorySource('mem_1')]));
    await tester.pumpAndSettle();

    expect(find.textContaining('来自记忆'), findsOneWidget);
    expect(find.byIcon(Icons.psychology_outlined), findsOneWidget);
  });

  testWidgets('点击记忆来源跳到详情页', (tester) async {
    await tester.pumpWidget(_app(<MessageSource>[_memorySource('mem_1')]));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('来自记忆'));
    await tester.pumpAndSettle();

    expect(find.byType(MemoryDetailPage), findsOneWidget);
    expect(find.text('这条记忆的正文'), findsOneWidget);
  });

  testWidgets('没有 memory_id 时不可点', (tester) async {
    await tester.pumpWidget(
      _app(<MessageSource>[
        MessageSource(
          url: 'memory://mem_1',
          fetchedAt: 1,
          kind: MessageSourceKind.memory,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('来自记忆'));
    await tester.pumpAndSettle();

    expect(find.byType(MemoryDetailPage), findsNothing);
  });

  testWidgets('超过三条记忆来源折叠，展开后全部显示', (tester) async {
    await tester.pumpWidget(
      _app(<MessageSource>[
        for (var index = 0; index < 5; index += 1) _memorySource('mem_$index'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('来自记忆'), findsNWidgets(3));
    expect(find.text('+2 条记忆'), findsOneWidget);

    await tester.tap(find.text('+2 条记忆'));
    await tester.pumpAndSettle();

    expect(find.textContaining('来自记忆'), findsNWidgets(5));
    expect(find.text('+2 条记忆'), findsNothing);
  });

  testWidgets('网页来源保持原有行为与图标', (tester) async {
    await tester.pumpWidget(
      _app(<MessageSource>[
        MessageSource(
          url: 'https://example.com/a',
          fetchedAt: DateTime(2026, 10, 24).millisecondsSinceEpoch,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.byIcon(Icons.link), findsOneWidget);
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
  });
}
