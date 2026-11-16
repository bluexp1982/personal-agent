import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/design/terminal_palette.dart';

/// 终端面板：等宽字体 + 选中复制 / 粘贴。
///
/// 配色跟着应用明暗走（见 [TerminalPalette]）：浅色界面里是近白底深字，
/// 深色界面保持原来那套暗色。这里不再写死任何底色。
///
/// 复制 / 粘贴按钮不画在这里，而是挂到状态栏上（见 `ssh_page.dart`）：
/// 悬浮在终端右上角会盖住输出，且和同一栏的其它动作不是一套规格。
/// 那两条动作要用到选区与焦点，所以控制器和焦点可以从外面传进来；
/// 不传时本组件自己建一份（测试与其它宿主不用关心）。
///
/// 断开时不清空输出：用户很可能正要抄最后一段报错，盖一层遮罩比整屏清空有用。
class SshTerminalView extends StatefulWidget {
  const SshTerminalView({
    super.key,
    required this.terminal,
    this.controller,
    this.focusNode,
    this.disconnected = false,
    this.reconnecting = false,
    this.onReconnect,
    this.onExitFullscreen,
  });

  final Terminal terminal;

  /// 选区控制器。外部要做「复制选中」时必须由它持有，才能拿到选区。
  final TerminalController? controller;

  /// 输入焦点。外部「粘贴」后要还焦点给终端，所以也允许外部持有。
  final FocusNode? focusNode;

  /// 已经断开：盖遮罩并提供重连入口。
  final bool disconnected;

  /// 正在重连：盖一层"重连中"遮罩，不给按钮——上一次点击已经在办了，
  /// 再给一个能点的东西只会让人连点。
  final bool reconnecting;
  final VoidCallback? onReconnect;

  /// 仅在某种全屏生效时非空（终端全屏、旧的面板全屏都走这里）：
  /// 此时 Esc 用于退出全屏而不是发给远端。
  ///
  /// 非全屏时必须传 null：vim / less / tmux 收到的 Esc 要与以前完全一致。
  final VoidCallback? onExitFullscreen;

  @override
  State<SshTerminalView> createState() => _SshTerminalViewState();
}

class _SshTerminalViewState extends State<SshTerminalView> {
  late final TerminalController _controller =
      widget.controller ?? TerminalController();
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();

  @override
  void dispose() {
    // 谁创建谁释放：外部传进来的由外部负责。
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;

    return DecoratedBox(
      decoration: BoxDecoration(color: palette.background),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            // 顶部这条 32dp 是给 macOS 红绿灯留的（见 `window_chrome.dart` 的
            // `HiddenWindowTitleBarInset`，它把 `MediaQuery.padding.top` 补成 32）。
            // xterm 会把 `MediaQuery.padding` 当成"被系统 UI 遮住的安全区"：
            // 一边把绘制整体下推 `padding.top`，一边从行数里扣掉它——于是终端
            // 顶边空出一条黑带，内容还少了一两行。
            //
            // 终端在面板内部，上面已经有标签栏和状态栏，离窗口顶端远得很，
            // 不需要这份安全区，这里显式清掉。
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: TerminalView(
                widget.terminal,
                controller: _controller,
                theme: palette.theme,
                // 终端字符是等宽正文里唯一"不能被 0.5px 影响行数计算"的地方：
                // 字号取自 token，但行高比 UI 的 1.2 松，且中文需 CJK fallback。
                textStyle: const TerminalStyle(
                  fontSize: AppFontSize.md,
                  height: AppLineHeight.terminal,
                  fontFamily: AppMono.family,
                  fontFamilyFallback: <String>[
                    'SF Mono',
                    'PingFang SC',
                    'Noto Sans Mono CJK SC',
                    'monospace',
                  ],
                ),
                // 左右 12、上下 10：字形四周有呼吸位，首行不顶状态栏，
                // 最后一列也不会贴到右边缘。
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                focusNode: _focusNode,
                autofocus: true,
                keyboardAppearance: palette.keyboardAppearance,
                // 移动端输入法的退格经常不产生硬件删除事件，这个补偿开关就是为此存在的。
                deleteDetection: true,
                backgroundOpacity: 1,
                onKeyEvent: _handleKeyEvent,
              ),
            ),
          ),
          if (widget.disconnected)
            Positioned.fill(
              child: _DisconnectedOverlay(onReconnect: widget.onReconnect),
            )
          else if (widget.reconnecting)
            const Positioned.fill(child: _ReconnectingOverlay()),
        ],
      ),
    );
  }

  /// xterm 的 `TerminalView` 会先问这里、再决定是否把按键发给远端。
  ///
  /// 只在全屏且是单纯的 Esc 按下时拦截；其余情况返回 `ignored` 交回终端，
  /// 这样非全屏时 vim / less / tmux 收到的 Esc 与以前完全一致。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final onExit = widget.onExitFullscreen;
    if (onExit != null &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      onExit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _DisconnectedOverlay extends StatelessWidget {
  const _DisconnectedOverlay({this.onReconnect});

  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;

    return ColoredBox(
      color: palette.overlay,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.link_off_rounded,
              size: 30,
              color: palette.chromeForeground,
            ),
            const SizedBox(height: 10),
            Text(
              '连接已断开',
              style: TextStyle(
                color: palette.theme.foreground,
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.semiBold,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onReconnect,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新连接'),
              style: FilledButton.styleFrom(
                // 终端自己的青绿身份色：与模式三色同源，不再单独写一遍十六进制。
                backgroundColor: AppPalette.of(context).accent.sshStart,
                foregroundColor: AppPalette.of(context).text.onAccent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 重连中：与断线遮罩同一套视觉，但没有按钮。
///
/// 终端内容留在下面（半透明遮罩）：用户刚在看的东西不该因为点了一次重连就消失。
class _ReconnectingOverlay extends StatelessWidget {
  const _ReconnectingOverlay();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;

    return ColoredBox(
      color: palette.overlay,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.chromeForeground,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '正在重连…',
              style: TextStyle(
                color: palette.theme.foreground,
                fontSize: AppFontSize.md,
                fontWeight: AppWeight.semiBold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
