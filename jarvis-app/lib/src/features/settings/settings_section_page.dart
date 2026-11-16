import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'settings_sections.dart';

/// 窄屏的二级设置页：一栏内容整页铺开，页头是「返回 + 该栏标题」。
///
/// 只有「我的 → 设置 → 某一栏」这条路径用它：宽屏是弹窗，没有整页形态。
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({
    super.key,
    required this.session,
    required this.section,
  });

  final SessionState session;
  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    // body 铺到页头之后（`frostTop`），首项要往下让出页头高度，滚起来才有
    // 内容从页头底下经过；底部补系统安全区，最后一项才不会被 Home 指示条压住。
    //
    // 顶部要让出的是「状态栏 + 页头」：这一页是 push 上来的整页，body 顶边即
    // 窗口顶边，而页头自己按 `padding.top` 下推——只让出 54 的话，卡片首行会
    // 直接躺在页头标题上。
    final media = MediaQuery.paddingOf(context);
    final topSafe = media.top;
    final bottomSafe = media.bottom;

    return AppPageScaffold(
      frostTop: true,
      appBar: MobileAppBar(
        title: section.title,
        showBack: Navigator.of(context).canPop(),
      ),
      body: SettingsSectionView(
        session: session,
        section: section,
        padding: EdgeInsets.fromLTRB(
          16,
          16 + kMobileTopBarMinHeight + topSafe,
          16,
          16 + bottomSafe,
        ),
      ),
    );
  }
}

/// 推入某一栏的整页。窄屏设置列表、以及栏内跳转的返回落点都走这里。
Future<void> openSettingsSectionPage(
  BuildContext context, {
  required SessionState session,
  required SettingsSection section,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SettingsSectionPage(session: session, section: section),
    ),
  );
}
