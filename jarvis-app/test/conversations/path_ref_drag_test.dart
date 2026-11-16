import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:jarvis_app/src/features/shell/project_file_pane.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/demo',
);

const List<ProjectEntry> _entries = <ProjectEntry>[
  ProjectEntry(name: 'styles', path: '/tmp/demo/styles', kind: 'dir'),
  ProjectEntry(name: 'cat.html', path: '/tmp/demo/cat.html', kind: 'file'),
];

class _FixedTarget extends ShellTargetController {
  _FixedTarget(this.initial);

  final ShellTarget? initial;

  @override
  ShellTarget? build() => initial;
}

/// 文件树在上、输入栏在下：拖拽的两端都在同一棵树里，和真实宽屏一致。
Future<QuillController> _pump(WidgetTester tester) async {
  final controller = QuillController.basic();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        shellTargetProvider.overrideWith(
          () => _FixedTarget(const ProjectTarget(_project)),
        ),
        projectListingProvider.overrideWith(
          (ref, key) =>
              const ProjectListing(path: '/tmp/demo', entries: _entries),
        ),
        apiClientProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const Expanded(child: ProjectFilePane()),
              ChatComposer(
                controller: controller,
                sending: false,
                onSend: () {},
                onStop: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// 从文件树的一行拖到输入栏。
///
/// 先横向挪一点再往下走：文件树是 `ListView`，垂直方向会先和滚动手势竞争，
/// 横向位移能让 `Draggable` 立刻赢下竞技场（真实拖动也是先离开行的横向范围）。
Future<void> _dragToComposer(WidgetTester tester, String label) async {
  final from = tester.getCenter(find.text(label));
  final to = tester.getCenter(find.byKey(kChatComposerPanelKey));

  final gesture = await tester.startGesture(from);
  await tester.pump();
  await gesture.moveBy(const Offset(24, 0));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('文件拖进输入栏：插入路径芯片，正文是相对路径', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = await _pump(tester);

      await _dragToComposer(tester, 'cat.html');

      expect(pathRefEmbeds(controller), hasLength(1));
      expect(pathRefEmbeds(controller).single.name, 'cat.html');
      expect(pathRefEmbeds(controller).single.relativePath, 'cat.html');
      expect(
        pathRefEmbeds(controller).single.absolutePath,
        '/tmp/demo/cat.html',
      );
      expect(pathRefEmbeds(controller).single.isDir, isFalse);
      expect(composerText(controller), 'cat.html');
      expect(attachmentIds(controller), isEmpty, reason: '路径引用不是附件，不能混进附件 id');
      // 芯片的悬停提示是服务端绝对路径。
      expect(find.byTooltip('/tmp/demo/cat.html'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('目录拖进输入栏：相对路径不带子目录内容', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = await _pump(tester);

      await _dragToComposer(tester, 'styles');

      expect(pathRefEmbeds(controller).single.isDir, isTrue);
      expect(pathRefEmbeds(controller).single.relativePath, 'styles');
      expect(composerText(controller), 'styles');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('删除芯片：节点与尾随空格一起清掉，正文回到空', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final controller = await _pump(tester);
      await _dragToComposer(tester, 'cat.html');

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(pathRefEmbeds(controller), isEmpty);
      expect(composerText(controller), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
