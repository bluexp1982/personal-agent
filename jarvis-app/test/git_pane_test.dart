import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/git_models.dart';
import 'package:jarvis_app/src/core/git_providers.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/git/git_pane.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'demo',
  mode: ProjectModes.code,
  path: '/tmp/demo',
);

/// 固定选中项：widget 测试里不驱动左侧导航，直接给一个项目目标。
class _FixedTarget extends ShellTargetController {
  _FixedTarget(this.initial);

  final ShellTarget? initial;

  @override
  ShellTarget? build() => initial;
}

/// 记录写操作的替身。
///
/// 只记调用不发请求：这几条路径的行为由服务端的集成测试（`tests/git_api.rs`）
/// 在真实仓库上验，这里要验的是"面板有没有把对的路径、对的动作发出去"。
class _RecordingActions extends GitActions {
  _RecordingActions(super.ref, this.calls);

  final List<String> calls;

  @override
  Future<GitStatusReport> stage(String projectId, List<String> paths) async {
    calls.add('stage:${paths.join(',')}');
    return const GitStatusReport(repo: true, detached: false);
  }

  @override
  Future<GitStatusReport> unstage(String projectId, List<String> paths) async {
    calls.add('unstage:${paths.join(',')}');
    return const GitStatusReport(repo: true, detached: false);
  }

  @override
  Future<GitStatusReport> discard(String projectId, List<String> paths) async {
    calls.add('discard:${paths.join(',')}');
    return const GitStatusReport(repo: true, detached: false);
  }

  @override
  Future<GitCommitResult> commit(String projectId, String message) async {
    calls.add('commit:$message');
    return GitCommitResult(
      commit: GitCommitSummary(
        hash: 'abcdef1234',
        shortHash: 'abcdef1',
        subject: message,
        author: '测试',
        timeMs: 0,
      ),
      status: const GitStatusReport(repo: true, detached: false),
    );
  }
}

Widget _harness({
  required GitStatusReport status,
  GitCommitsPage? log,
  GitDiffReport? diff,
  List<String>? calls,
  ShellTarget? target = const ProjectTarget(_project),
}) {
  final recorder = calls ?? <String>[];
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(() => _FixedTarget(target)),
      gitStatusProvider.overrideWith((ref, projectId) => status),
      gitLogProvider.overrideWith((ref, key) => log ?? const GitCommitsPage()),
      gitDiffProvider.overrideWith(
        (ref, key) => diff ?? const GitDiffReport(text: ''),
      ),
      gitActionsProvider.overrideWith(
        (ref) => _RecordingActions(ref, recorder),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        // 默认测试画布是 800×600：面板高度必须落在它之内，否则底部提交区
        // 会被裁到屏幕外，点它是点空的。
        body: SizedBox(width: 400, height: 560, child: const GitPane()),
      ),
    ),
  );
}

/// 悬停到某个控件上：行内动作按钮只在悬停时出现（槽位常驻、默认忽略指针）。
Future<void> _hover(WidgetTester tester, Finder finder) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(finder)));
  await tester.pumpAndSettle();
}

GitFileChange _change(String path, GitFileState state) =>
    GitFileChange(path: path, state: state);

void main() {
  testWidgets('分支栏显示分支与变更条数，三组变更各自成组', (tester) async {
    await tester.pumpWidget(
      _harness(
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          staged: <GitFileChange>[_change('a.dart', GitFileState.modified)],
          unstaged: <GitFileChange>[_change('b.dart', GitFileState.modified)],
          untracked: <GitFileChange>[_change('c.dart', GitFileState.untracked)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('main'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: '分支栏的变更总数胶囊');
    expect(find.text('已暂存 1'), findsOneWidget);
    expect(find.text('更改 1'), findsOneWidget);
    expect(find.text('未跟踪 1'), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('c.dart'), findsOneWidget);
  });

  testWidgets('悬停后暂存一个未跟踪文件，把仓库内相对路径发给服务端', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _harness(
        calls: calls,
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          untracked: <GitFileChange>[
            _change('src/fresh.dart', GitFileState.untracked),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _hover(tester, find.text('fresh.dart'));
    await tester.tap(find.byTooltip('暂存'));
    await tester.pumpAndSettle();

    expect(calls, <String>['stage:src/fresh.dart']);
  });

  testWidgets('没有暂存内容时提交按钮禁用并写明原因', (tester) async {
    await tester.pumpWidget(
      _harness(
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          unstaged: <GitFileChange>[_change('b.dart', GitFileState.modified)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有已暂存的内容'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '提交'),
    );
    expect(button.onPressed, isNull, reason: '暂存区是空的，不能提交');
  });

  testWidgets('写完提交信息点提交，带着原文发给服务端', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _harness(
        calls: calls,
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          staged: <GitFileChange>[_change('a.dart', GitFileState.added)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'feat: 加 Git 面板');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提交'));
    await tester.pumpAndSettle();

    expect(calls, <String>['commit:feat: 加 Git 面板']);
  });

  testWidgets('撤销要先二次确认，取消不会动仓库', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _harness(
        calls: calls,
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          unstaged: <GitFileChange>[_change('b.dart', GitFileState.modified)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _hover(tester, find.text('b.dart'));
    await tester.tap(find.byTooltip('撤销改动'));
    await tester.pumpAndSettle();

    expect(find.text('撤销这些改动？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty, reason: '取消之后不能发任何写请求');

    await _hover(tester, find.text('b.dart'));
    await tester.tap(find.byTooltip('撤销改动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(calls, <String>['discard:b.dart']);
  });

  testWidgets('不是 Git 仓库时给出空态而不是报错', (tester) async {
    await tester.pumpWidget(
      _harness(status: GitStatusReport.notARepo('已选目录不是 Git 仓库')),
    );
    await tester.pumpAndSettle();

    expect(find.text('这里还不是 Git 仓库'), findsOneWidget);
    expect(find.text('已选目录不是 Git 仓库'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '这不是错误，不该出现重试');
  });

  testWidgets('没选项目时提示先选项目', (tester) async {
    await tester.pumpWidget(
      _harness(
        status: const GitStatusReport(repo: true, detached: false),
        target: null,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('先在左侧选择一个项目'), findsOneWidget);
  });

  testWidgets('点一行文件看 diff，返回回到列表', (tester) async {
    await tester.pumpWidget(
      _harness(
        status: GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
          unstaged: <GitFileChange>[_change('b.dart', GitFileState.modified)],
        ),
        diff: const GitDiffReport(
          text: '@@ -1 +1 @@\n-旧的一行\n+新的一行\n',
          path: 'b.dart',
          additions: 1,
          deletions: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('b.dart'));
    await tester.pumpAndSettle();

    expect(find.text('-旧的一行'), findsOneWidget);
    expect(find.text('+新的一行'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(find.text('b.dart'), findsOneWidget, reason: '回到变更列表');
  });

  testWidgets('历史视图列出提交，点一条看该提交的 diff', (tester) async {
    await tester.pumpWidget(
      _harness(
        status: const GitStatusReport(
          repo: true,
          detached: false,
          branch: 'main',
        ),
        log: const GitCommitsPage(
          commits: <GitCommitSummary>[
            GitCommitSummary(
              hash: 'abcdef1234',
              shortHash: 'abcdef1',
              subject: 'feat: 面板',
              author: '测试',
              timeMs: 0,
            ),
          ],
        ),
        diff: const GitDiffReport(
          text: '@@ -0,0 +1 @@\n+新文件的一行\n',
          commit: 'abcdef1234',
          additions: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('feat: 面板'), findsOneWidget);

    await tester.tap(find.text('feat: 面板'));
    await tester.pumpAndSettle();
    expect(find.text('提交 abcdef1'), findsOneWidget);
    expect(find.text('+新文件的一行'), findsOneWidget);
  });
}
