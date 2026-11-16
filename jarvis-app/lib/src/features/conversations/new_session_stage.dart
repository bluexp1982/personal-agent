import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';

/// 新会话空态的标语。
///
/// 只留文字、不配图标：空会话页要的是干净的一个视觉重心，
/// 图标反而会把注意力从输入栏上分走。标语放常量，换文案只改一行。
///
/// 会话页与「聊天」空态页共用：两处出现同一个开场，文案分叉会立刻显得像两个应用。
class NewSessionBrand extends StatelessWidget {
  const NewSessionBrand({super.key});

  /// 空会话的标语。
  static const String label = '探索未来';

  /// 品牌行的固定行高。
  ///
  /// 舞台要按它算"输入栏下方补多高"，才能让输入栏自己落在中线上；
  /// 让它随字体度量走的话，这个补偿值会在不同平台上差几像素。
  /// 44 = 36 磅文字按 [AppLineHeight.tight]（43.2）向上取到 4 的倍数。
  static const double lineHeight = 44;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: lineHeight,
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: AppFontSize.displayXl,
            // 行高压到 1.2：36 磅跟着 titleLarge 的 1.27 走，行盒会到 45.7，
            // 和上下两块留白的比例就散了。
            height: AppLineHeight.tight,
            fontWeight: AppWeight.semiBold,
            letterSpacing: AppLetterSpacing.tight,
            color: AppPalette.of(context).text.primary,
          ),
        ),
      ),
    );
  }
}

/// 新会话的居中舞台：输入栏居中，品牌行叠加在它上方。
///
/// **水平垂直居中的是输入栏本身**：把「品牌行 + 间距 + 输入栏」当一个整体居中，
/// 输入栏就会落到中线以下半块品牌行的高度——空会话页第一眼看上去像「输入栏偏低」，
/// 而不是「开场在正中」。所以下面留一块与上方品牌区等高的占位，把它顶回来；
/// 品牌行于是只影响上方留白，不参与输入栏的定位。
///
/// 中线是**整个窗口**的中线，不是栏头以下那一块的中线：舞台自己只占栏头以下，
/// 所以要按 [chromeAbove] 把内容再往上提半个栏头高，否则输入栏会比窗口中线低 20dp。
///
/// 也因此，居中舞台必须用不带垂直内边距的输入栏外框（见 `ChatComposerArea.padding`）：
/// 外框自己的 8 / 12 上下边距不对称，会让面板整体偏上 2dp，品牌行到面板的间距
/// 也会变成「间距 + 8」而不是这里写的值。
///
/// 用 `minHeight` 撑满再 `Center`，而不是直接 `Center`：窗口很矮、输入框
/// 长到 6 行时内容会高过视口，撑满的滚动容器还能滚，裸 `Center` 会被裁掉。
///
/// 输入区由调用方构造成 [composer] 传进来：它的状态（controller / 发送态 /
/// 权限选择）属于页面，舞台只负责摆位。
class NewSessionStage extends StatelessWidget {
  const NewSessionStage({
    super.key,
    required this.composer,
    this.chromeAbove = 0,
  });

  /// 品牌行底边到输入栏顶边的间距。
  static const double brandGap = 24;

  /// 已经拼好的输入区（通常是 `ChatComposerArea`）。
  final Widget composer;

  /// 舞台上方那条栏头的高度（`EmbeddedToolbar` / `AppBar`），以窗口高度为中线时扣除。
  ///
  /// 浮窗传 0：它悬在窗口中间，自身就是一个小窗，减去整窗的栏头只会把内容顶出框。
  final double chromeAbove;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            // 底部留一条栏头高的空边：居中盒整体上移半个栏头，输入栏才落在整窗中线上。
            child: Padding(
              padding: EdgeInsets.only(bottom: chromeAbove),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const NewSessionBrand(),
                  const SizedBox(height: brandGap),
                  composer,
                  // 让输入栏自己落在中线上：下方补一块与上方品牌区等高的空白。
                  const SizedBox(height: NewSessionBrand.lineHeight + brandGap),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
