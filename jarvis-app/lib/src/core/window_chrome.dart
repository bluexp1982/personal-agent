import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'browser/browser_zoom.dart';

/// macOS 隐藏标题栏后，红绿灯所在标题栏区的高度。
///
/// 原生侧（`macos/Runner/MainFlutterWindow.swift`）用
/// `titlebarAppearsTransparent + fullSizeContentView` 把内容铺到窗口顶端，
/// 标题栏保持系统高度（macOS 26 实测 32pt）：红绿灯在标题栏里垂直居中。
/// 桌面端引擎通常上报安全区为 0（没有刘海），窄屏仍要靠这个值主动让开。
///
/// 注意它**不再是**三栏首行的高度：首行取 `kPaneHeaderHeight`（40，
/// 由右栏标签高度 + 上下留白推导）。红绿灯本身由系统居中在这 32pt 里，
/// 原生侧（`MainFlutterWindow.alignTrafficLights()`）再把三颗按钮整体下移
/// 4pt，按钮中心因此落在首行中线上，与栏头按钮同轴。
/// "双击标题栏缩放"仍然只在这 32pt 内生效，首行多出来的部分只能按住拖动
/// （见 `WindowDragArea`）。它还必须落在空白拖动区：栏头按钮整好也在这条带
/// 里，靠 [TitleBarClickReporter] 逐次排除，连点后退不会缩放窗口。
///
/// 这个数不只是"画得像"：它同时也是 macOS 自己的窗口拖动区
/// （原生按 `frame.height - contentLayoutRect.height` 现算，见
/// `MainFlutterWindow.titleBarBandHeight`）。凡是比它高出来的部分，
/// 都会跟着一起变成"按住就拖窗口 / 双击就缩放"——所以不要再用 titlebar
/// accessory 去把这个区域垫高，那会把它一下翻到 68pt，整条第二行都受牵连。
const double kMacWindowButtonsHeight = 32;

/// 红绿灯在水平方向占掉的宽度。
///
/// 三颗按钮从窗口左边 6dp 起排到约 56dp，再留一段间距才轮到应用自己的控件；
/// 78 是"不打架且不显空"的值：侧栏收起后，开合按钮正好落在红绿灯右侧，
/// 而不是压在它们身上（一条栏头里，两者垂直方向是同一条线）。
const double kMacWindowButtonsWidth = 78;

/// 当前窗口是否"标题栏已隐藏、内容铺满整窗"。
///
/// 只对 macOS 生效：Windows / Linux 没有自绘的窗口按钮，
/// 隐藏原生标题栏会让窗口没法最小化/关闭，那边保持系统标题栏。
bool get usesHiddenWindowTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// 原生窗口通道：隐藏标题栏之后，系统那条可拖动的标题栏没了，
/// 拖动窗口只能由 Flutter 主动向后端发起（与 `window_manager` 的做法一致）。
///
/// 同一个通道还承载"原生窗口全屏"（见下面的 `setNativeFullScreen`）：
/// 三端方法名与参数完全一致，平台差异全部留在原生侧。
const MethodChannel _windowChannel = MethodChannel('personal_agent/window');

/// 当前平台是否实现了原生窗口全屏。
///
/// 桌面三端各有各的做法（macOS 系统全屏空间、Windows 无边框铺满监视器、
/// Linux 交给窗口管理器），移动端与 Web 没有可全屏的窗口，
/// 直接降级成"只切换界面"。
bool get supportsNativeFullScreen =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// 查询窗口当前是否处于原生全屏。
///
/// 返回 `null` 表示"问不到"：非桌面平台、或宿主没有注册通道（单元测试）。
/// 调用方据此决定是"什么都不做"还是"进入前先记下窗口状态"。
Future<bool?> isNativeFullScreen() async {
  if (!supportsNativeFullScreen) {
    return null;
  }
  try {
    return await _windowChannel.invokeMethod<bool>('isFullScreen');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// 让窗口进入 / 退出原生全屏。
///
/// 失败时静默：全屏只是"锦上添花"，拿不到窗口就退化成界面全屏，
/// 不该把异常抛给 UI（与 [startWindowDrag] 同一套处理）。
Future<void> setNativeFullScreen(bool fullScreen) async {
  if (!supportsNativeFullScreen) {
    return;
  }
  try {
    await _windowChannel.invokeMethod<void>('setFullScreen', <String, Object>{
      'fullScreen': fullScreen,
    });
  } on MissingPluginException {
    // 单元测试或未注册通道的宿主。
  } on PlatformException {
    // 原生侧拒绝（过渡动画中等）：界面已经切过去了，下次还会再同步一次。
  }
}

/// 「原生全屏状态变了」的订阅者。
///
/// 通道的 `setMethodCallHandler` 是覆盖语义，只能装一个处理器；这里在它之上
/// 再维护一层订阅表，多个消费者（终端全屏、栏头判断有没有红绿灯）各订各的，
/// 后注册的不会把先注册的顶掉。
final List<void Function(bool fullScreen)> _fullScreenListeners =
    <void Function(bool fullScreen)>[];

/// 浏览器缩放快捷键的订阅者（原生 → Dart）。
final List<void Function(BrowserZoomCommand)> _browserZoomListeners =
    <void Function(BrowserZoomCommand)>[];

/// 通道的 `setMethodCallHandler` 是覆盖语义，只能装一次：
/// 全屏与浏览器缩放共用同一个分发器，谁先订阅谁负责装上。
bool _windowEventHandlerInstalled = false;

void _ensureWindowEventHandler() {
  if (_windowEventHandlerInstalled) {
    return;
  }
  _windowEventHandlerInstalled = true;
  _windowChannel.setMethodCallHandler((MethodCall call) async {
    switch (call.method) {
      case 'fullScreenChanged':
        final arguments = call.arguments;
        if (arguments is Map && arguments['fullScreen'] is bool) {
          final bool fullScreen = arguments['fullScreen'] as bool;
          // 复制一份再遍历：订阅者在回调里读 provider，可能间接改这张表。
          for (final void Function(bool) listener
              in List<void Function(bool)>.of(_fullScreenListeners)) {
            listener(fullScreen);
          }
        }
      case 'browserZoom':
        final arguments = call.arguments;
        if (arguments is Map) {
          final command = BrowserZoomCommand.fromWire(arguments['action']);
          if (command != null) {
            for (final void Function(BrowserZoomCommand) listener
                in List<void Function(BrowserZoomCommand)>.of(
                  _browserZoomListeners,
                )) {
              listener(command);
            }
          }
        }
    }
    return null;
  });
}

/// 订阅"原生侧的全屏状态变了"。
///
/// 必需的方向是 **原生 → Dart**：用户在 macOS 点绿灯 / 按 Ctrl+Cmd+F、
/// 或在 Linux 的窗口管理器里退出全屏时，界面必须跟着退出沉浸模式，
/// 否则会停在"窗口已还原、界面还是满屏终端"的错位状态。
///
/// 订阅只增不减：消费者都是随应用常驻的全局状态（`windowFullScreenProvider`、
/// `immersiveFullscreenProvider`），没有反复注册 / 注销的场景。
void listenNativeFullScreenChanges(void Function(bool fullScreen) onChanged) {
  if (!supportsNativeFullScreen) {
    return;
  }
  _fullScreenListeners.add(onChanged);
  _ensureWindowEventHandler();
}

/// 当前平台是否拉通了"浏览器缩放"的原生快捷键。
///
/// 只有桌面两端有：macOS 在 `AppDelegate` 的本地按键监听里识别，Windows 在
/// Runner 的加速键表里识别，两边都通过 `personal_agent/window` 回传。
/// 移动端没有可接的原生键盘通道，缩放快捷键只在 Flutter 控件聚焦时生效
/// （见 `BrowserZoomShortcutHost` 里的 `CallbackShortcuts`）。
bool get supportsNativeBrowserZoomShortcuts =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// 告诉原生"现在右栏停在一个可缩放的浏览器页上"。
///
/// 原生只在 `active == true` 时才吞 Cmd/Ctrl + `=` / `-` / `0`：
/// 没有活动浏览器标签时，这些组合键必须原样放行，不能把别处（含将来新增的）
/// 语义无声抢走。
Future<void> setBrowserZoomShortcutActive(bool active) async {
  if (!supportsNativeBrowserZoomShortcuts) {
    return;
  }
  try {
    await _windowChannel.invokeMethod<void>(
      'setBrowserZoomContext',
      <String, Object>{'active': active},
    );
  } on MissingPluginException {
    // 单元测试或未注册通道的宿主。
  } on PlatformException {
    // 原生侧没实现（老版本 Runner）：快捷键退化成 Flutter 层兜底。
  }
}

/// 订阅原生发回来的缩放命令。
///
/// 与全屏订阅共用同一个通道处理器。返回退订函数：右栏切标签、收起面板都会
/// 拆掉 host，不退订的话监听表会随着切换次数一直变长，且旧 host 的回调会在
/// `ref` 已失效之后被调用。
VoidCallback? listenBrowserZoomShortcuts(
  void Function(BrowserZoomCommand) onCommand,
) {
  if (!supportsNativeBrowserZoomShortcuts) {
    return null;
  }
  _browserZoomListeners.add(onCommand);
  _ensureWindowEventHandler();
  return () => _browserZoomListeners.remove(onCommand);
}

/// 最近这一次指针按下是否落在 [WindowDragArea] 上。
///
/// 由 [startWindowDrag] 写下、由 [TitleBarClickReporter] 读走并复位：
/// 原生靠它区分"按的是标题栏空白"和"按的是栏头按钮"。
bool _pointerStartedWindowDrag = false;

/// 让原生窗口跟随当前鼠标事件开始拖动。
///
/// 必须在指针按下时调用：原生侧拿到的是 `NSApp.currentEvent`，
/// 一旦松手就没有可用的拖动事件了。
Future<void> startWindowDrag() async {
  if (!usesHiddenWindowTitleBar) {
    return;
  }
  // 先记下"这一次按下落在空白区"，根部报告器随后把它交给原生。
  _pointerStartedWindowDrag = true;
  try {
    await _windowChannel.invokeMethod<void>('startDragging');
  } on MissingPluginException {
    // 单元测试或未注册通道的宿主：没有窗口可拖，忽略。
  } on PlatformException {
    // 原生侧拒绝拖动（事件已不是按下状态）：同样不该把异常抛给 UI。
  }
}

/// 把每一次指针按下"是不是落在标题栏空白区"报给原生。
///
/// macOS 那条「双击标题栏以缩放窗口」的识别器挂在 Flutter 视图上，只按
/// "点击是否在顶部 32pt 带内"判断；而左栏栏头、中栏栏头、右栏标签条整条
/// 都在这条带里——在后退按钮上连点两下（退两页的常规操作），第二下就会被
/// AppKit 当成双击标题栏，窗口跟着缩放。
///
/// 这里逐次上报"这次按下有没有开始拖窗口"，原生只在两次点击都落在空白区时
/// 才认双击，栏头按钮上的连点不再牵动窗口。
///
/// 必须挂在界面**根部**：Flutter 的指针事件从最深处的控件往外派发，
/// 挂在外层才读得到 [WindowDragArea] 刚写下的标记。
class TitleBarClickReporter extends StatelessWidget {
  const TitleBarClickReporter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!usesHiddenWindowTitleBar) {
      return child;
    }
    return Listener(
      // translucent：没有子控件命中的空白处也要报。漏报会让原生拿上一次的
      // 标记去判断这一次点击，双击缩放就会时灵时不灵。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _reportTitleBarClick(),
      child: child,
    );
  }
}

/// 读走并复位标记，再把这一次点击的性质交给原生。
Future<void> _reportTitleBarClick() async {
  final startedDrag = _pointerStartedWindowDrag;
  _pointerStartedWindowDrag = false;
  try {
    await _windowChannel.invokeMethod<void>('titleBarClick', <String, Object>{
      'startedDrag': startedDrag,
    });
  } on MissingPluginException {
    // 单元测试或没有原生窗口的宿主。
  } on PlatformException {
    // 原生侧没装处理器：不影响界面。
  }
}

/// 一块"按住就能拖窗口"的空白区。
///
/// 隐藏标题栏后窗口没有系统可拖区域（那条原生标题栏已经不在了），
/// 只有把标题栏里的留白包上它，用户才能在栏上拖动窗口。
/// 非 macOS 原样返回 child：那边系统标题栏还在，既不需要也不该拦截指针。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!usesHiddenWindowTitleBar) {
      return child;
    }
    return Listener(
      // opaque：空白区本身没有内容可命中，不设这个连按下事件都收不到。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => startWindowDrag(),
      child: child,
    );
  }
}

/// 把红绿灯区域补进 `MediaQuery.padding.top`。
///
/// 这样所有 `SafeArea` 与 `AppBar`（它按 `padding.top` 加顶部内边距）
/// 都自动让开，不必逐个页面改。
/// 引擎若已经上报了安全区（部分版本会算上标题栏），取较大值即可，
/// 不会叠成两倍留白。
class HiddenWindowTitleBarInset extends StatelessWidget {
  const HiddenWindowTitleBarInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!usesHiddenWindowTitleBar) {
      return child;
    }

    final media = MediaQuery.of(context);
    if (media.padding.top >= kMacWindowButtonsHeight) {
      return child;
    }

    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(top: kMacWindowButtonsHeight),
        viewPadding: media.viewPadding.copyWith(
          top: math.max(media.viewPadding.top, kMacWindowButtonsHeight),
        ),
      ),
      child: child,
    );
  }
}
