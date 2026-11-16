import 'package:flutter/material.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import 'canvas_node_data.dart';

/// 画布上一张卡片的内容。
///
/// 只画"卡片里写什么"：底色、描边、圆角、选中态都由 `NodeWidget` 按
/// `canvasThemeOf` 里的 `NodeTheme` 画，这里再画一遍就等于两套主题并存。
///
/// 分组框（`GroupNode`）与便签（`CommentNode`）不经过这里：它们是库里的
/// **自渲染节点**，`buildWidget` 直接返回自己的标题带 / 便签底，`nodeBuilder`
/// 的返回值会被丢掉。它们的外观只能通过构造时的 `color` 与 `NodeTheme` 控制，
/// 见 `canvas_demo_graph.dart` 与 `canvas_theme.dart`。
class CanvasNodeCard extends StatelessWidget {
  const CanvasNodeCard({super.key, required this.node});

  /// 节点数据是可空的：分组框与便签不携带业务数据，但同样会走到这里。
  final Node<CanvasNodeData?> node;

  @override
  Widget build(BuildContext context) {
    final data = node.data;
    if (data == null) {
      // 自渲染节点（分组 / 便签）走这条：内容由库自己画，这里给零尺寸占位，
      // 免得白白 layout 一遍。
      return const SizedBox.shrink();
    }

    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              // 类型色点：8dp 的小圆，一眼分出"触发 / 处理 / 分支 / 输出"。
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _accentOf(context, data),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.row.copyWith(fontWeight: AppWeight.medium),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            data.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppFontSize.xs,
              height: AppLineHeight.normal,
              color: palette.text.tertiary,
            ),
          ),
        ],
      ),
    );
  }

  /// 节点类型色。
  ///
  /// 借用状态色而不是另造四档 accent：它们本来就有明暗两套且过了对比度红线，
  /// 画布上只是"这一格是哪种节点"的标记，不承载成功 / 警告的语义。
  Color _accentOf(BuildContext context, CanvasNodeData data) {
    final palette = AppPalette.of(context);
    return switch (data) {
      TriggerNodeData() => palette.status.success,
      AgentNodeData() => Theme.of(context).colorScheme.primary,
      BranchNodeData() => palette.status.warning,
      OutputNodeData() => palette.status.info,
    };
  }
}
