import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'narrow_tab_icons.dart';

/// 空态的 Key：这段文案以后会随功能落地改写，测试锚在这里而不是文字上。
const Key kMessagesEmptyKey = Key('narrow-messages-empty');

/// 「消息」标签：跨项目会话聚合。
///
/// 手机端原型里这一页标注「未实现」，客户端也还没有聚合接口（现在会话按项目
/// 分组）。这里先给一个明确的空态，而不是留一张白页：用户点进来要能看懂
/// "这里将来放什么、现在为什么是空的"。
class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key, this.bottomInset = 0, this.topInset = 0});

  /// 底部为悬浮导航留出的高度。空态整体上移同样多，视觉重心才不会被胶囊压低。
  final double bottomInset;

  /// 顶部为页头留出的高度。空态整体下移同样多，才落在页头以下的可见区正中。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = palette.accent;
    final text = AppText.of(context);

    // 一级标签页：渐变由骨架铺好（`PageBackdropScope`），这里只需透明底。
    return AppPageScaffold(
      // 窄屏一级标签：body 铺到页头之后，页头那层虚化带才有内容可糊。
      frostTop: topInset > 0,
      // 一级标签页，没有可返回的上一页；动作区留给将来的「搜索 | 更多」胶囊。
      appBar: MobileAppBar(
        title: '消息',
        showBack: false,
      ),
      body: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(32, 24 + topInset, 32, 24 + bottomInset),
          child: Column(
            key: kMessagesEmptyKey,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: accent.projectTint.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Center(
                  child: NarrowTabIcon(
                    glyph: NarrowGlyph.messages,
                    color: accent.projectStart,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('跨项目会话聚合', style: text.cardTitle),
              const SizedBox(height: 8),
              Text(
                '各个项目的会话会汇总到这一页，按最近活跃排序。',
                textAlign: TextAlign.center,
                style: text.hint,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.projectTint.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  '即将上线',
                  style: text.badge.copyWith(color: palette.text.secondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
