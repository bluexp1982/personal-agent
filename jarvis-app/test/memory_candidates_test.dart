import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/features/memory/memory_candidates_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Memory _candidate(
  String id, {
  String? batchId = 'bat_1',
  bool private = false,
}) => Memory(
  id: id,
  kind: MemoryKind.preference,
  status: MemoryStatus.candidate,
  content: '候选 $id',
  source: MemorySourceKind.session,
  sensitivity: private ? MemorySensitivity.private : MemorySensitivity.normal,
  pinned: false,
  conflicting: false,
  confidence: 0.7,
  importance: 0.5,
  useCount: 0,
  createdAt: DateTime(2026, 10, 28).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 10, 28).millisecondsSinceEpoch,
  batchId: batchId,
);

class _FakeApi extends MemoryApi {
  _FakeApi() : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));

  final List<String> accepted = <String>[];
  final List<String> rejected = <String>[];
  final List<String> revoked = <String>[];

  @override
  Future<CandidateDecisionResult> decide({
    required List<String> ids,
    required bool accept,
  }) async {
    (accept ? accepted : rejected).addAll(ids);
    return CandidateDecisionResult(
      accepted: accept ? ids.length : 0,
      rejected: accept ? 0 : ids.length,
      skipped: const <String>[],
    );
  }

  @override
  Future<BatchRevokeResult> revokeBatch(String batchId, {String? reason}) async {
    revoked.add(batchId);
    return BatchRevokeResult(batchId: batchId, revoked: 2);
  }
}

Widget _app(List<CandidateBatch> batches, _FakeApi api) {
  return ProviderScope(
    overrides: [
      memoryApiProvider.overrideWith((ref) => api),
      memoryCandidatesProvider.overrideWith((ref) async => batches),
      memoryStateProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: MemoryCandidatesPage()),
  );
}

void main() {
  testWidgets('按批次分组，批次头显示来源与条数', (tester) async {
    await tester.pumpWidget(
      _app(<CandidateBatch>[
        CandidateBatch(
          batchId: 'bat_1',
          items: <Memory>[_candidate('mem_1'), _candidate('mem_2')],
          createdAt: DateTime(2026, 10, 28).millisecondsSinceEpoch,
        ),
      ], _FakeApi()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('2 条'), findsOneWidget);
    expect(find.text('撤销本批'), findsOneWidget);
    expect(find.text('候选 mem_1'), findsOneWidget);
  });

  testWidgets('接受单条会调用 decide', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(<CandidateBatch>[
        CandidateBatch(
          batchId: 'bat_1',
          items: <Memory>[_candidate('mem_1')],
          createdAt: 0,
        ),
      ], api),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('接受'));
    await tester.pumpAndSettle();

    expect(api.accepted, <String>['mem_1']);
  });

  testWidgets('撤销本批必须先确认', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(<CandidateBatch>[
        CandidateBatch(
          batchId: 'bat_1',
          items: <Memory>[_candidate('mem_1')],
          createdAt: 0,
        ),
      ], api),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('撤销本批'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这一批？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.revoked, isEmpty);

    await tester.tap(find.text('撤销本批'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('撤销')),
    );
    await tester.pumpAndSettle();

    expect(api.revoked, <String>['bat_1']);
  });

  testWidgets('私密候选带说明', (tester) async {
    await tester.pumpWidget(
      _app(<CandidateBatch>[
        CandidateBatch(
          batchId: 'bat_1',
          items: <Memory>[_candidate('mem_1', private: true)],
          createdAt: 0,
        ),
      ], _FakeApi()),
    );
    await tester.pumpAndSettle();

    expect(find.text('私密'), findsOneWidget);
    expect(find.text('不会进入日常对话的常驻记忆'), findsOneWidget);
  });

  testWidgets('没有候选时给空态', (tester) async {
    await tester.pumpWidget(_app(const <CandidateBatch>[], _FakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('没有待确认的记忆'), findsOneWidget);
  });
}
