import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';

/// 芯片文字的最大宽度。再长就省略：一枚芯片不该占满整行。
///
/// 附件与路径引用共用同一个值，并排放着时宽度才对得上。
const double kComposerChipLabelMaxWidth = 180;

/// 输入框内嵌标签的公共外壳：技能标签与附件芯片共用同一套外观。
///
/// 抽出来的理由不是"少写几行"：两处各写一份之后，底色、描边、圆角、图标尺寸、
/// X 的命中区会各自漂移，同一行里并排放着就会看出两代控件。
/// 这里只负责"一枚胶囊长什么样"，内容（图标 / 缩略图 / 文字）由调用方给。
class ComposerChipFrame extends StatefulWidget {
  const ComposerChipFrame({
    super.key,
    required this.label,
    required this.tooltip,
    this.leading,
    this.onRemove,
    this.error = false,
    this.busy = false,
  });

  /// 标签文字。过长由调用方自己省略——这里不替它决定截断策略。
  final Widget label;

  final String tooltip;

  /// 左侧装饰：图标、缩略图或转圈。为空时只有文字与删除按钮。
  final Widget? leading;

  /// 删除动作。为 null 时不画 X（气泡里的只读芯片用这种形态）。
  final VoidCallback? onRemove;

  /// 出错态：底色与描边换成状态红，提示"这一枚没上传成功"。
  final bool error;

  /// 还在处理中：X 位置换成一个小转圈，挡住重复点击。
  final bool busy;

  @override
  State<ComposerChipFrame> createState() => _ComposerChipFrameState();
}

class _ComposerChipFrameState extends State<ComposerChipFrame> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final status = palette.status;

    final background = widget.error
        ? status.surfaceOf(status.danger)
        : scheme.surfaceContainerHighest.withValues(
            alpha: _hovering ? 0.9 : 0.6,
          );
    final border = widget.error
        ? status.borderOf(status.danger)
        : scheme.outlineVariant.withValues(alpha: 0.6);

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.fromLTRB(6, 1, 2, 1),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.leading != null) ...<Widget>[
                widget.leading!,
                const SizedBox(width: 4),
              ],
              widget.label,
              if (widget.onRemove != null) ...<Widget>[
                const SizedBox(width: 2),
                // 命中区 16 而图标 10：太小点不中，太大会把标签撑高。
                SizedBox(
                  width: 16,
                  height: 16,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onRemove,
                      child: widget.busy
                          ? const Center(
                              child: SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(strokeWidth: 1.2),
                              ),
                            )
                          : Icon(
                              Icons.close,
                              size: 10,
                              color: _hovering
                                  ? palette.text.secondary
                                  : palette.text.tertiary,
                            ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 芯片里的文字样式。字号与行高与正文同源，标签才跟文字一样高。
TextStyle chipLabelStyle(BuildContext context, {Color? color}) {
  return TextStyle(
    fontSize: AppFontSize.base,
    height: AppLineHeight.tight,
    color: color ?? AppPalette.of(context).text.primary,
    // 名字不换行：标签折成两行会撑高输入框。
    leadingDistribution: TextLeadingDistribution.even,
  );
}
