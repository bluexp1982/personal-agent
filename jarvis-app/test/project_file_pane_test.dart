import 'dart:async';

import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/core/project_paths.dart';
import 'package:jarvis_app/src/features/shell/chat_window_state.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/file_preview_view.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/shell/project_file_pane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

/// 拦下剪贴板调用：测试环境没有平台通道，不 mock 只能拿到空结果。
void _mockClipboard(WidgetTester tester, List<String> sink) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        sink.add((call.arguments as Map<dynamic, dynamic>)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

class _FixedTarget extends ShellTargetController {
  _FixedTarget(this.initial);

  final ShellTarget? initial;

  @override
  ShellTarget? build() => initial;
}

/// 聊天浮窗显示时中栏让给右栏，两栏之间的拖动条会被拿掉。
class _FloatingChat extends ChatWindowController {
  @override
  ChatWindowState build() => const ChatWindowState(floating: true);
}

Widget _harness({
  required FutureOr<ProjectListing> Function(ProjectListingKey key) listing,
  FutureOr<FileContent> Function(ProjectFileKey key)? content,
  Widget child = const ProjectFilePane(),
}) {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(
        () => _FixedTarget(const ProjectTarget(_project)),
      ),
      projectListingProvider.overrideWith((ref, key) => listing(key)),
      if (content != null)
        projectFileContentProvider.overrideWith((ref, key) => content(key)),
    ],
    child: MaterialApp(
      home: Scaffold(body: SizedBox(width: 320, height: 640, child: child)),
    ),
  );
}

void main() {
  testWidgets('树按目录优先渲染，文件显示大小与截断提示', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          truncated: true,
          entries: <ProjectEntry>[
            ProjectEntry(name: 'src', path: '/tmp/demo/src', kind: 'dir'),
            ProjectEntry(
              name: 'a.txt',
              path: '/tmp/demo/a.txt',
              kind: 'file',
              size: 1536,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('src'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.text('条目太多，只显示前 200 项'), findsOneWidget);
  });

  testWidgets('显示隐藏文件开关切换后重新取列表', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            const ProjectEntry(
              name: 'a.txt',
              path: '/tmp/demo/a.txt',
              kind: 'file',
            ),
            if (key.showHidden)
              const ProjectEntry(
                name: '.env',
                path: '/tmp/demo/.env',
                kind: 'file',
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('.env'), findsNothing);

    await tester.tap(find.byTooltip('显示隐藏文件'));
    await tester.pumpAndSettle();

    expect(find.text('.env'), findsOneWidget);
    expect(find.byTooltip('隐藏 . 开头的项'), findsOneWidget);
  });

  testWidgets('展开目录失败时显示原因', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) {
          if (key.path.isEmpty) {
            return const ProjectListing(
              path: '/tmp/demo',
              entries: <ProjectEntry>[
                ProjectEntry(name: 'bad', path: '/tmp/demo/bad', kind: 'dir'),
              ],
            );
          }
          throw const ApiException(
            code: 'invalid_request',
            message: 'unreadable',
            retryable: false,
            hint: '目录不可访问',
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('bad'));
    await tester.pumpAndSettle();

    expect(find.text('目录不可访问'), findsOneWidget);
  });

  testWidgets('预览失败显示可读提示', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(path: '/tmp/demo'),
        content: (key) => throw const ApiException(
          code: 'invalid_request',
          message: 'binary',
          retryable: false,
          hint: 'blob.bin 是二进制文件（或不是 UTF-8 文本），无法预览',
        ),
        // 预览标签自带路径：一个文件一个标签，不再从 provider 里取"当前文件"。
        child: const FilePreviewView(path: '/tmp/demo/blob.bin'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('blob.bin 是二进制文件（或不是 UTF-8 文本），无法预览'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('右键 html 文件给出「打开」「预览」与两个复制项', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(
              name: 'clock.html',
              path: '/tmp/demo/clock.html',
              kind: 'file',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('clock.html'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('打开'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('复制相对路径'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
  });

  testWidgets('右键非网页文件没有「预览」，复制两项仍在', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(
              name: 'api.md',
              path: '/tmp/demo/api.md',
              kind: 'file',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('api.md'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('打开'), findsOneWidget);
    expect(find.text('预览'), findsNothing);
    expect(find.text('复制相对路径'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
  });

  testWidgets('右键目录只给复制两项：展开 / 收起仍只占单击', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(name: 'src', path: '/tmp/demo/src', kind: 'dir'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('src'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('打开'), findsNothing);
    expect(find.text('预览'), findsNothing);
    expect(find.text('复制相对路径'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
  });

  testWidgets('复制相对路径以项目根为根，复制路径给服务端绝对路径', (tester) async {
    final copied = <String>[];
    _mockClipboard(tester, copied);
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(
              name: 'cat.html',
              path: '/tmp/demo/cat.html',
              kind: 'file',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('cat.html'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制相对路径'));
    // 菜单在下一帧收起后才会执行条目回调，复制完成再要一帧。
    await tester.pump();
    await tester.pump();

    expect(copied, <String>['cat.html']);
    expect(find.text('已复制相对路径：cat.html'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));

    await tester.tap(find.text('cat.html'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制路径'));
    await tester.pump();
    await tester.pump();

    expect(copied, <String>['cat.html', '/tmp/demo/cat.html']);
    expect(find.text('已复制路径：/tmp/demo/cat.html'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('文件与目录行都能拖出路径引用数据', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        _harness(
          listing: (key) => const ProjectListing(
            path: '/tmp/demo',
            entries: <ProjectEntry>[
              ProjectEntry(name: 'src', path: '/tmp/demo/src', kind: 'dir'),
              ProjectEntry(
                name: 'cat.html',
                path: '/tmp/demo/cat.html',
                kind: 'file',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      Draggable<ProjectPathReference> draggableOf(String label) {
        return tester.widget<Draggable<ProjectPathReference>>(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate(
                  (widget) => widget is Draggable<ProjectPathReference>,
                ),
              )
              .first,
        );
      }

      final file = draggableOf('cat.html').data!;
      expect(file.relativePath, 'cat.html');
      expect(file.absolutePath, '/tmp/demo/cat.html');
      expect(file.isDir, isFalse);

      final dir = draggableOf('src').data!;
      expect(dir.relativePath, 'src');
      expect(dir.absolutePath, '/tmp/demo/src');
      expect(dir.isDir, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('右键目录也能复制相对路径', (tester) async {
    final copied = <String>[];
    _mockClipboard(tester, copied);
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(name: 'styles', path: '/tmp/demo/styles', kind: 'dir'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('styles'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制相对路径'));
    await tester.pump();
    await tester.pump();

    expect(copied, <String>['styles']);
    expect(find.text('已复制相对路径：styles'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('单击文件只选中：不打开预览，行呈选中态', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(
              name: 'api.md',
              path: '/tmp/demo/api.md',
              kind: 'file',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.byType(ProjectFilePane)))
        .colorScheme;

    BoxDecoration rowDecoration() {
      final row = find
          .ancestor(of: find.text('api.md'), matching: find.byType(Container))
          .first;
      return tester.widget<Container>(row).decoration! as BoxDecoration;
    }

    InkWell rowInkWell() {
      return tester.widget<InkWell>(
        find
            .ancestor(of: find.text('api.md'), matching: find.byType(InkWell))
            .first,
      );
    }

    expect(
      rowInkWell().hoverColor,
      scheme.surfaceContainerHighest.withValues(alpha: 0.9),
      reason: '悬停底色与左栏项目 / 会话行同一套',
    );
    expect(rowDecoration().color, isNull, reason: '还没点之前不该有选中底色');
    expect(rowDecoration().border, isNull, reason: '选中不靠描边');

    // 行的悬停 / 选中块与左栏项目 / 会话行同一套外留白：
    // 普通布局左侧有拖动条（已让出 8），所以行块自己只补右侧 8。
    expect(
      tester
          .widget<Padding>(
            find.byKey(const ValueKey<String>('file-row-pill')).first,
          )
          .padding,
      const EdgeInsets.only(left: 0, right: kRailRowPillInset),
    );
    // 扣掉外层留白后，文字 / 文件大小到窗口边仍是 kPaneContentInset。
    expect(
      tester
          .widget<Container>(
            find
                .ancestor(
                  of: find.text('api.md'),
                  matching: find.byType(Container),
                )
                .first,
          )
          .padding,
      const EdgeInsets.only(
        left: kPaneEdgeInset,
        right: kPaneContentInset - kRailRowPillInset,
      ),
    );

    await tester.tap(find.text('api.md'));
    await tester.pumpAndSettle();

    expect(
      rowDecoration().color,
      scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      reason: '选中底与左栏同一档，且比悬停更淡',
    );
    expect(rowDecoration().border, isNull, reason: '不再画左侧主色边');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectFilePane)),
    );
    expect(
      container.read(filePaneTabProvider).activePreviewPath,
      isNull,
      reason: '单击不再打开预览，打开只能走右键「打开」',
    );
  });

  testWidgets('聊天浮窗让位、没有拖动条时，行块左侧自己补 8', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellTargetProvider.overrideWith(
            () => _FixedTarget(const ProjectTarget(_project)),
          ),
          projectListingProvider.overrideWith(
            (ref, key) => const ProjectListing(
              path: '/tmp/demo',
              entries: <ProjectEntry>[
                ProjectEntry(
                  name: 'api.md',
                  path: '/tmp/demo/api.md',
                  kind: 'file',
                ),
              ],
            ),
          ),
          // 聊天浮窗显示：中栏让给右栏，两栏之间的拖动条不再占位。
          chatWindowProvider.overrideWith(_FloatingChat.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, height: 640, child: ProjectFilePane()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Padding>(
            find.byKey(const ValueKey<String>('file-row-pill')).first,
          )
          .padding,
      const EdgeInsets.only(left: kRailRowPillInset, right: kRailRowPillInset),
      reason: '没有拖动条垫底时，左侧必须自己让出 8 才能与左栏视觉一致',
    );
  });

  testWidgets('右键「打开」打开预览，并让该行保持选中', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(
          path: '/tmp/demo',
          entries: <ProjectEntry>[
            ProjectEntry(
              name: 'cat.html',
              path: '/tmp/demo/cat.html',
              kind: 'file',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('cat.html'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectFilePane)),
    );
    expect(
      container.read(filePaneTabProvider).activePreviewPath,
      '/tmp/demo/cat.html',
    );

    final row = find
        .ancestor(of: find.text('cat.html'), matching: find.byType(Container))
        .first;
    expect(
      (tester.widget<Container>(row).decoration! as BoxDecoration).color,
      isNotNull,
      reason: '打开之后这一行仍应是选中态',
    );
  });

  testWidgets('右键菜单点树内空白与树外都会收起', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellTargetProvider.overrideWith(
            () => _FixedTarget(const ProjectTarget(_project)),
          ),
          projectListingProvider.overrideWith(
            (ref, key) => const ProjectListing(
              path: '/tmp/demo',
              entries: <ProjectEntry>[
                ProjectEntry(
                  name: 'api.md',
                  path: '/tmp/demo/api.md',
                  kind: 'file',
                ),
              ],
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: <Widget>[
                // 树只占左边 320，右侧留出真正的"树外"空白。
                SizedBox(width: 320, height: 600, child: ProjectFilePane()),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 树内空白：列表下方没有被行占满的区域。
    await tester.tap(find.text('api.md'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsOneWidget);
    await tester.tapAt(
      tester.getBottomRight(find.byType(ProjectFilePane)) -
          const Offset(16, 16),
    );
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsNothing, reason: '点树内空白应收起菜单');

    // 树外：右栏失去焦点时也要收起。
    await tester.tap(find.text('api.md'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byType(ProjectFilePane)) + const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsNothing, reason: '点树外应收起菜单');
  });

  testWidgets('预览每行带行号，行号不进入选区', (tester) async {
    await tester.pumpWidget(
      _harness(
        listing: (key) => const ProjectListing(path: '/tmp/demo'),
        content: (key) => const FileContent(
          path: '/tmp/demo/a.txt',
          size: 5,
          text: 'a\nb\nc',
        ),
        child: const FilePreviewView(path: '/tmp/demo/a.txt'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('a'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    final gutter = tester.widget<SelectionContainer>(
      find
          .ancestor(
            of: find.text('1'),
            matching: find.byType(SelectionContainer),
          )
          .first,
    );
    expect(
      gutter.delegate,
      isNull,
      reason: '行号用 SelectionContainer.disabled 包住，全选复制不会带上数字',
    );
  });
}
