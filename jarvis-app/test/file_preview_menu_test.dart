import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/features/shell/file_preview_menu.dart';
import 'package:jarvis_app/src/features/shell/file_preview_view.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
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

const String _text = 'line one\nline two\nline three\n';

class _FixedTarget extends ShellTargetController {
  _FixedTarget(this.initial);

  final ShellTarget? initial;

  @override
  ShellTarget? build() => initial;
}

Widget _harness({String text = _text}) {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(
        () => _FixedTarget(const ProjectTarget(_project)),
      ),
      projectFileContentProvider.overrideWith(
        (ref, key) =>
            FileContent(path: key.path, size: text.length, text: text),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: FilePreviewView(path: '/tmp/hello-demo/a.txt'),
        ),
      ),
    ),
  );
}

/// 右键菜单在桌面才有；macOS 还会先选中落点下的词，因此「复制」一定在列表里。
///
/// 不能用 `addTearDown` 复位 `debugDefaultTargetPlatformOverride`：
/// binding 的兜底断言在 tearDown 之前跑，会判"测试改动了 foundation 调试变量"。
Future<void> _withMacOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 在预览正文上按次要键。菜单"按下即出"，一次 tap 就够。
Future<void> _rightClick(WidgetTester tester, Offset at) async {
  await tester.tapAt(
    at,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('右键预览正文弹出项目统一的菜单，只有平台文本动作', (tester) async {
    await _withMacOS(() async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final spot = tester.getCenter(find.text('line one'));
      await _rightClick(tester, spot);

      expect(find.byKey(kPreviewContextMenuKey), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(
        find.text('复制全部内容'),
        findsNothing,
        reason: '自定义项已去掉，菜单只跟随平台的 contextMenuButtonItems',
      );
      expect(
        find.byType(AgentMenuDivider),
        findsNothing,
        reason: '同一组文本动作之间不插分组线',
      );
      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsNothing,
        reason: '系统工具条必须被 contextMenuBuilder 完全替换',
      );

      // 面板左上角落在右键落点上（与标签右键同一口径），不是浮在屏幕中间。
      final panel = tester.getTopLeft(find.byKey(kPreviewContextMenuKey));
      expect(panel.dx, closeTo(spot.dx, 1));
      expect(panel.dy, closeTo(spot.dy, 1));
    });
  });

  testWidgets('点菜单外收起，之后还能再次右键弹出', (tester) async {
    await _withMacOS(() async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final spot = tester.getCenter(find.text('line one'));
      await _rightClick(tester, spot);
      expect(find.byKey(kPreviewContextMenuKey), findsOneWidget);

      // 落在预览之外：外层 TapRegion 收起菜单。
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      expect(find.byKey(kPreviewContextMenuKey), findsNothing);

      // 关键回归：外层 ContextMenuController 的 OverlayEntry 也必须收干净，
      // 否则下一次右键只会 markNeedsBuild，菜单再也弹不出来。
      await _rightClick(tester, spot);
      expect(find.byKey(kPreviewContextMenuKey), findsOneWidget);
    });
  });

  testWidgets('Esc 收起菜单', (tester) async {
    await _withMacOS(() async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      await _rightClick(tester, tester.getCenter(find.text('line one')));

      expect(find.byKey(kPreviewContextMenuKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(kPreviewContextMenuKey), findsNothing);
    });
  });

  testWidgets('菜单按平台顺序排列：复制在上、全选在下', (tester) async {
    await _withMacOS(() async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      await _rightClick(tester, tester.getCenter(find.text('line one')));

      final copy = tester.getTopLeft(find.text('复制')).dy;
      final selectAll = tester.getTopLeft(find.text('全选')).dy;

      expect(copy, lessThan(selectAll));
    });
  });
}
