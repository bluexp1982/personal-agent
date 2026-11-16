import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/ui/app_dialog.dart';

/// 选择服务端目录，返回选中的绝对路径；取消返回 `null`。
///
/// 它叠在「新建项目」上面，而不是 push 一整页：目录只是那张表单里的一个格子，
/// 跳页会把已经填好的名字、Git 开关一起藏起来，回来还得重新确认一遍。
///
/// 目录在**服务端那台电脑**上，客户端看不到文件系统，所以只能一层层浏览。
/// 能进哪些目录由服务端决定（Git 项目走 `code.allow_roots`，普通项目走 `project.browse_roots`），
/// 客户端不做任何越界判断——「面包屑」也只是把服务端给的路径切段。
Future<String?> showDirectoryPickerDialog(
  BuildContext context, {
  required bool git,
}) {
  return showAppDialog<String>(
    context,
    builder: (_) => _DirectoryPickerDialog(git: git),
  );
}

class _DirectoryPickerDialog extends ConsumerStatefulWidget {
  const _DirectoryPickerDialog({required this.git});

  /// 是否在为新项目勾选「Git 仓库」：决定白名单与标题文案。
  final bool git;

  @override
  ConsumerState<_DirectoryPickerDialog> createState() =>
      _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState
    extends ConsumerState<_DirectoryPickerDialog> {
  String get _mode => widget.git ? ProjectModes.code : ProjectModes.work;

  /// 当前目录；`null` 表示"还没选，从允许的第一个根开始"。
  String? _path;

  void _enter(String path) => setState(() => _path = path);

  @override
  Widget build(BuildContext context) {
    final listing = ref.watch(dirListingProvider((mode: _mode, path: _path)));

    final current = listing.value?.path ?? _path;
    final parent = listing.value?.parent;

    // 弹窗高度固定在一个区间里而不是跟着内容长：翻目录时列表条数会跳变，
    // 高度若跟着变，底部的「使用此目录」会一上一下跑。
    final maxHeight = (MediaQuery.sizeOf(context).height - 96).clamp(
      320.0,
      560.0,
    );

    return AppDialog(
      title: widget.git ? '选择仓库目录' : '选择目录',
      // 返回箭头与关闭钮左右各一枚，标题居中才是真的居中。
      titleAlign: TextAlign.center,
      leading: IconButton(
        tooltip: '上一级',
        onPressed: parent == null ? null : () => _enter(parent),
        style: kAppDialogIconButtonStyle,
        icon: const Icon(Icons.chevron_left, size: 20),
      ),
      maxWidth: 560,
      maxHeight: maxHeight,
      // 列表自己吃满剩余高度，底部按钮贴底、不参与滚动。
      scrollable: false,
      actions: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: FilledButton.icon(
          onPressed: current == null || current.isEmpty
              ? null
              : () => Navigator.of(context).pop(current),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.check),
          label: Text(
            current == null || current.isEmpty
                ? '使用此目录'
                : '使用此目录（${_tail(current)}）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 翻目录时只换一条 2dp 进度条，不把内容换成转圈：
          // 上一层结果还在屏幕上，能看清自己在往哪走。
          if (listing.isLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: listing.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorPanel(
                message: error is ApiException ? error.userMessage : '$error',
                onReset: () => setState(() => _path = null),
              ),
              data: (data) => _Listing(
                data: data,
                git: widget.git,
                onEnter: _enter,
                onRefresh: () async => ref.invalidate(
                  dirListingProvider((mode: _mode, path: _path)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _tail(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

class _Listing extends StatelessWidget {
  const _Listing({
    required this.data,
    required this.git,
    required this.onEnter,
    required this.onRefresh,
  });

  final DirListing data;
  final bool git;
  final ValueChanged<String> onEnter;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = AppText.of(context).hint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Crumbs(data: data, onJump: onEnter),
        // 多个根时给一排入口；只有一个根就不重复显示——它已经在面包屑里了。
        if (data.roots.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final root in data.roots)
                  ChoiceChip(
                    label: Text(_tail(root)),
                    labelStyle: AppText.of(context).row,
                    selected: _isInside(data.path, root),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => onEnter(root),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
              children: <Widget>[
                for (final entry in data.entries)
                  _EntryTile(entry: entry, onTap: () => onEnter(entry.path)),
                if (data.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: <Widget>[
                        Icon(
                          Icons.folder_off_outlined,
                          size: 32,
                          color: AppPalette.of(context).text.tertiary,
                        ),
                        const SizedBox(height: 10),
                        Text('这个目录下没有可选的子目录', style: hint),
                        if (git) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            '当前目录本身就能作为 Git 项目，直接点下面的按钮即可。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppPalette.of(context).text.tertiary,
                              height: AppLineHeight.normal,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static bool _isInside(String path, String root) =>
      path == root || path.startsWith('$root/');

  static String _tail(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

class _Crumbs extends StatelessWidget {
  const _Crumbs({required this.data, required this.onJump});

  final DirListing data;
  final ValueChanged<String> onJump;

  @override
  Widget build(BuildContext context) {
    final crumbs = data.crumbs();
    if (crumbs.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => Icon(
          Icons.chevron_right,
          size: 14,
          color: Theme.of(context).colorScheme.outline,
        ),
        itemBuilder: (context, index) {
          final crumb = crumbs[index];
          final last = index == crumbs.length - 1;
          final palette = AppPalette.of(context);
          final accent = palette.accent;
          return Center(
            child: TextButton(
              onPressed: last ? null : () => onJump(crumb.path),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: last ? accent.projectTint : null,
              ),
              child: Text(
                crumb.label,
                style: AppText.of(context).meta.copyWith(
                  fontWeight: last ? AppWeight.bold : AppWeight.medium,
                  color: last ? accent.projectTint : palette.text.secondary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final DirEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      leading: Icon(
        entry.isRepo ? Icons.account_tree_outlined : Icons.folder_outlined,
        color: entry.isRepo
            ? palette.accent.projectTint
            : palette.text.secondary,
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.of(context).row,
            ),
          ),
          if (entry.isRepo) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.accent.projectTint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Text(
                'Git',
                style: AppText.of(context).badge
                    .copyWith(color: palette.accent.projectTint),
              ),
            ),
          ],
        ],
      ),
      trailing: Icon(
        Icons.subdirectory_arrow_right,
        size: 18,
        color: palette.text.tertiary,
      ),
      onTap: onTap,
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onReset});

  final String message;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.folder_off_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onReset, child: const Text('回到根目录')),
          ],
        ),
      ),
    );
  }
}
