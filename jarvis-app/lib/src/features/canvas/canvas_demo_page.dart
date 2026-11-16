import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/immersive_fullscreen.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'canvas_control_bar.dart';
import 'canvas_demo_graph.dart';
import 'canvas_json_preview.dart';
import 'canvas_node_card.dart';
import 'canvas_node_data.dart';
import 'canvas_options.dart';
import 'canvas_theme.dart';

/// 底部操作提示条的高度。
const double kCanvasHintBarHeight = 28;

/// 栏头里那颗「全屏」按钮的 Key。文案会改，测试靠它定位。
const Key kCanvasFullscreenKey = Key('canvas-fullscreen');

/// 画布编辑器本身的 Key。测试靠它断言"进出全屏没有重挂编辑器"。
const Key kCanvasEditorKey = Key('canvas-editor');

/// 无限画布演示页。
///
/// 纯内存：节点与连线只活在这一页的 [NodeFlowController] 里，切走再回来是初始
/// 示例图。这是刻意的——Demo 只有十来个节点，重建成本可忽略；换来的是不必把
/// 一个内部用 MobX 的控制器托管到 provider 里，也就不用为它设计销毁时机。
///
/// 宽屏由 `ShellPane` 以 `embedded: true` 嵌进中栏，窄屏由 [openCanvasDemoPage]
/// 整页推入：两种形态共用同一份 body，只有栏头不同。
class CanvasDemoPage extends ConsumerStatefulWidget {
  const CanvasDemoPage({
    super.key,
    this.embedded = false,
    this.immersive = false,
  });

  /// 是否嵌在三栏骨架的中栏里。内嵌时不画 AppBar，改用 40dp 的细栏头。
  final bool embedded;

  /// 画布正占着沉浸全屏（与终端、图片预览同一套，见 `immersive_fullscreen.dart`）。
  ///
  /// 由 `ShellPane` 传进来而不是在这里读 provider：窄屏整页形态也复用本页，
  /// 而整页本身已经铺满，读同一份全局状态只会让人误以为它也在全屏里。
  ///
  /// 为真时栏头、控制条、提示条一起收起，整屏只剩画布——与终端全屏的口径一致。
  final bool immersive;

  @override
  ConsumerState<CanvasDemoPage> createState() => _CanvasDemoPageState();
}

class _CanvasDemoPageState extends ConsumerState<CanvasDemoPage> {
  /// 画布控制器。内部是 MobX，`dispose` 时必须释放，否则切页会泄漏。
  NodeFlowController<CanvasNodeData?, dynamic>? _controller;

  /// 事件对象只建一次：每次 build 新建会让编辑器在 `didUpdateWidget` 里
  /// 反复重挂事件处理器（库按对象身份比较）。
  NodeFlowEvents<CanvasNodeData?, dynamic>? _events;

  CanvasLinkStyle _linkStyle = CanvasLinkStyle.smoothstep;
  CanvasEffect _effect = CanvasEffect.flowingDash;
  CanvasGridStyle _gridStyle = CanvasGridStyle.dots;
  bool _minimapVisible = true;
  bool _snapEnabled = false;
  bool _lodEnabled = false;
  bool _statsVisible = false;

  int _nodeCount = 0;
  int _connectionCount = 0;
  double _zoom = 1;

  /// 统计刷新去重：一帧里可能连着收到好几个事件（新建连线会同时触发
  /// 连线变更与选择变更），重复 setState 只是白重建一次整页。
  bool _statsScheduled = false;

  /// Esc 的早期处理器是否已挂上（只在这个页面处于沉浸全屏时挂）。
  bool _escHandlerInstalled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) {
      return;
    }

    // 分组框与便签的底色只能从语义色取，而 `build` 里创建控制器会在每帧重建；
    // 用 `didChangeDependencies`（此时 `Theme` 已经可读）保证只建一次。
    final scheme = Theme.of(context).colorScheme;
    // 分组框与便签都是库的自渲染节点：`color` 会被整条铺成标题带 / 便签底，
    // 而正文用的是 `nodeTheme.titleStyle`（主文字色）。所以这两个颜色必须是
    // "容器色"——明暗两套里都能和主文字色拉开对比，否则标题会糊在色带上。
    final graph = buildCanvasDemoGraph(
      groupColor: scheme.secondaryContainer,
      noteColor: scheme.tertiaryContainer,
    );

    final controller = NodeFlowController<CanvasNodeData?, dynamic>(
      config: NodeFlowConfig(
        // 缩放上下限比库默认宽一档：Demo 要能一眼看全整张图，也要能贴近看卡片。
        minZoom: 0.3,
        maxZoom: 2.5,
        // 库自带的署名角标在演示页里是干扰项。
        showAttribution: false,
        plugins: <NodeFlowPlugin>[
          AutoPanPlugin(),
          LodPlugin(enabled: _lodEnabled),
          MinimapPlugin(
            visible: _minimapVisible,
            // 小地图主题不挂在 `NodeFlowTheme` 上，只能在这里配。
            // 明暗切换后它不会跟着变：控制器是单例，重建它就等于丢掉整张图。
            theme: MinimapTheme(
              backgroundColor: scheme.surface,
              nodeColor: scheme.primary,
              viewportColor: scheme.primary,
              borderColor: scheme.outlineVariant,
              borderRadius: AppRadius.sm,
            ),
          ),
          SnapPlugin(<SnapDelegate>[
            GridSnapDelegate(gridSize: 24),
          ], enabled: _snapEnabled),
          StatsPlugin(),
        ],
      ),
      nodes: graph.nodes,
      connections: graph.connections,
    );

    _controller = controller;
    _nodeCount = graph.nodes.length;
    _connectionCount = graph.connections.length;

    _events = NodeFlowEvents<CanvasNodeData?, dynamic>(
      node: NodeEvents<CanvasNodeData?>(
        onCreated: (_) => _scheduleStats(),
        onDeleted: (_) => _scheduleStats(),
      ),
      connection: ConnectionEvents<CanvasNodeData?, dynamic>(
        onCreated: (_) => _scheduleStats(),
        onDeleted: (_) => _scheduleStats(),
      ),
      viewport: ViewportEvents(onMoveEnd: (_) => _scheduleStats()),
      onSelectionChange: (_) => _scheduleStats(),
    );

    // 首帧布局完才有屏幕尺寸，`fitToView` 在此之前算不出缩放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _controller?.fitToView();
      _syncStats();
    });
  }

  @override
  void initState() {
    super.initState();
    _syncEscapeHandler();
  }

  @override
  void didUpdateWidget(covariant CanvasDemoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.immersive == widget.immersive) {
      return;
    }
    // 进出全屏只改了可用高度。这里刻意**不** `fitToView()`：那会改掉用户
    // 当下的缩放；只把统计（小地图、缩放比例）重新取一遍就够了。
    _scheduleStats();
    _syncEscapeHandler();
  }

  /// 让 Esc 只在沉浸全屏里生效，并且不受焦点落在谁身上影响。
  ///
  /// 为什么不能用祖先 `Focus.onKeyEvent`：画布库把 Esc 绑成了 `cancel_operation`
  /// （`vyuh_node_flow` 的 `node_flow_actions.dart`），编辑器一旦自己拿到焦点
  /// （点过画布、连接拖拽之后都会），按键就在它那一层被消费掉，冒泡不到外面——
  /// 表现就是"刚进全屏时 Esc 能退，过几秒就退不出来了"。
  ///
  /// `FocusManager` 的早期处理器跑在整棵焦点树之前，与焦点在谁身上无关；
  /// 只在沉浸期间挂，非全屏时编辑器自己的 Esc 语义（取消连线 / 取消编辑）原样保留。
  void _syncEscapeHandler() {
    if (widget.immersive && !_escHandlerInstalled) {
      _escHandlerInstalled = true;
      FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKey);
    } else if (!widget.immersive && _escHandlerInstalled) {
      _escHandlerInstalled = false;
      FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKey);
    }
  }

  KeyEventResult _handleEarlyKey(KeyEvent event) {
    if (!widget.immersive ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // 正在编辑便签正文 / 分组标题时，Esc 先让文本框收掉编辑（第一次按只是
    // 退出编辑），再按一次才退出全屏。
    if (_isEditingText()) {
      return KeyEventResult.ignored;
    }
    ref.read(immersiveFullscreenProvider.notifier).exit();
    return KeyEventResult.handled;
  }

  /// 键盘焦点是否落在可编辑文本里（便签正文与分组标题双击后是 `TextField`）。
  bool _isEditingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) {
      return false;
    }
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  @override
  void dispose() {
    if (_escHandlerInstalled) {
      _escHandlerInstalled = false;
      FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKey);
    }
    _controller?.dispose();
    super.dispose();
  }

  void _scheduleStats() {
    if (_statsScheduled) {
      return;
    }
    _statsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _statsScheduled = false;
      _syncStats();
    });
  }

  /// 把节点数 / 连线数 / 缩放比例读出来给底部提示条。
  ///
  /// 只在真的变了才 setState：`onSelectionChange` 在每次点选时都会来一发，
  /// 数字没变时重建整页会让画布闪一下。
  void _syncStats() {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }
    final nodes = controller.nodes.length;
    final connections = controller.connections.length;
    final zoom = controller.currentZoom;
    if (nodes == _nodeCount &&
        connections == _connectionCount &&
        (zoom - _zoom).abs() < 0.005) {
      return;
    }
    setState(() {
      _nodeCount = nodes;
      _connectionCount = connections;
      _zoom = zoom;
    });
  }

  void _zoomBy(double delta) {
    _controller?.zoomBy(delta);
    _scheduleStats();
  }

  void _fitToView() {
    _controller?.fitToView();
    _scheduleStats();
  }

  void _resetZoom() {
    _controller?.zoomTo(1);
    _scheduleStats();
  }

  void _toggleMinimap() {
    // 状态先改：库的 `MinimapPlugin` 内部是 MobX observable，
    // 命令式调用之后它自己会重建小地图，不需要我们再 setState 一次图层。
    _controller?.minimap?.toggle();
    setState(() => _minimapVisible = !_minimapVisible);
  }

  void _toggleSnap() {
    _controller?.snap?.toggle();
    setState(() => _snapEnabled = !_snapEnabled);
  }

  void _toggleLod() {
    _controller?.lod?.toggle();
    setState(() => _lodEnabled = !_lodEnabled);
  }

  /// 导出当前图的 JSON 文本。
  ///
  /// 走库自己的 `exportGraph()`：节点、端口、连线、视口全部由它序列化，
  /// 我们只补一个节点数据的投影——sealed 家族的实例本身不可 JSON 化。
  String _exportJson() {
    final graph = _controller!.exportGraph();
    final map = graph.toJson(
      (data) => data == null
          ? null
          : <String, Object?>{
              'kind': data.kind,
              'title': data.title,
              'subtitle': data.subtitle,
            },
      (value) => value,
    );
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  void _export() {
    final String json;
    try {
      json = _exportJson();
    } on Object catch (error) {
      // 序列化失败不该把页面炸掉：给一句能定位的提示就够了。
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('导出失败：$error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    showCanvasJsonPreview(context, json: json);
  }

  /// 栏头右端的视口动作。内嵌的细栏头与窄屏 AppBar 共用同一份。
  ///
  /// 窄屏整页把 4 枚缩放钮并成一枚胶囊：各自一层玻璃会在交界处叠出两条折射
  /// 边缘，看起来像胶囊裂了缝。内嵌形态仍是栏头里排开的方钮，不合并。
  List<Widget> _viewActions() {
    final buttons = <Widget>[
      _actionButton(
        bare: !widget.embedded,
        tooltip: '缩小',
        icon: Icons.remove,
        onPressed: () => _zoomBy(-0.1),
      ),
      _actionButton(
        bare: !widget.embedded,
        tooltip: '放大',
        icon: Icons.add,
        onPressed: () => _zoomBy(0.1),
      ),
      _actionButton(
        bare: !widget.embedded,
        tooltip: '自适应全图',
        icon: Icons.fit_screen_outlined,
        onPressed: _fitToView,
      ),
      _actionButton(
        bare: !widget.embedded,
        tooltip: '复位到 100%',
        icon: Icons.restart_alt,
        onPressed: _resetZoom,
      ),
    ];

    if (!widget.embedded) {
      return <Widget>[MobileTopBarButtonGroup(children: buttons)];
    }

    // 全屏只在宽屏内嵌态出现：窄屏整页本身已经铺满，按了不会有任何变化。
    // 进的是与终端 / 图片预览同一套沉浸模式（`immersive_fullscreen.dart`），
    // 不是另开一页；进去之后这条栏自己也被收起，退出靠 Esc。
    buttons.add(
      _actionButton(
        key: kCanvasFullscreenKey,
        tooltip: '全屏',
        icon: Icons.open_in_full_rounded,
        onPressed: () => unawaited(
          ref
              .read(immersiveFullscreenProvider.notifier)
              .enter(ImmersiveSurface.canvas),
        ),
      ),
    );
    return buttons;
  }

  /// 与录音、设置页同一套栏头按钮：内嵌时命中区收到 24、图标 14；
  /// 窄屏整页换成 38dp 玻璃圆钮。
  Widget _actionButton({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool bare = false,
  }) {
    if (!widget.embedded) {
      return MobileTopBarButton(
        key: key,
        bare: bare,
        icon: icon,
        tooltip: tooltip,
        onPressed: onPressed,
      );
    }
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: shellIconButtonStyle(
        minimumSize: const Size.square(kPaneHeaderButtonSize),
      ),
      iconSize: kPaneHeaderIconSize,
      icon: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时骨架的渐变透上来；
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded ? paneSurfaceColor(scheme) : null,
      // 内嵌形态不画第二层 AppBar：外层已经是三栏统一的细栏头。
      appBar: widget.embedded
          ? null
          : MobileAppBar(title: '无限画布', actions: _viewActions()),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          // 四个槽位恒定（栏头 / 控制条 / 画布 / 提示条）：沉浸模式只把三块
          // 换成零尺寸占位，绝不增删子节点——否则 `Expanded` 里的
          // `NodeFlowEditor` 会换索引重挂，视口、选中与拖拽状态一起丢。
          children: <Widget>[
            widget.embedded && !widget.immersive
                ? EmbeddedToolbar(title: '无限画布', actions: _viewActions())
                : const SizedBox.shrink(),
            if (!widget.immersive)
              CanvasControlBar(
                linkStyle: _linkStyle,
                effect: _effect,
                gridStyle: _gridStyle,
                minimapVisible: _minimapVisible,
                snapEnabled: _snapEnabled,
                lodEnabled: _lodEnabled,
                statsVisible: _statsVisible,
                onLinkStyleChanged: (value) =>
                    setState(() => _linkStyle = value),
                onEffectChanged: (value) => setState(() => _effect = value),
                onGridStyleChanged: (value) =>
                    setState(() => _gridStyle = value),
                onMinimapToggled: _toggleMinimap,
                onSnapToggled: _toggleSnap,
                onLodToggled: _toggleLod,
                onStatsToggled: () =>
                    setState(() => _statsVisible = !_statsVisible),
                onExport: _export,
              )
            else
              const SizedBox.shrink(),
            Expanded(
              // 有 Key 才不会被换掉：`Column` 更新子节点时，两端一旦对不上，
              // 中间那几格只按 Key 匹配——无 Key 的槽位会被整个重建。
              key: const ValueKey<String>('canvas-editor-slot'),
              child: controller == null
                  ? const SizedBox.shrink()
                  : NodeFlowEditor<CanvasNodeData?, dynamic>(
                      key: kCanvasEditorKey,
                      controller: controller,
                      theme: canvasThemeOf(
                        context,
                        linkStyle: _linkStyle,
                        effect: _effect,
                        gridStyle: _gridStyle,
                      ),
                      events: _events,
                      nodeBuilder: (context, node) =>
                          CanvasNodeCard(node: node),
                    ),
            ),
            widget.immersive
                ? const SizedBox.shrink()
                : _CanvasHintBar(
                    statsVisible: _statsVisible,
                    nodeCount: _nodeCount,
                    connectionCount: _connectionCount,
                    zoom: _zoom,
                  ),
          ],
        ),
      ),
    );
  }
}

/// 底部提示条：左边固定写操作方式，右边在「统计」打开时给一行实时数字。
///
/// 不放进控制条：控制条是"改参数"的地方，这里是"怎么用"的说明，
/// 两者混在一起会让那一条越加越长。
class _CanvasHintBar extends StatelessWidget {
  const _CanvasHintBar({
    required this.statsVisible,
    required this.nodeCount,
    required this.connectionCount,
    required this.zoom,
  });

  final bool statsVisible;
  final int nodeCount;
  final int connectionCount;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);

    return Container(
      height: kCanvasHintBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '滚轮缩放 · 空白拖动平移 · 框选多选 · Delete 删除 · 从端口拖出连线',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.meta,
            ),
          ),
          if (statsVisible)
            Text(
              '节点 $nodeCount · 连线 $connectionCount · ${(zoom * 100).round()}%',
              style: text.meta,
            ),
        ],
      ),
    );
  }
}
