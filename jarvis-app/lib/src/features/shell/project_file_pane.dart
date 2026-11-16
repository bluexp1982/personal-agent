import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_file_providers.dart';
import '../../core/project_paths.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/shell_icon_button.dart';
import '../conversations/composer_menus.dart';
import '../conversations/path_ref_embed.dart';
import 'chat_window_state.dart';
import 'file_pane_state.dart';
import 'panel_fullscreen.dart';
import 'preview_launcher.dart';
import 'shell_layout_state.dart';

/// 文件行的右键动作。
enum FileRowAction { open, preview, copyRelativePath, copyAbsolutePath }

/// 文件标签的主体：路径工具栏 + 懒加载目录树。
///
/// 只对「已展开」的目录 watch provider：收起即停止监听，不会因为顶层渲染
/// 就把整棵仓库递归拉一遍。
class ProjectFilePane extends ConsumerStatefulWidget {
  const ProjectFilePane({super.key});

  @override
  ConsumerState<ProjectFilePane> createState() => _ProjectFilePaneState();
}

class _ProjectFilePaneState extends ConsumerState<ProjectFilePane> {
  /// 右键命中的文件或目录。菜单内容跟着它走：非 html/htm 不出现「预览」。
  ProjectEntry? _menuTarget;

  /// 项目根的服务端绝对路径，复制相对路径以它为根。
  ///
  /// 取根列表的 `listing.path`（服务端规范化后的结果），不用 `Project.path`：
  /// 后者与文件树根未必是同一层规范化，Windows 服务端上会差出斜杠与盘符大小写。
  String _rootPath = '';

  /// 当前选中的文件路径。
  ///
  /// 单击文件只点亮这一行、不打开预览；打开只能走右键「打开」。
  /// 与"当前预览标签"保持同步（见 build 里的 listen），两者不会各亮一行。
  String? _selectedPath;

  /// [_selectedPath] 属于哪个项目：切项目时旧路径不再有意义，清掉高亮。
  String _selectedProjectId = '';

  /// 整棵文件树共用一个菜单锚点。
  ///
  /// 不给每行各挂一个 `MenuAnchor`：树一次构建全部已展开行（上限 200），
  /// 每行一个锚点等于白建 200 个浮层宿主，只为了右键那一下。
  final MenuController _menu = MenuController();
  final GlobalKey _anchorKey = GlobalKey(debugLabel: 'file-pane-menu-anchor');

  @override
  Widget build(BuildContext context) {
    // 认"最后一个有归属的项目"：中栏切到录音 / 设置 / 记忆时这棵树不该消失。
    final projectId = ref.watch(shellProjectMemoProvider);
    if (projectId != _selectedProjectId) {
      // 纯赋值：这里只是把上一棵树的高亮丢掉，重建由项目变化本身触发。
      _selectedProjectId = projectId;
      _selectedPath = null;
    }
    // 从标签栏切到另一个预览时，树里的高亮跟过去：选中态与"正在看的那一份"
    // 始终是同一个文件，不会出现一行浅底、另一行主色边。
    ref.listen<String?>(
      filePaneTabProvider.select((state) => state.activePreviewPath),
      (previous, next) {
        if (next != null && next != _selectedPath) {
          setState(() => _selectedPath = next);
        }
      },
    );

    // 右栏左侧那条 8dp 拖动条此刻在不在：普通三栏有，聊天浮窗让位 /
    // 面板全屏时没有（与 `_WideContent.showHandle` 同口径）。有它时行块贴住
    // 面板左缘就已经是视觉 8；没有时面板左缘就是分隔线，行块必须自己让出 8。
    final floating = ref.watch(
      chatWindowProvider.select((state) => state.floating),
    );
    final fullscreen = ref.watch(panelFullscreenProvider);
    final leadInset = floating || fullscreen ? kRailRowPillInset : 0.0;

    final body = projectId.isEmpty
        ? const _PaneHint('先在左侧选择一个项目')
        : _buildTree(context, projectId, leadInset);

    return Stack(
      children: <Widget>[
        body,
        // 菜单锚点缩成左上角的 0 尺寸空盒：`MenuAnchor` 会把锚点整棵子树都当成
        // "菜单内部"，锚在整棵树上时，点树里的空白不会收起菜单。
        // 坐标换算仍以它为准（`globalToLocal` 得到的还是树内坐标），弹出位置不变。
        Positioned(
          left: 0,
          top: 0,
          child: AgentMenu<FileRowAction>(
            controller: _menu,
            width: AgentMenuStyle.panelMinWidth,
            // 按坐标弹出：面板左上角落在右键落点，不再额外偏移。
            alignmentOffset: Offset.zero,
            // 触发器只是一个空锚点，点击全交给树里的行自己处理。
            triggerHandlesTap: false,
            consumeOutsideTap: true,
            groups: <AgentMenuGroup<FileRowAction>>[
              AgentMenuGroup<FileRowAction>(items: _menuItems()),
            ],
            onSelected: _run,
            builder: (context, controller, open, hovering) => KeyedSubtree(
              key: _anchorKey,
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTree(
    BuildContext context,
    String projectId,
    double leadInset,
  ) {
    final showHidden = ref.watch(filePaneShowHiddenProvider);
    final key = (projectId: projectId, path: '', showHidden: showHidden);
    final root = ref.watch(projectListingProvider(key));
    // 纯赋值：根路径只服务于右键菜单，不需要为它再触发一次重建。
    final rootPath = root.asData?.value.path;
    if (rootPath != null && rootPath.isNotEmpty) {
      _rootPath = rootPath;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PathToolbar(
          path: root.asData?.value.path ?? '',
          showHidden: showHidden,
          onRefresh: () => ref.invalidate(projectListingProvider),
          onToggleHidden: () =>
              ref.read(filePaneShowHiddenProvider.notifier).toggle(),
        ),
        Expanded(
          child: root.when(
            loading: () => const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (error, _) => _PaneError(
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(projectListingProvider),
            ),
            data: (listing) {
              if (listing.entries.isEmpty) {
                return _PaneHint(showHidden ? '这个目录是空的' : '这个目录是空的（可能有隐藏项）');
              }

              return ListView(
                // 水平内边距交给行自己：这里再垫一层会和行内边距叠加。
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
                children: <Widget>[
                  for (final entry in listing.entries)
                    _EntryTile(
                      projectId: projectId,
                      entry: entry,
                      depth: 0,
                      showHidden: showHidden,
                      rootPath: _rootPath,
                      selectedPath: _selectedPath,
                      leadInset: leadInset,
                      onSelect: _select,
                      onSecondary: _openMenu,
                    ),
                  if (listing.truncated) const _InlineHint('条目太多，只显示前 200 项'),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 菜单内容跟着"右键命中的那个文件 / 目录"走。
  ///
  /// 还没右键过时为空：`AgentMenu` 不会在空菜单上弹出空白面板。
  List<AgentMenuItem<FileRowAction>> _menuItems() {
    final entry = _menuTarget;
    if (entry == null) {
      return const <AgentMenuItem<FileRowAction>>[];
    }

    return <AgentMenuItem<FileRowAction>>[
      // 目录没有"打开 / 预览"：单击已经负责展开，菜单里只留复制路径。
      if (!entry.isDir) ...<AgentMenuItem<FileRowAction>>[
        AgentMenuItem<FileRowAction>(
          key: const ValueKey<String>('file-menu-open'),
          value: FileRowAction.open,
          icon: Icons.description_outlined,
          label: '打开',
        ),
        // 只给网页：真正能渲染的只有 html/htm，别的扩展名显示出来只会是一次失败。
        if (_isPreviewable(entry))
          AgentMenuItem<FileRowAction>(
            key: const ValueKey<String>('file-menu-preview'),
            value: FileRowAction.preview,
            icon: Icons.public_rounded,
            label: '预览',
          ),
      ],
      // 复制与上面的"打开"是两组动作。目录场景这是首项，
      // 菜单组件会自动忽略首项上的分隔线，不会出现一根悬空的线。
      AgentMenuItem<FileRowAction>(
        key: const ValueKey<String>('file-menu-copy-relative'),
        value: FileRowAction.copyRelativePath,
        icon: Icons.link_rounded,
        label: '复制相对路径',
        dividerBefore: !entry.isDir,
      ),
      AgentMenuItem<FileRowAction>(
        key: const ValueKey<String>('file-menu-copy-absolute'),
        value: FileRowAction.copyAbsolutePath,
        icon: Icons.content_copy_rounded,
        label: '复制路径',
      ),
    ];
  }

  bool _isPreviewable(ProjectEntry entry) {
    if (entry.isDir) {
      return false;
    }
    final name = entry.name.toLowerCase();
    return name.endsWith('.html') || name.endsWith('.htm');
  }

  /// 单击文件行：只点亮它，不打开预览。
  ///
  /// 目录不走这里——目录的单击仍然是展开 / 收起。
  void _select(ProjectEntry entry) {
    if (entry.isDir || entry.path == _selectedPath) {
      return;
    }
    setState(() => _selectedPath = entry.path);
  }

  /// 右键某一行时按落点打开菜单。
  void _openMenu(ProjectEntry entry, Offset globalPosition) {
    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox) {
      return;
    }

    // 锚点是整个文件树，`MenuController.open(position:)` 要的是相对它的坐标。
    final local = box.globalToLocal(globalPosition);
    setState(() => _menuTarget = entry);

    // 帧末再开：`onSecondaryTapDown` 期间改 Overlay 会撞上"构建中改状态"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _menu.open(position: local);
    });
  }

  void _run(FileRowAction action) {
    final entry = _menuTarget;
    if (entry == null) {
      return;
    }

    switch (action) {
      case FileRowAction.open:
        // 打开后这一行保持点亮：选中态与"正在看的那一份"应当是同一个文件。
        setState(() => _selectedPath = entry.path);
        ref
            .read(filePaneTabProvider.notifier)
            .openPreview(path: entry.path, title: entry.name);
      case FileRowAction.preview:
        unawaited(_preview(entry));
      case FileRowAction.copyRelativePath:
        unawaited(
          _copyPath(projectRelativePath(entry.path, _rootPath), relative: true),
        );
      case FileRowAction.copyAbsolutePath:
        unawaited(_copyPath(entry.path, relative: false));
    }
  }

  /// 写剪贴板并给一句确认。
  ///
  /// `MenuItemButton` 的 `onPressed` 会推到帧末执行，回调里不再碰菜单行自己的
  /// `BuildContext`；这里只用 State 的 context，并先确认 [mounted]。
  Future<void> _copyPath(String path, {required bool relative}) async {
    final label = relative ? '相对路径' : '路径';
    try {
      await Clipboard.setData(ClipboardData(text: path));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _toast('复制$label失败：$error');
      return;
    }

    if (!mounted) {
      return;
    }
    _toast('已复制$label：$path');
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    // 连着复制两项时直接换掉上一条提示：排队会让第二条在 2 秒后才露面，
    // 看起来像"第二次没反应"。
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        // 绝对路径可能很长：最多两行，剩下的省略，免得提示条盖住半个面板。
        content: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 向服务端要一个可加载的预览地址，然后在浏览器面板里打开。
  ///
  /// 地址里有预览站的随机端口与访问令牌，客户端自己拼不出来——也不该拼。
  Future<void> _preview(ProjectEntry entry) async {
    final projectId = ref.read(shellProjectMemoProvider);
    final client = ref.read(apiClientProvider);
    if (projectId.isEmpty || client == null) {
      return;
    }

    try {
      final json = await client.getJson(
        '/api/projects/${Uri.encodeComponent(projectId)}/preview',
        query: <String, String>{'path': entry.path},
      );
      if (!mounted) {
        return;
      }

      final url = json['url'] as String?;
      final display = json['display'] as String?;
      if (url == null || url.isEmpty) {
        return;
      }

      // 文件树自己就长在面板里：窄屏不要再推一层 PanelPage，
      // 切到新开的浏览器标签就是"看到页面"。
      final wide = MediaQuery.sizeOf(context).width >= kShellBreakpoint;
      await openPreviewInPanel(
        context,
        ref,
        url: url,
        wide: wide,
        display: display,
        pushPanelOnNarrow: false,
      );
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      // 拒绝的理由（越界、不是网页、预览站没起来）必须让人看见，
      // 否则右键点了没反应，只能靠猜。
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error.userMessage)),
      );
    }
  }
}

/// 一行目录或文件。目录展开后在其下方挂子树；文件单击只选中，打开走右键菜单。
class _EntryTile extends ConsumerWidget {
  const _EntryTile({
    required this.projectId,
    required this.entry,
    required this.depth,
    required this.showHidden,
    required this.rootPath,
    required this.selectedPath,
    required this.leadInset,
    required this.onSelect,
    required this.onSecondary,
  });

  final String projectId;
  final ProjectEntry entry;
  final int depth;
  final bool showHidden;

  /// 项目根的服务端绝对路径：拖拽时要把这一行换算成相对路径。
  final String rootPath;

  /// 当前选中的文件路径。目录永远不选中。
  final String? selectedPath;

  /// 行底色块左侧的外留白：右栏有拖动条时为 0（拖动条已让出 8），
  /// 没有拖动条（聊天浮窗 / 面板全屏）时为 8。
  final double leadInset;

  /// 单击文件行：只选中，不打开预览。
  final void Function(ProjectEntry entry) onSelect;

  /// 右键某一行的回调。文件与目录都生效；目录的展开/收起仍然只占单击。
  final void Function(ProjectEntry entry, Offset globalPosition) onSecondary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded =
        entry.isDir && ref.watch(filePaneExpandedProvider).contains(entry.path);
    // 选中态是树自己的状态（单击 / 右键打开 / 切预览标签同步），不再直接
    // 把"活动预览标签"当高亮：同一时刻只该有一行亮着。
    final selected = !entry.isDir && entry.path == selectedPath;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _dragSource(
          _EntryRow(
            entry: entry,
            depth: depth,
            expanded: expanded,
            selected: selected,
            leadInset: leadInset,
            // 目录也能右键：单击负责展开 / 收起，右键只给「复制路径」两项。
            onSecondaryTapDown: (details) =>
                onSecondary(entry, details.globalPosition),
            onTap: () {
              if (entry.isDir) {
                ref.read(filePaneExpandedProvider.notifier).toggle(entry.path);
              } else {
                // 单击只点亮这一行；打开必须走右键菜单的「打开」。
                onSelect(entry);
              }
            },
          ),
        ),
        if (expanded)
          _DirectoryChildren(
            projectId: projectId,
            path: entry.path,
            depth: depth + 1,
            showHidden: showHidden,
            rootPath: rootPath,
            selectedPath: selectedPath,
            leadInset: leadInset,
            onSelect: onSelect,
            onSecondary: onSecondary,
          ),
      ],
    );
  }

  /// 把一行包成拖拽源：拖到聊天输入栏后变成一枚路径引用芯片。
  ///
  /// 桌面按下即可拖；触摸端用长按，否则在列表里一移动就变成拖拽、滚不动。
  /// `Draggable` 只认主键，不影响 `InkWell` 的单击与右键菜单。
  Widget _dragSource(Widget row) {
    final reference = ProjectPathReference(
      name: entry.name,
      relativePath: projectRelativePath(entry.path, rootPath),
      absolutePath: entry.path,
      isDir: entry.isDir,
    );
    final dragging = Opacity(opacity: 0.4, child: row);
    final feedback = _DragPreview(reference: reference);

    if (composerDesktopPlatform) {
      return Draggable<ProjectPathReference>(
        data: reference,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback,
        childWhenDragging: dragging,
        child: row,
      );
    }
    return LongPressDraggable<ProjectPathReference>(
      data: reference,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: dragging,
      child: row,
    );
  }
}

class _DirectoryChildren extends ConsumerWidget {
  const _DirectoryChildren({
    required this.projectId,
    required this.path,
    required this.depth,
    required this.showHidden,
    required this.rootPath,
    required this.selectedPath,
    required this.leadInset,
    required this.onSelect,
    required this.onSecondary,
  });

  final String projectId;
  final String path;
  final int depth;
  final bool showHidden;

  /// 项目根的服务端绝对路径，原样下传给子行用于拖拽换算。
  final String rootPath;

  /// 选中态、左留白与单击回调：原样下传，否则深层的行点不动、也亮不起来。
  final String? selectedPath;
  final double leadInset;
  final void Function(ProjectEntry entry) onSelect;

  final void Function(ProjectEntry entry, Offset globalPosition) onSecondary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = ref.watch(
      projectListingProvider((
        projectId: projectId,
        path: path,
        showHidden: showHidden,
      )),
    );

    return children.when(
      loading: () => _InlineHint('载入中…', indent: depth),
      error: (error, _) => _InlineHint(
        error is ApiException ? error.userMessage : '$error',
        indent: depth,
        isError: true,
        onTap: () => ref.invalidate(projectListingProvider),
      ),
      data: (listing) {
        if (listing.entries.isEmpty) {
          return _InlineHint('空目录', indent: depth);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final entry in listing.entries)
              _EntryTile(
                projectId: projectId,
                entry: entry,
                depth: depth,
                showHidden: showHidden,
                rootPath: rootPath,
                selectedPath: selectedPath,
                leadInset: leadInset,
                onSelect: onSelect,
                onSecondary: onSecondary,
              ),
            if (listing.truncated)
              _InlineHint('条目太多，只显示前 200 项', indent: depth),
          ],
        );
      },
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.leadInset,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  final ProjectEntry entry;
  final int depth;
  final bool expanded;
  final bool selected;

  /// 行底色块左侧的外留白，由上层按"当前有没有拖动条"算好。
  final double leadInset;

  final VoidCallback onTap;

  /// 右键按下。目录行也有菜单，只是里面只有「复制路径」两项。
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = scheme.primary;

    return Padding(
      key: const ValueKey<String>('file-row-pill'),
      // 与左栏项目 / 会话行同一套外留白：悬停底与选中底画在留白里面。
      // 左侧贴分隔线那一侧：有拖动条时它已经让出 8（`leadInset = 0`），
      // 聊天浮窗 / 面板全屏把拖动条拿掉时由这里补上 8；右侧窗口边恒留 8。
      padding: EdgeInsets.only(
        left: leadInset,
        right: kRailRowPillInset,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          // 同一行里主键走 onTap、次要键走 onSecondaryTapDown：
          // `InkWell` 自己就区分按键，不需要再包一层 GestureDetector。
          onSecondaryTapDown: onSecondaryTapDown,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          // 与左栏项目 / 会话行同一套：悬停重、选中淡，两者按需求对调过，
          // 别当笔误改回常规顺序。
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          child: Container(
            height: 30,
            // 左（贴分隔线）扣掉栏缝的 8dp；右再扣掉外层留白，
            // 文字到窗口边仍是 kPaneContentInset。
            padding: EdgeInsets.only(
              left: kPaneEdgeInset + depth * 12,
              right: kPaneContentInset - kRailRowPillInset,
            ),
            decoration: BoxDecoration(
              // 选中只换底色：不描边、不换字色 / 字重——与左栏 `_RailRow`
              // 同一份定义，侧栏里不该出现第二种选中样式。
              color: selected
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                  : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: <Widget>[
                if (entry.isDir)
                  Icon(
                    expanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
                    size: 15,
                    color: AppPalette.of(context).text.secondary,
                  )
                else
                  const SizedBox(width: 15),
                const SizedBox(width: 2),
                Icon(
                  entry.isDir ? Icons.folder_outlined : _fileIcon(entry.name),
                  size: 14,
                  color: entry.isDir
                      ? tint.withValues(alpha: 0.85)
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: AppFontSize.base,
                      // 与左栏同一条取舍：选中只靠底色表达，不加粗、不换色。
                      fontWeight: AppWeight.regular,
                      color: AppPalette.of(context).text.primary,
                    ),
                  ),
                ),
                if (!entry.isDir && entry.size != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      formatFileSize(entry.size!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: AppFontSize.xs,
                        color: AppPalette.of(context).text.tertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 只给少数常见后缀一个区分度，其余统一用文档图标。
  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.md') || lower.endsWith('.txt')) {
      return Icons.article_outlined;
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    return Icons.description_outlined;
  }
}

/// 拖动时跟着指针走的那枚小标签：与输入框里的路径芯片同一套外观。
class _DragPreview extends StatelessWidget {
  const _DragPreview({required this.reference});

  final ProjectPathReference reference;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      // Overlay 里没有现成的 Material：不套一层的话文字会丢样式。
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: PathRefChip(
          embed: PathRefEmbed(
            name: reference.name,
            relativePath: reference.relativePath,
            absolutePath: reference.absolutePath,
            isDir: reference.isDir,
          ),
        ),
      ),
    );
  }
}

class _PathToolbar extends StatelessWidget {
  const _PathToolbar({
    required this.path,
    required this.showHidden,
    required this.onRefresh,
    required this.onToggleHidden,
  });

  final String path;
  final bool showHidden;
  final VoidCallback onRefresh;
  final VoidCallback onToggleHidden;

  /// 路径行里两枚小按钮：悬停底是圆角方形，不是 Material 默认的正圆。
  /// 28 是这一行的命中区，比栏头 24 略大——它旁边是 34 高的路径行，不是标签条。
  static final ButtonStyle _pathButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(28),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: 34,
      padding: const EdgeInsets.only(
        left: kPaneEdgeInset,
        right: kPaneContentInset,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.folder_open_outlined,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(
                _shortPath(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.of(context).mono(
                  size: AppFontSize.xs,
                  height: AppLineHeight.tight,
                  color: AppPalette.of(context).text.tertiary,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: onRefresh,
            style: _pathButtonStyle,
            iconSize: 15,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: showHidden ? '隐藏 . 开头的项' : '显示隐藏文件',
            onPressed: onToggleHidden,
            style: _pathButtonStyle,
            iconSize: 15,
            isSelected: showHidden,
            icon: Icon(
              showHidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: showHidden ? scheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  /// 右栏很窄，完整路径基本放不下：只留末两段，完整值放在 Tooltip 里。
  String _shortPath(String value) {
    if (value.length <= 34) {
      return value;
    }
    final segments = value
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length <= 2) {
      return value;
    }
    return '…/${segments.sublist(segments.length - 2).join('/')}';
  }
}

class _PaneHint extends StatelessWidget {
  const _PaneHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppText.of(context).hint.copyWith(
            color: AppPalette.of(context).text.secondary,
            height: AppLineHeight.relaxed,
          ),
        ),
      ),
    );
  }
}

class _PaneError extends StatelessWidget {
  const _PaneError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.of(context).hint.copyWith(
                color: theme.colorScheme.error,
                height: AppLineHeight.relaxed,
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineHint extends StatelessWidget {
  const _InlineHint(
    this.text, {
    this.indent = 0,
    this.isError = false,
    this.onTap,
  });

  final String text;
  final int indent;
  final bool isError;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: kPaneEdgeInset + indent * 12,
          right: kPaneContentInset,
          top: 4,
          bottom: 6,
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: AppFontSize.sm,
            color: isError
                ? scheme.error
                : AppPalette.of(context).text.tertiary,
          ),
        ),
      ),
    );
  }
}
