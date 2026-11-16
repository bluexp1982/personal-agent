import 'package:flutter/material.dart';

import '../design/app_palette.dart';
import '../design/app_surface.dart';
import 'shell_insets.dart';
import 'top_bar_fade.dart';

/// 整页 `Scaffold`：把“这一屏的渐变底该画在哪一层”收成一条契约。
///
/// 规则只有三条：
/// - `backgroundColor` 非空：宽屏内嵌的栏底（`paneSurfaceColor`）、全屏黑底、
///   附件预览这类有意指定的实色底——原样返回一个普通 [Scaffold]，
///   像素与手写完全一致。
/// - `backgroundColor` 为空（= 窄屏整页形态）且祖先没有 [PageBackdropScope]：
///   这是 push 上来的整页路由，自己在 [Scaffold] 外面垫一层整窗渐变，
///   并把 Scaffold 置透明。渐变位于这条路由的子树内，随它一起滑入滑出，
///   且首段已预乘为不透明色，转场期间不会透出下层列表。
/// - `backgroundColor` 为空且祖先有 [PageBackdropScope]：骨架（`HomeShell`）
///   已经在整窗画了渐变，这里只把 Scaffold 置透明。同一屏画两层渐变不只是
///   白费，还会因为起点不同（骨架在安全区之上、页面在安全区之下）在顶部
///   多出一条极淡的横向色带。
///
/// 所以换页时通常只改类名与 import，不重排 `body`、不动布局。
class AppPageScaffold extends StatelessWidget {
  const AppPageScaffold({
    super.key,
    this.appBar,
    this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
    this.extendBodyBehindAppBar = false,
    this.frostTop = false,
  });

  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;
  final bool extendBodyBehindAppBar;

  /// 让 body 铺到 appBar 之后，页头那层虚化带才有内容可糊。
  ///
  /// 只给"窄屏一级标签页"开：它们的内容要能从页头底下滚过。首个内容项的
  /// 顶部留白由页面自己加在滚动内容里（`padding.top`），不是在这里加——加在
  /// body 外层只会把视口推下去，内容仍然滚不到页头下面。
  final bool frostTop;

  /// 把 body 包进 `Stack`，在其上叠一条顶部虚化带。
  ///
  /// 层级必须是「body 在下、虚化带在中、appBar 在上」：`Scaffold` 先画 body
  /// 再画 appBar，所以虚化带放在 body 里正好位于页头之下、内容之上——它只糊
  /// 身后的滚动内容，标题与按钮不受影响。
  Widget? _frostedBody(BuildContext context) {
    final content = body;
    if (!frostTop || content == null) return content;

    // 带子贴在 body 顶边：骨架内的页面已经在 `SafeArea` 之后，body 顶边就是
    // 内容区顶边，偏移为 0；push 上来的整页（无 `PageBackdropScope`）body 顶边
    // 就是窗口顶边，页头自己还按 `padding.top` 往下挪了一段——带子不跟着下移，
    // 就会压在状态栏上、把页头下半截露在光板上。
    final shellHosted = PageBackdropScope.of(context);
    final topOffset = shellHosted ? 0.0 : MediaQuery.paddingOf(context).top;

    // 填充色要按「带子上沿在整窗里的位置」取：骨架内 `SafeArea` 把 padding
    // 清零了，只能读骨架挂下来的那个值；push 上来的整页正是上面那份偏移。
    // 取错会让带子上沿与背景差出几个亮度，留下一条细横线。
    final windowTop = shellHosted ? ShellInsets.topOf(context) : topOffset;

    return Stack(
      children: <Widget>[
        Positioned.fill(child: content),
        Positioned(
          top: topOffset,
          left: 0,
          right: 0,
          child: TopBarFade(topInset: windowTop),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = backgroundColor;

    if (color != null) {
      return Scaffold(
        appBar: appBar,
        body: _frostedBody(context),
        backgroundColor: color,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: bottomNavigationBar,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        extendBodyBehindAppBar: extendBodyBehindAppBar || frostTop,
      );
    }

    final scaffold = Scaffold(
      appBar: appBar,
      body: _frostedBody(context),
      backgroundColor: Colors.transparent,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBodyBehindAppBar: extendBodyBehindAppBar || frostTop,
    );

    if (PageBackdropScope.of(context)) {
      return scaffold;
    }

    // 渐变铺在最外层：Scaffold 透明之后，`appBar`、`body`、底部栏都浮在它上面。
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: appSurfaceGradient(
          AppPalette.of(context),
          Theme.of(context).colorScheme,
        ),
      ),
      child: scaffold,
    );
  }
}

/// 标记“祖先已经铺好整窗渐变”。
///
/// 只回答一个问题：这一屏还需不需要页面自己铺底。用一次性查询而不是
/// `dependOnInheritedWidgetOfExactType`：标记一旦存在就不会变，
/// 不需要让页面跟着祖先重建。
class PageBackdropScope extends InheritedWidget {
  const PageBackdropScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PageBackdropScope>() != null;

  @override
  bool updateShouldNotify(PageBackdropScope oldWidget) => false;
}
