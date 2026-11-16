import '../../core/design/app_tokens.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shell_dividers.dart';
import 'shell_layout_state.dart';

/// 蓄力时长：越界之后必须继续按住这么久，才真的收起。
///
/// 一越界就收太容易误触：手抖一下、多拖几像素，整栏就没了。留半秒的
/// 缓冲，用户还有机会把分隔条拖回来。
const Duration kCollapseHoldDuration = Duration(milliseconds: 500);

/// 收起之后往回拖多少才算"要拉回来"。
///
/// 死区是必要的：蓄满的那一下常带一点反向抖动，1px 就把栏拽回来会让人
/// 觉得"刚收起来又自己弹回去"。
const double kSashReopenPull = 16;

/// 一次拖动更新之后，调用方把"还能不能继续缩"告诉拖动条。
///
/// 判断留在懂业务宽度的一侧（它才知道下限是多少），拖动条只负责计时、
/// 反馈与回拉计数。
enum ResizeDragResult {
  /// 正常跟手：宽度已经按 dx 更新过了。
  resizing,

  /// 已经贴在下限：再往前就是"想收起"，由拖动条开始蓄力。
  atLimit,
}

/// 分隔线贴向命中区的哪一侧。
///
/// 拖动条的 8dp 命中区会涂成相邻栏的底色（[ShellResizeHandle.fillColor]），
/// 视觉上属于那一栏，所以分隔线必须画在它的**远端**边缘：
/// 左栏的拖动条把线画在右边、右栏的拖动条把线画在左边。
///
/// 线若落在栏缝中央，两侧底色都不与它齐平，看上去仍然是"一条线 + 一条色带边界"。
enum ResizeHandleLineSide {
  /// 线贴命中区左边缘（右栏的拖动条）。
  leading,

  /// 线贴命中区右边缘（左栏的拖动条）。
  trailing,
}

/// 拖动条上那条分隔线。测试靠它断言"每个分隔处只有一条线"。
const Key kResizeHandleLineKey = Key('shell-resize-handle-line');

/// 拖动期间盖在整窗上那层"光标保底"。测试用它断言拖完就撤。
const Key kResizeCursorGuardKey = Key('shell-resize-cursor-guard');

/// 栏与内容区之间的拖动条，左右两侧栏共用。
///
/// 它同时是分隔线的唯一来源：
/// - 命中区刷成相邻栏的底色，把 8dp 栏缝并进那一栏，缝隙里不会露出外层渐变；
/// - 线画在命中区的远端，正好压在面板边界上，鼠标划过或拖拽时加粗变色。
///
/// 这样每个分隔处只有一条线。两套栏各写一版的话，迟早会有一条手感不一样。
///
/// 拖动到下限之后的行为也在这里（见 [_ShellResizeHandleState]）：
/// 越界要蓄力满 [kCollapseHoldDuration] 才收起，收起后还能从同一手势里
/// 反向拉回来——所以拖动条必须由调用方一直挂在树上，收起时压成 0 宽也不要摘。
class ShellResizeHandle extends StatefulWidget {
  const ShellResizeHandle({
    super.key,
    required this.onDrag,
    required this.onHold,
    required this.onReopen,
    required this.reopenSign,
    required this.fillColor,
    required this.lineSide,
    this.width = kRailHandleWidth,
    this.holdDuration = kCollapseHoldDuration,
  });

  /// 收到水平位移（dx），返回这一下之后是否已经贴在下限上。
  final ResizeDragResult Function(double dx) onDrag;

  /// 蓄力满：由调用方执行真正的收起。
  final VoidCallback onHold;

  /// 收起后反向拖够：由调用方把栏恢复原样。
  final VoidCallback onReopen;

  /// 哪个方向是"把栏拉回来"：左栏 `1`（向右），右栏 `-1`（向左）。
  final double reopenSign;

  /// 命中区的底色，取相邻栏的底色（`surface` @0.6）。
  ///
  /// 缝隙涂成面板色而不是透明：透明会露出底下的渐变，与两侧面板形成一条
  /// 颜色不同的窄带，带子两边各是一条边界，看起来还是两条线。
  final Color fillColor;

  /// 分隔线贴哪一侧。见 [ResizeHandleLineSide]。
  final ResizeHandleLineSide lineSide;

  final double width;

  /// 蓄力时长。做成参数只为让测试能压到几十毫秒。
  final Duration holdDuration;

  @override
  State<ShellResizeHandle> createState() => _ShellResizeHandleState();
}

class _ShellResizeHandleState extends State<ShellResizeHandle>
    with SingleTickerProviderStateMixin {
  bool _hovering = false;
  bool _dragging = false;

  /// 蓄力进度。用 `AnimationController` 而不是 `Timer`：既要计时，
  /// 又要把进度画到分隔线上，一个时钟就够，也不必自己管重绘。
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener(_handleHoldStatus);

  /// 本次手势里已经触发过收起。
  ///
  /// `onHold` 之后控件会重建、拖动条被压成 0 宽，但同一手势的 update 可能
  /// 还在路上；有这个标志才不会连续收起两次。
  bool _fired = false;

  /// 已收起、正在等"往回拉"。
  ///
  /// 这段时间里的位移只累计回拉距离，**不参与宽度计算**：栏已经藏起来了，
  /// 再去改宽度只会让恢复时的值飘掉。
  bool _collapsed = false;

  /// 收起之后累计的回拉距离（已按 [ShellResizeHandle.reopenSign] 换算成展开方向）。
  double _pull = 0;

  /// 拖动期间那层全屏"光标保底"，见 [_keepResizeCursor]。
  OverlayEntry? _cursorGuard;

  /// 拖动期间无论指针在哪，都保持"可调宽"光标。
  ///
  /// 光靠拖动条自己的 `MouseRegion` 不够：蓄力时宽度冻住、收起后更是压成
  /// 0 宽，指针一离开那条 8dp 的窄缝，光标就掉回默认箭头——可用户明明还按着
  /// 鼠标在拖，尤其是"收起后反拖恢复"那一段，光标突然变成箭头会让人以为
  /// 操作已经结束了。所以在 Overlay 顶部盖一层全屏 MouseRegion：
  /// `translucent` 只抢光标不抢事件，松手立刻撤掉。
  void _keepResizeCursor() {
    if (_cursorGuard != null) {
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      // 没有 Overlay 的场景（例如被单独 pump 在 Scaffold 里）：拖动条自身
      // 的 MouseRegion 仍然是可用状态，不做保底也不影响功能。
      return;
    }
    final entry = OverlayEntry(
      builder: (context) => const Positioned.fill(
        child: MouseRegion(
          key: kResizeCursorGuardKey,
          cursor: SystemMouseCursors.resizeColumn,
          hitTestBehavior: HitTestBehavior.translucent,
          child: SizedBox.expand(),
        ),
      ),
    );
    _cursorGuard = entry;
    overlay.insert(entry);
  }

  void _releaseResizeCursor() {
    final entry = _cursorGuard;
    _cursorGuard = null;
    // `mounted` 兜住"整棵树先被拆掉"的收尾顺序，避免对已移除的条目再 remove。
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  void _handleHoldStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _fired) {
      return;
    }
    _fired = true;
    _collapsed = true;
    _pull = 0;
    widget.onHold();
  }

  /// 停表并清进度。蓄力被取消、或被换成"已收起"时都要走这里。
  void _resetHold() {
    _hold.stop();
    _hold.value = 0;
  }

  void _handleDragStart(DragStartDetails details) {
    _fired = false;
    _collapsed = false;
    _pull = 0;
    _resetHold();
    _keepResizeCursor();
    setState(() => _dragging = true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final dx = details.delta.dx;

    if (_collapsed) {
      // 收起后手还没松：位移先攒着，攒够一个死区才把栏拉回来。
      // 往收起方向继续拖不会让它更"实"，所以负值一律按 0 处理。
      _pull = math.max(0, _pull + dx * widget.reopenSign);
      if (_pull < kSashReopenPull) {
        return;
      }
      // 恢复之后这一手势就回到"正常拖动"：把 `_fired` 一起清掉，
      // 用户再往回收还能重新蓄力（VS Code 里收放可以来回好几次）。
      _collapsed = false;
      _fired = false;
      _pull = 0;
      _resetHold();
      widget.onReopen();
      return;
    }

    final result = widget.onDrag(dx);
    if (result == ResizeDragResult.atLimit) {
      // `forward()` 在动画进行中不会重启，重复调用没有副作用。
      if (!_fired) {
        _hold.forward();
      }
      return;
    }

    // 回到合法区间：上一次蓄力作废，下次越界从头计时。
    _fired = false;
    _resetHold();
  }

  void _handleDragEnd() {
    // 松手即终止本次收起：已经收起的保持收起，没蓄满的作废。
    _fired = false;
    _collapsed = false;
    _pull = 0;
    _resetHold();
    _releaseResizeCursor();
    setState(() => _dragging = false);
  }

  @override
  void didUpdateWidget(ShellResizeHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hold.duration = widget.holdDuration;
  }

  @override
  void dispose() {
    // 拖动中被拆掉（例如切换布局）也要把保底光标撤掉，否则整窗会一直
    // 顶着"可调宽"的光标。
    _releaseResizeCursor();
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovering || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _handleDragStart,
        onHorizontalDragEnd: (_) => _handleDragEnd(),
        onHorizontalDragCancel: _handleDragEnd,
        onHorizontalDragUpdate: _handleDragUpdate,
        child: Container(
          width: widget.width,
          // 与相邻面板同底色：这一条 8dp 在视觉上属于面板，不算"缝隙"。
          // 留透明的话会露出外层渐变，与两侧面板各形成一条边界。
          color: widget.fillColor,
          child: Align(
            alignment: switch (widget.lineSide) {
              ResizeHandleLineSide.leading => Alignment.centerLeft,
              ResizeHandleLineSide.trailing => Alignment.centerRight,
            },
            // 只重建这条线：蓄力那半秒里逐帧推进，也不惊动整栏。
            child: ListenableBuilder(
              listenable: _hold,
              builder: (context, _) => _line(scheme, active),
            ),
          ),
        ),
      ),
    );
  }

  /// 两端渐隐的停点：普通态与蓄力遮罩共用同一份，改一处两端一起变。
  ///
  /// 各留 20% 的淡出区：再短，两端像被硬切一刀；再长，栏头与栏尾附近的线
  /// 几乎消失，与骨架横线在拐角处接不上。中间剩下的 60% 仍是整段实色，
  /// 拖动时的"可抓感"靠的就是它。
  static const List<double> _lineFadeStops = <double>[0, 0.2, 0.8, 1];

  /// 线宽。**三种状态都是 1px**：悬停与拖动只换颜色，不加粗。
  ///
  /// 早先交互态是 3px，加粗之后整条栏缝像被人用记号笔画了一道；分隔线该
  /// 提示"这里可以拖"，不该抢过内容。1px + 渐变 + 更低的 alpha 已经够读了。
  static const double _lineWidth = 1;

  /// 那条线：平时是常驻的 1px 细线，悬停 / 拖拽时换成主色（更透、两端渐隐），
  /// 蓄力时在它上面从顶端往下渐亮。
  ///
  /// 悬停 / 拖拽态不是"整条一样的实色"：两端各淡出 12%，中段才是实色，
  /// 看起来像从上下两端往中间亮起来的一条光带。**静止态不做渐隐**——分隔线
  /// 在栏头与栏尾也必须读得出来，那里恰好是骨架横线起笔的地方。
  ///
  /// 普通态两个分支都用 `LinearGradient`（未交互时四段同色）：装饰同构，
  /// `AnimatedContainer` 才能走 `Gradient.lerp` 平滑过渡，而不是在
  /// "实色 → 渐变"之间跳一下。
  ///
  /// 蓄力期间不能继续用 `AnimatedContainer`：它的 120ms 缓动会把逐帧推进的
  /// 进度吃掉，看起来像没动。线宽与交互态一致，蓄力只改颜色不改几何——否则
  /// "分隔处只有一条线、位置贴边"的既有约定就破了。
  Widget _line(ColorScheme scheme, bool active) {
    // 0.4 而不是更高：这条线只是"可拖"的提示，压在内容与栏缝之间，
    // 再实一点就会像一道从上到下的分色带。
    final baseColor = active
        ? scheme.primary.withValues(alpha: 0.4)
        // 与骨架层的横线同色：竖线和横线在拐角处必须是同一条线。
        : shellDividerColor(scheme);
    final progress = _fired ? 0.0 : _hold.value;

    if (progress <= 0) {
      return AnimatedContainer(
        key: kResizeHandleLineKey,
        duration: const Duration(milliseconds: 120),
        width: _lineWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: active
                // 端点的透明色由主色派生：`Colors.transparent` 是透明**黑**，
                // 插值时中间会掠过一段发暗的灰，两端看着像蒙了脏。
                ? <Color>[
                    baseColor.withValues(alpha: 0),
                    baseColor,
                    baseColor,
                    baseColor.withValues(alpha: 0),
                  ]
                // 静止态四段同色：等价于原来的实心细线，整条连续。
                : <Color>[baseColor, baseColor, baseColor, baseColor],
            stops: _lineFadeStops,
          ),
        ),
      );
    }

    // 进度条要"看得见但不抢眼"：蓄力只是一次拖动里的中间状态，蓝色实心块
    // 从上往下长太跳。所以颜色压到很淡的一层主色（比拖动时的 0.4 还淡），
    // 前沿用一段 30% 的过渡带晕开，看起来像那条线在慢慢变亮，而不是一根
    // 色块在爬。
    //
    // `stops` 收在 0.001~0.95：两端取到 0/1 最容易在渲染层踩边界情况，
    // 也要给过渡带留出位置。
    final filled = progress.clamp(0.001, 0.95);
    final edge = math.min(1.0, filled + 0.3);
    return ShaderMask(
      // `dstIn` 把遮罩的 alpha 乘到子级上：进度渐变的观感原样保留，只多一层
      // 两端淡出，与悬停态的轮廓是同一条。若改成一个渐变里手工合并停点，
      // 就得把 filled / edge 与渐隐停点一起排序并保证单调递增，蓄力每推进
      // 一帧都要重算，很容易写出非法 stops。
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        // 遮罩只取 alpha，颜色仍由主色派生，不引入第二种色相。
        colors: <Color>[
          scheme.primary.withValues(alpha: 0),
          scheme.primary,
          scheme.primary,
          scheme.primary.withValues(alpha: 0),
        ],
        stops: _lineFadeStops,
      ).createShader(bounds),
      child: Container(
        key: kResizeHandleLineKey,
        // 与另外两种状态同宽：蓄力也只改颜色，不加粗。
        width: _lineWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              scheme.primary.withValues(alpha: 0.32),
              scheme.primary.withValues(alpha: 0.32),
              baseColor,
              baseColor,
            ],
            stops: <double>[0, filled, edge, 1],
          ),
        ),
      ),
    );
  }
}
