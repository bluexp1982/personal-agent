import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/ui/agent_menu.dart';

/// 环形直径与线宽。参考图里它和相邻的圆形图标按钮同一量级。
const double _ringSize = 20;
const double _ringStroke = 2;

/// 悬停 / 长按的命中盒：比环本身大一圈，细环才点得准。
const double _hitSize = 26;

/// 进度过渡时长。
///
/// 只在"这一轮刚结束、用量从旧值跳到新值"时看得出来。太长会让数字变化
/// 显得迟滞，太短又像闪一下；200ms 与全站其余微交互同一档。
const Duration _ringTransition = Duration(milliseconds: 200);

/// 悬停提示文案：`16.8% · 168.0K / 1000.0K 上下文已使用`。
///
/// 独立成纯函数是为了能直接单测口径：百分比一位小数并夹在 0~100，
/// token 数按参考产品用大写 `K`（1M 显示成 `1000.0K`，与实际窗口对齐）。
///
/// [compactedMessages] 大于 0 时补一句"更早 N 条已压缩"：占比数字会因为
/// 摘要而变小，不解释一句的话，用户会以为历史凭空少了一截。
///
/// [canOpenSummary] 为 true 时再补一句"点击查看摘要"：能点才提示能点，
/// 否则在没有摘要的会话里会教用户去点一个没有反应的环。
String formatContextTooltip({
  required int contextTokens,
  required int contextWindow,
  int compactedMessages = 0,
  bool canOpenSummary = false,
}) {
  if (contextWindow <= 0) {
    return '模型上下文窗口未配置';
  }
  if (contextTokens <= 0) {
    return '暂无上下文数据';
  }
  final ratio = (contextTokens / contextWindow).clamp(0.0, 1.0);
  final percent = (ratio * 100).toStringAsFixed(1);
  final compacted = compactedMessages > 0 ? '；更早 $compactedMessages 条已压缩' : '';
  final action = canOpenSummary ? '；点击查看摘要' : '';
  return '$percent% · ${_formatTokens(contextTokens)} / '
      '${_formatTokens(contextWindow)} 上下文已使用$compacted$action';
}

/// token 数的展示口径：< 1000 原样，否则一位小数的 `K`。
String _formatTokens(int value) {
  if (value < 1000) {
    return '$value';
  }
  return '${(value / 1000).toStringAsFixed(1)}K';
}

/// 输入栏的上下文用量环。
///
/// 显示「本轮最后一次模型调用的上下文长度 ÷ 模型最大上下文窗口」：
/// 实体在控件行里只是模型胶囊与发送按钮之间的一枚细环，不写百分比文字，
/// 悬停（触屏长按）才给出精确数值。
///
/// 数据全部由调用方传入：这里不读 provider，也不管会话状态，
/// 才能在空态、停靠、浮窗与各种测试 harness 里用同一份实现。
///
/// 没有用量（[contextTokens] 为 0：新会话、首轮还在生成、或历史旧数据）时
/// 整枚环零尺寸、不占位，也不弹空提示——"没有上下文"不是一种需要展示的状态。
///
/// [onOpenCompaction] 非空时这枚环同时是「查看上下文摘要」的入口：
/// 长会话里摘要横条会被埋在消息流上方，环是随时够得着的那一个。
class ContextUsageRing extends StatefulWidget {
  const ContextUsageRing({
    super.key,
    this.contextTokens = 0,
    this.contextWindow = 0,
    this.compactedMessages = 0,
    this.compacting = false,
    this.onOpenCompaction,
  });

  /// 当前上下文长度（本轮最后一次调用的输入 token 数）。没有数据时为 0。
  final int contextTokens;

  /// 模型最大上下文窗口。服务端没给（或旧配置）时为 0。
  final int contextWindow;

  /// 已被整理成摘要的消息条数；0 表示没有可用摘要。只进提示文案。
  final int compactedMessages;

  /// 正在整理上下文：环改成一段持续旋转的弧，表示"这次整理还在跑"。
  ///
  /// 只由页面按"手动重新整理进行中"传 true——后台自动整理下客户端拿不到
  /// pending 状态，不能凭猜测让它一直转。
  final bool compacting;

  /// 打开摘要抽屉。`null` = 这个会话没有压缩记录，环退化为纯展示，
  /// 组件树与加这个参数之前逐字一致（不挂手势、不换光标、提示不多一个字）。
  final VoidCallback? onOpenCompaction;

  @override
  State<ContextUsageRing> createState() => _ContextUsageRingState();
}

class _ContextUsageRingState extends State<ContextUsageRing>
    with SingleTickerProviderStateMixin {
  bool _hovering = false;

  /// 转圈相位。只在 [ContextUsageRing.compacting] 为真时跑，
  /// 停下时立刻 `stop()`——留着空转会让"看起来还在整理"。
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      // 约 1.1 秒一圈：比占比过渡（200ms）慢得多，是"在干活"的节奏，
      // 又不至于慢到像卡住。
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.compacting) {
      _spin.repeat();
    }
  }

  @override
  void didUpdateWidget(ContextUsageRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.compacting == oldWidget.compacting) {
      return;
    }
    if (widget.compacting) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  /// 占比：窗口未知时按 0，只画轨道不画进度弧。
  ///
  /// 没有用量（`contextTokens <= 0`）的那条路径在 [build] 里已经提前返回，
  /// 走不到这里；留着判据是防止以后调整显隐条件时漏掉除零。
  double get _ratio {
    if (widget.contextWindow <= 0 || widget.contextTokens <= 0) {
      return 0;
    }
    return (widget.contextTokens / widget.contextWindow).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // 防御一层：调用方可能忘了在布局里条件化，单独复用时也不能画出空环。
    if (widget.contextTokens <= 0) {
      return const SizedBox.shrink();
    }

    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final onOpen = widget.onOpenCompaction;

    // 环本体：命中盒、悬停底与进度弧。可点与否画的是同一枚环，
    // 差别只在外面那一层手势——不要为"能点"再造一套画法。
    final ring = MouseRegion(
      // 不可点时保持默认光标：会变手型却点不动，比不可点更让人困惑。
      cursor: onOpen == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        width: _hitSize,
        height: _hitSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // 悬停底与相邻的圆形图标触发器同一档：都是同一中性色的低 alpha，
          // 不新增颜色，也不额外抬升视觉重量。
          color: _hovering
              ? scheme.surfaceContainerHighest.withValues(
                  alpha: AgentMenuStyle.triggerHighlightAlpha,
                )
              : null,
        ),
        child: Center(
          // 整理中画旋转弧，其余时候画占比。两条分支都只换画法，
          // 命中盒、悬停底与手势留在外层，不受影响。
          child: widget.compacting
              ? AnimatedBuilder(
                  animation: _spin,
                  builder: (context, _) => CustomPaint(
                    size: const Size.square(_ringSize),
                    painter: _ContextRingPainter(
                      ratio: _ratio,
                      spin: _spin.value,
                      track: scheme.outlineVariant.withValues(alpha: 0.5),
                      progress: palette.text.control,
                    ),
                  ),
                )
              : TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: _ratio),
                  duration: _ringTransition,
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => CustomPaint(
                    size: const Size.square(_ringSize),
                    painter: _ContextRingPainter(
                      ratio: value,
                      track: scheme.outlineVariant.withValues(alpha: 0.5),
                      // 控件入口那一档：看得见但不抢内容（与「+」、胶囊触发器同源）。
                      progress: palette.text.control,
                    ),
                  ),
                ),
        ),
      ),
    );

    final message = formatContextTooltip(
      contextTokens: widget.contextTokens,
      contextWindow: widget.contextWindow,
      compactedMessages: widget.compactedMessages,
      canOpenSummary: onOpen != null,
    );

    if (onOpen == null) {
      return Tooltip(
        message: message,
        waitDuration: const Duration(milliseconds: 120),
        child: ring,
      );
    }

    return Semantics(
      button: true,
      label: '上下文已用 ${(_ratio * 100).toStringAsFixed(0)}%，点击查看摘要',
      child: Tooltip(
        message: message,
        waitDuration: const Duration(milliseconds: 120),
        child: GestureDetector(
          // 命中盒只有 26dp：opaque 让点在环的留白上也生效，不必精确压到细弧。
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: ring,
        ),
      ),
    );
  }
}

/// 一圈底环 + 从 12 点顺时针的进度弧。
///
/// 不用 `CircularProgressIndicator`：那个是加载语义（会转、颜色跟主题走、
/// 线宽与轨道色都不受控），放进控件行会被读成"正在加载"。
class _ContextRingPainter extends CustomPainter {
  const _ContextRingPainter({
    required this.ratio,
    required this.track,
    required this.progress,
    this.spin,
  });

  /// 0~1 的已用比例。`spin` 非空时不参与绘制。
  final double ratio;
  final Color track;
  final Color progress;

  /// 转圈相位（0~1）。非空表示"正在整理"：画一段固定弧长的旋转弧，
  /// 而不是用量占比——两者语义不同，不能共用同一段弧。
  final double? spin;

  /// 转圈时那段弧占整圈的比例。约 22%：短到能看出在转，长到不像卡住。
  static const double _spinSweep = 0.22;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - _ringStroke) / 2;
    if (radius <= 0) {
      return;
    }

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringStroke
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringStroke
      ..strokeCap = StrokeCap.round
      ..color = progress;
    final rect = Rect.fromCircle(center: center, radius: radius);

    if (spin case final phase?) {
      canvas.drawArc(
        rect,
        -math.pi / 2 + 2 * math.pi * phase,
        2 * math.pi * _spinSweep,
        false,
        progressPaint,
      );
      return;
    }

    if (ratio <= 0) {
      return;
    }
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * ratio, false, progressPaint);
  }

  @override
  bool shouldRepaint(_ContextRingPainter oldDelegate) {
    return oldDelegate.ratio != ratio ||
        oldDelegate.track != track ||
        oldDelegate.progress != progress ||
        oldDelegate.spin != spin;
  }
}
