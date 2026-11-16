import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/git_models.dart';
import '../shell/shell_layout_state.dart';

/// 三组变更列表：已暂存 / 更改 / 未跟踪。
///
/// 一个文件可以同时出现在前两组（暂存后又改了一笔），这不是 bug 而是 git 的语义：
/// 两组看的是不同的东西（索引相对 HEAD、工作区相对索引），合并展示只会让
/// "我现在提交会带上什么"这件事变得不可判断。
class GitChangeList extends StatelessWidget {
  const GitChangeList({
    super.key,
    required this.status,
    required this.busy,
    required this.onSelect,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
  });

  final GitStatusReport status;

  /// 有写操作在飞：所有行内动作一起禁用，避免连点堆出两次 add。
  final bool busy;

  /// 点一行看 diff。[staged] 决定看暂存区还是工作区。
  final void Function(GitFileChange change, bool staged) onSelect;

  final void Function(List<String> paths) onStage;
  final void Function(List<String> paths) onUnstage;

  /// 撤销。调用方负责二次确认——不可恢复的动作不该由列表组件弹框。
  final void Function(List<String> paths) onDiscard;

  @override
  Widget build(BuildContext context) {
    if (status.isClean) {
      return _CleanState(hasCommits: status.head != null);
    }

    // 展开成"标题 + 行"的平铺序列交给 `ListView.builder`：
    // 一次大重构之后变更能有几千条，一次性建完所有行会把面板卡住。
    final entries = <_Entry>[
      if (status.staged.isNotEmpty) ...<_Entry>[
        _Entry.header('已暂存', status.staged.length),
        for (final change in status.staged)
          _Entry.change(change, staged: true, group: _Group.staged),
      ],
      if (status.unstaged.isNotEmpty) ...<_Entry>[
        _Entry.header('更改', status.unstaged.length),
        for (final change in status.unstaged)
          _Entry.change(change, staged: false, group: _Group.unstaged),
      ],
      if (status.untracked.isNotEmpty) ...<_Entry>[
        _Entry.header('未跟踪', status.untracked.length),
        for (final change in status.untracked)
          _Entry.change(change, staged: false, group: _Group.untracked),
      ],
    ];

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final header = entry.header;
        if (header != null) {
          return _SectionHeader(title: header, count: entry.count ?? 0);
        }

        final change = entry.change!;
        return _ChangeRow(
          change: change,
          busy: busy,
          // 「撤销」只对 HEAD 里有的文件有意义：未跟踪与新加文件撤销不了
          // （服务端也不会删它们），按钮干脆不出现，免得点了才知道不行。
          canDiscard:
              change.state != GitFileState.untracked &&
              change.state != GitFileState.added &&
              change.state != GitFileState.unmerged,
          canStage: entry.group != _Group.staged,
          canUnstage: entry.group == _Group.staged,
          onTap: () => onSelect(change, entry.staged),
          onStage: () => onStage(<String>[change.path]),
          onUnstage: () => onUnstage(<String>[change.path]),
          onDiscard: () => onDiscard(<String>[change.path]),
        );
      },
    );
  }
}

/// 列表里的一项：标题或文件行。
class _Entry {
  const _Entry._({
    this.header,
    this.count,
    this.change,
    this.staged = false,
    this.group = _Group.unstaged,
  });

  factory _Entry.header(String title, int count) =>
      _Entry._(header: title, count: count);

  factory _Entry.change(
    GitFileChange change, {
    required bool staged,
    required _Group group,
  }) => _Entry._(change: change, staged: staged, group: group);

  final String? header;
  final int? count;
  final GitFileChange? change;
  final bool staged;
  final _Group group;
}

enum _Group { staged, unstaged, untracked }

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset + 2,
        10,
        kPaneContentInset,
        4,
      ),
      child: Text(
        '$title $count',
        style: TextStyle(
          fontSize: AppFontSize.sm,
          fontWeight: AppWeight.semiBold,
          letterSpacing: AppLetterSpacing.tight,
          color: palette.text.tertiary,
        ),
      ),
    );
  }
}

/// 一个文件行：状态徽标 + 文件名（目录）+ 悬停浮出的动作。
class _ChangeRow extends StatefulWidget {
  const _ChangeRow({
    required this.change,
    required this.busy,
    required this.canDiscard,
    required this.canStage,
    required this.canUnstage,
    required this.onTap,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
  });

  final GitFileChange change;
  final bool busy;
  final bool canDiscard;
  final bool canStage;
  final bool canUnstage;
  final VoidCallback onTap;
  final VoidCallback onStage;
  final VoidCallback onUnstage;
  final VoidCallback onDiscard;

  @override
  State<_ChangeRow> createState() => _ChangeRowState();
}

class _ChangeRowState extends State<_ChangeRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final color = _stateColor(palette, widget.change.state);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: _hovering
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
            : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              kPaneEdgeInset + 2,
              3,
              kPaneContentInset - 4,
              3,
            ),
            child: Row(
              children: <Widget>[
                _StateBadge(state: widget.change.state, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          widget.change.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppFontSize.base,
                            color: palette.text.primary,
                          ),
                        ),
                      ),
                      if (widget.change.directory.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            widget.change.directory,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppFontSize.xs,
                              color: palette.text.tertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 动作按钮常驻槽位、只切换透明度：悬停时插入按钮会让文件名
                // 被挤窄、整行抖一下（与标签栏关闭叉同一处理）。
                AnimatedOpacity(
                  opacity: _hovering || widget.busy ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hovering || widget.busy,
                    child: Row(
                      children: <Widget>[
                        if (widget.canStage)
                          _RowAction(
                            tooltip: '暂存',
                            icon: Icons.add_rounded,
                            onTap: widget.onStage,
                          ),
                        if (widget.canUnstage)
                          _RowAction(
                            tooltip: '取消暂存',
                            icon: Icons.remove_rounded,
                            onTap: widget.onUnstage,
                          ),
                        if (widget.canDiscard)
                          _RowAction(
                            tooltip: '撤销改动',
                            icon: Icons.undo_rounded,
                            color: palette.status.danger,
                            onTap: widget.onDiscard,
                          ),
                      ],
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

  static Color _stateColor(AppPalette palette, GitFileState state) {
    return switch (state) {
      GitFileState.modified => palette.status.warning,
      GitFileState.added || GitFileState.untracked => palette.status.success,
      GitFileState.deleted || GitFileState.unmerged => palette.status.danger,
      GitFileState.renamed || GitFileState.copied => palette.status.info,
      GitFileState.typeChanged => palette.status.neutral,
    };
  }
}

/// 状态徽标：单字母 + 低饱和底，颜色与 diff 的增删着色同源。
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state, required this.color});

  final GitFileState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        state.badge,
        style: TextStyle(
          fontFamily: AppMono.family,
          fontFamilyFallback: AppMono.fallback,
          fontSize: AppFontSize.xs,
          fontWeight: AppWeight.bold,
          height: AppLineHeight.tight,
          color: color,
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(20),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      iconSize: 13,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(icon),
    );
  }
}

/// 工作区干净：这既是空态也是好消息，不该画成"没数据"。
class _CleanState extends StatelessWidget {
  const _CleanState({required this.hasCommits});

  /// 还没有任何提交的仓库，"干净"其实是"还没开始"。
  final bool hasCommits;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          16,
          kPaneContentInset,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.check_circle_outline_rounded,
              size: 26,
              color: palette.status.success,
            ),
            const SizedBox(height: 10),
            Text(
              hasCommits ? '工作区干净' : '还没有任何提交',
              style: TextStyle(
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.semiBold,
                color: palette.text.secondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hasCommits ? '没有待暂存或待提交的改动' : '新建的文件会出现在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: palette.text.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
