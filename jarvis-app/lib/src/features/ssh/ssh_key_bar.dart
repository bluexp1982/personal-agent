import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';

/// 移动端终端辅助按键条。
///
/// 软键盘上没有 Esc / Ctrl / 方向键，而这几颗键恰恰是 shell 里最常用的
/// （打断进程、补全、翻历史）。这里直接走 `Terminal.keyInput`，与硬件键盘
/// 产生同一套转义序列，不自己拼 `\x1b[A` 之类的字节。
class SshKeyBar extends StatelessWidget {
  const SshKeyBar({super.key, required this.terminal, required this.tint});

  final Terminal terminal;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).terminal;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(top: BorderSide(color: palette.chromeBorder)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            _KeyCap(
              label: 'Esc',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.escape),
            ),
            _KeyCap(
              label: 'Tab',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.tab),
            ),
            _KeyCap(
              label: 'Ctrl-C',
              tint: tint,
              onTap: () => terminal.charInput(0x63, ctrl: true),
            ),
            _KeyCap(
              label: 'Ctrl-D',
              tint: tint,
              onTap: () => terminal.charInput(0x64, ctrl: true),
            ),
            _KeyCap(
              label: '←',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.arrowLeft),
            ),
            _KeyCap(
              label: '↑',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.arrowUp),
            ),
            _KeyCap(
              label: '↓',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.arrowDown),
            ),
            _KeyCap(
              label: '→',
              tint: tint,
              onTap: () => terminal.keyInput(TerminalKey.arrowRight),
            ),
            _KeyCap(
              label: '粘贴',
              icon: Icons.content_paste_rounded,
              tint: tint,
              onTap: () => _paste(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    terminal.paste(text);
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.label,
    required this.tint,
    required this.onTap,
    this.icon,
  });

  final String label;
  final Color tint;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // 键帽底色仍用模式色（青绿）打底，文字/图标取终端正文色：
    // 浅色终端上白字会直接糊掉，深色上黑字同样看不见。
    final foreground = AppPalette.of(context).terminal.theme.foreground;

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 14, color: foreground),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: AppFontSize.base,
                    fontWeight: AppWeight.semiBold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
