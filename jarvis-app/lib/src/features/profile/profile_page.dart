import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/session.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../canvas/canvas_navigation.dart';
import '../memory/memory_navigation.dart';
import '../settings/settings_navigation.dart';
import '../settings/settings_widgets.dart';

/// 窄屏「我的」：账户、工具入口与设置。
///
/// 原来「我的」标签直接就是设置页；设置改成「我的」的下级整页之后，这一层
/// 才放得下账户身份与两个工具入口。样式与设置一级列表同一套（分组标题 +
/// 卡片 + 行），两条列表看起来才是同一个家族。
class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.session,
    this.bottomInset = 0,
    this.topInset = 0,
  });

  final SessionState session;

  /// 页面底部到窗口底的距离。
  ///
  /// 当一级标签用时压着一条悬浮导航，列表最后一项要能滚到胶囊上方；被推入时
  /// 由调用方补系统安全区即可。
  final double bottomInset;

  /// 顶部额外留白：body 铺到页头之后（`frostTop`），首项要往下让出这一段。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return AppPageScaffold(
      frostTop: topInset > 0,
      appBar: const MobileAppBar(title: '我的'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16 + topInset, 16, 16 + bottomInset),
        children: <Widget>[
          // 账户身份：只显示名字与一句说明，还没有可点的账户设置。
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.accent.projectTint,
                    ),
                    child: Center(
                      child: Text(
                        kAccountDisplayName.substring(0, 1).toUpperCase(),
                        style: TextStyle(
                          fontSize: AppFontSize.lg,
                          height: AppLineHeight.tight,
                          fontWeight: AppWeight.semiBold,
                          color: palette.accent.projectStart,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          kAccountDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.row.copyWith(
                            fontWeight: AppWeight.medium,
                            color: palette.text.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text('本机账户', style: text.hint),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('工具', style: text.section),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: <Widget>[
                SettingsRow(
                  icon: Icons.psychology_outlined,
                  title: '记忆',
                  description: '画像、事件与授权；对话时会自动带上一份摘要',
                  onTap: () => openMemoryPage(context),
                ),
                const Divider(height: 1),
                SettingsRow(
                  icon: Icons.hub_outlined,
                  title: '无限画布',
                  description: '节点与连线的演示画布，用来试手势与布局',
                  onTap: () => openCanvasDemoPage(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 分组标题不能也叫「设置」：行标题已经占用了这个词，
          // 两处同名时点哪一个是歧义，读屏也会念成两句一样的。
          Text('更多', style: text.section),
          const SizedBox(height: 8),
          Card(
            child: SettingsRow(
              icon: Icons.settings_outlined,
              title: '设置',
              description: '连接与设备、外观、能力、录音与关于',
              onTap: () => openSettingsPage(context, session: session),
            ),
          ),
        ],
      ),
    );
  }
}
