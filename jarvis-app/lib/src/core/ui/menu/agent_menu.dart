import 'package:flutter/material.dart';

import 'menu_model.dart';
import 'menu_panel.dart';

/// 全站唯一的菜单组件：一个触发器 + 一个浮层面板。
///
/// 调用方只描述"有哪些组、哪些项、点了做什么"，不再自己拼 `MenuAnchor`、
/// 不再自己写 `MenuItemButton` 的样式。想调整菜单外观，改 [AgentMenuStyle]
/// 或这里的触发器部件，全站入口一起变。
///
/// 为什么不是 `showMenu`：`PopupMenuItem` 的悬停高亮是系统默认的淡色矩形，
/// 拿不到 Codex 那种"浅灰圆角块"，也没法自然插分组标题与行尾说明。
/// `MenuAnchor` + `MenuItemButton` 的 ButtonStyle 能按状态给底色与前景色，
/// 而定位、点外部关闭、Esc、上下键遍历、越界夹取全部是现成的。
class AgentMenu<T> extends StatefulWidget {
  const AgentMenu({
    super.key,
    required this.width,
    required this.groups,
    required this.onSelected,
    required this.builder,
    this.maxHeight = AgentMenuStyle.panelMaxHeight,
    this.alignment = AlignmentDirectional.bottomStart,
    this.alignmentOffset = const Offset(0, AgentMenuStyle.triggerGap),
    this.tooltip,
    this.controller,
    this.consumeOutsideTap = false,
    this.triggerHandlesTap = true,
  });

  /// 浮层宽度。
  ///
  /// 定值而不是跟着触发器走：触发器通常只有几十 dp 宽，跟着它会长成一条
  /// 放不下「中文名 + 英文别名 + 一句用途」的窄缝。参考图也是小胶囊、宽菜单。
  final double width;

  /// 菜单内容。分组标题、组间分组线、组内条目顺序都由它决定。
  final List<AgentMenuGroup<T>> groups;

  /// 选中某一项的标识。二级子菜单里的项可以用
  /// [AgentMenuItem.onSelected] 单独覆盖，走不同的分发。
  final ValueChanged<T> onSelected;

  /// 触发器构造器。
  ///
  /// `open` / `hovering` 由组件维护：折角朝向与悬停底色都要跟着它们走，
  /// 而 `MenuController` 本身不通知重建，只能在组件里记一份再下发。
  ///
  /// `controller` 可以直接 `open()`（按钮）、`open(position:)`（右键）或
  /// `isOpen ? close() : open()`（开合切换）。注意 `position` 取的是
  /// **相对锚点**的局部坐标（`TapDownDetails.localPosition`），不是全局坐标。
  final Widget Function(
    BuildContext context,
    MenuController controller,
    bool open,
    bool hovering,
  )
  builder;

  /// 面板最大高度：再长就滚动。
  final double maxHeight;

  /// 浮层锚在触发器的哪个角上。
  ///
  /// 默认左下角：面板从触发器左边起、向右长。要「面板右边缘对齐触发器右边缘」
  /// 就用 [AlignmentDirectional.bottomEnd] 配
  /// [AgentMenuStyle.rightAlignedOffset]——`MenuAnchor` 只会把面板的左上角
  /// 放在对齐点上，右对齐只能靠自己减一个宽度。
  final AlignmentGeometry alignment;

  /// 浮层相对对齐点的偏移。默认「向下 6dp」。
  ///
  /// 摆不下时 `MenuAnchor` 会在布局阶段把它翻到触发器上方并夹回视口：
  /// 输入栏贴着窗口底部，于是实际总是向上弹——这比自己算一个"向上"的对齐更稳，
  /// 面板高度随条目数变化，硬算会错位。
  final Offset alignmentOffset;

  /// 触发器的 tooltip。
  final String? tooltip;

  /// 外部持有的控制器。
  ///
  /// 需要在 `builder` 之外（比如右键回调、状态层）主动开菜单时传进来；
  /// 不传则内部自建一个，"点触发器等组件自己开"的场景不用关心它。
  final MenuController? controller;

  /// 按坐标弹出时通常为 true：这时"点锚点"指的是点回原来的位置，
  /// 用户的心智是"点别处收起"，不该被当成菜单内部点击而无反应。
  final bool consumeOutsideTap;

  /// 由组件接管触发器的点击（默认）。
  ///
  /// 传 false 时组件只负责开合状态与浮层，点击由 builder 里的控件自己处理——
  /// 各处「⋯」是 `IconButton`，它自带 onPressed 与 tooltip，若再在外层包一层
  /// 手势就会一次点击既开又关。
  final bool triggerHandlesTap;

  @override
  State<AgentMenu<T>> createState() => _AgentMenuState<T>();
}

class _AgentMenuState<T> extends State<AgentMenu<T>> {
  MenuController? _internalController;

  /// 箭头朝向与悬停底色要跟着开合走，而 `MenuController` 本身不通知重建。
  bool _open = false;
  bool _hovering = false;

  /// 有外部控制器就用外部的：两边各持一个的话，
  /// 外面调 `open` 只会在另一个锚点上开菜单。
  MenuController get _controller =>
      widget.controller ?? (_internalController ??= MenuController());

  void _toggle() =>
      _controller.isOpen ? _controller.close() : _controller.open();

  void _setOpen(bool value) {
    if (!mounted || _open == value) {
      return;
    }
    setState(() => _open = value);
  }

  @override
  Widget build(BuildContext context) {
    final trigger = widget.builder(context, _controller, _open, _hovering);

    // 触发器的指针与点击只在组件接管时挂：各处「⋯」是自带 onPressed 的
    // IconButton，鼠标指针与悬停反馈归它管；整条标签栏更是只接右键，
    // 在这里套一层 click 指针会让空白拖动区也跟着变成手型。
    final child = widget.triggerHandlesTap
        ? MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) {
              if (!_hovering) {
                setState(() => _hovering = true);
              }
            },
            onExit: (_) {
              if (_hovering) {
                setState(() => _hovering = false);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: trigger,
            ),
          )
        : trigger;

    return MenuAnchor(
      controller: _controller,
      alignmentOffset: widget.alignmentOffset,
      style: AgentMenuStyle.panelStyleOf(context).copyWith(
        alignment: widget.alignment,
        minimumSize: WidgetStatePropertyAll<Size>(Size(widget.width, 0)),
        maximumSize: WidgetStatePropertyAll<Size>(
          Size(widget.width, widget.maxHeight),
        ),
      ),
      consumeOutsideTap: widget.consumeOutsideTap,
      onOpen: () => _setOpen(true),
      onClose: () => _setOpen(false),
      menuChildren: buildAgentMenuRows(
        groups: widget.groups,
        panelWidth: widget.width,
        onSelected: widget.onSelected,
      ),
      builder: (context, controller, _) => widget.tooltip == null
          ? child
          : Tooltip(message: widget.tooltip!, child: child),
    );
  }
}
