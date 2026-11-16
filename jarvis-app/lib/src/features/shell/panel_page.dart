import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_page_scaffold.dart';
import 'file_pane_state.dart';
import 'panel_fullscreen.dart';
import 'immersive_fullscreen.dart';
import 'project_panel.dart';

/// 窄屏的整页面板：把右侧栏原样铺成一页。
///
/// 宽屏的右栏是"浮在中栏右侧的一栏"，窄屏没有第三栏可用；但面板里的能力
/// （文件浏览、终端）与窗口宽度无关，缺的只是空间。于是窄屏把同一个
/// [ProjectPanel] 以整页形式推上来，`standalone: true` 让它把
/// "隐藏右侧栏"换成"返回"，也不再显示栏内全屏按钮。
class PanelPage extends ConsumerWidget {
  const PanelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 与主界面同一套渐变（`appSurfaceGradient`）：从面板返回时不会有
    // 一瞬间的底色跳变。整页面板是独立路由，由 `AppPageScaffold` 自己铺底。
    return AppPageScaffold(
      body: SafeArea(
        bottom: false,
        // 整页从窗口左缘开始，标题条上的红绿灯照样在：第一个标签要让它。
        child: const ProjectPanel(standalone: true, flushLeft: true),
      ),
    );
  }
}

/// 打开整页面板。入口只在窄屏顶栏，宽屏用右栏开合按钮。
Future<void> openPanelPage(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);

  // 先把可能残留的宽屏全屏状态清掉：整页本身就占满屏幕，
  // 带着全屏标记回到宽屏会看到一个没有中间区的界面。
  //
  // 终端全屏同样要退：它会把窗口推进原生全屏，而整页形态是"另一个页面"，
  // 带着它推上来只会得到一屏没有红绿灯、也没有返回按钮的终端。
  container.read(panelFullscreenProvider.notifier).exit();
  container.read(immersiveFullscreenProvider.notifier).exit();

  // 标签被关光时整页会是一片空白：进来之前先补一张空白页，
  // 与宽屏「显示右侧栏」的处理保持一致（那条路径走 `show()`）。
  container.read(filePaneTabProvider.notifier).ensureTabPage();

  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const PanelPage()));
}
