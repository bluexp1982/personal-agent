import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/memory/memory_api.dart';
import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/memory/memory_providers.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/features/memory/memory_export_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = Project(
  id: 'ws_1',
  name: 'personal-agent',
  mode: ProjectModes.code,
  path: '/tmp/personal-agent',
);

class _FakeApi extends MemoryApi {
  _FakeApi({this.applyError})
    : super(ApiClient(baseUrl: 'http://127.0.0.1:1'));

  final ApiException? applyError;
  final List<String> applied = <String>[];

  @override
  Future<ExportPreview> exportPreview(String projectId) async {
    return const ExportPreview(
      projectId: 'ws_1',
      path: '/tmp/personal-agent/AGENTS.md',
      diff: '--- a/AGENTS.md\n+++ b/AGENTS.md\n-旧的一条\n+时间统一用毫秒\n',
      entries: 1,
      contentHash: 'abc123',
    );
  }

  @override
  Future<void> exportApply({
    required String projectId,
    required String expectedHash,
  }) async {
    applied.add(expectedHash);
    if (applyError != null) {
      throw applyError!;
    }
  }
}

Widget _app(_FakeApi api) {
  return ProviderScope(
    overrides: [
      memoryApiProvider.overrideWith((ref) => api),
      projectsProvider.overrideWith((ref) async => <Project>[_project]),
      memoryStateProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: MemoryExportPage()),
  );
}

void main() {
  testWidgets('预览显示 diff 与条数，写入后调用 apply', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('personal-agent'));
    await tester.pumpAndSettle();

    expect(find.text('1 条记忆将写入'), findsOneWidget);
    expect(find.text('+时间统一用毫秒'), findsOneWidget);
    expect(find.text('-旧的一条'), findsOneWidget);

    await tester.tap(find.text('写入文件'));
    await tester.pumpAndSettle();

    expect(api.applied, <String>['abc123']);
  });

  testWidgets('哈希不一致时提示重新预览', (tester) async {
    final api = _FakeApi(
      applyError: const ApiException(
        code: 'conflict',
        message: 'hash mismatch',
        retryable: false,
        hint: '文件已被改动，请重新预览后再写入',
      ),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('personal-agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写入文件'));
    await tester.pumpAndSettle();

    expect(find.text('文件已被改动，请重新预览'), findsOneWidget);
    // 预览失效后不能再点写入。
    expect(find.text('写入文件'), findsNothing);
  });

  testWidgets('没有 Git 项目时给提示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryApiProvider.overrideWith((ref) => _FakeApi()),
          projectsProvider.overrideWith(
            (ref) async => const <Project>[],
          ),
        ],
        child: const MaterialApp(home: MemoryExportPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有 Git 项目'), findsOneWidget);
  });

  testWidgets('普通项目不参与 AGENTS.md 导出', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryApiProvider.overrideWith((ref) => _FakeApi()),
          projectsProvider.overrideWith(
            (ref) async => const <Project>[
              Project(
                id: 'ws_plain',
                name: '资料整理',
                mode: ProjectModes.work,
                path: '/tmp/docs',
              ),
            ],
          ),
        ],
        child: const MaterialApp(home: MemoryExportPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有 Git 项目'), findsOneWidget);
    expect(find.text('资料整理'), findsNothing);
  });
}
