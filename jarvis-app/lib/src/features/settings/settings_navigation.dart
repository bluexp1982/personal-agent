import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'settings_page.dart';

/// 窄屏推入设置的一级分类列表。
///
/// 只有窄屏走这里（宽屏是 `showSettingsDialog` 的浮层）；整页推入之后
/// 底部导航被盖住，返回才回到「我的」。
Future<void> openSettingsPage(
  BuildContext context, {
  required SessionState session,
}) {
  // 在推入之前读安全区：builder 执行时外层 context 可能已经处于失活路径上。
  final bottomSafe = MediaQuery.paddingOf(context).bottom;

  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        session: session,
        // body 铺到页头之后，首项要往下让出页头高度；底部补系统安全区。
        //
        // 这里只给工具条那 54：状态栏高度**不在这里读**——本函数跑在骨架的
        // `SafeArea` 里，`padding.top` 已被清零，读出来恒为 0。push 上去的整页
        // 由 `SettingsPage` 自己在 build 里按路由内的 `MediaQuery` 补。
        topInset: kMobileTopBarMinHeight,
        bottomInset: bottomSafe,
      ),
    ),
  );
}
