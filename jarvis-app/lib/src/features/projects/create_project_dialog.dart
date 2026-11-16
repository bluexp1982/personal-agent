import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/session.dart';
import '../../core/ui/app_dialog.dart';
import 'directory_picker_dialog.dart';

/// 新建项目。返回 `true` 表示已创建（调用方负责刷新列表）。
///
/// 用居中的 [Dialog] 而不是底部抽屉：这个表单有名字、目录、Git 开关与预检结果，
/// 高度会随目录状态变化，居中在桌面端更像一个"新建对象"的窗口；
/// 右上角的关闭按钮也才有稳定的落点。
Future<bool> showCreateProjectDialog(BuildContext context) async {
  final created = await showAppDialog<bool>(
    context,
    builder: (_) => const _CreateProjectDialog(),
  );
  return created ?? false;
}

class _CreateProjectDialog extends ConsumerStatefulWidget {
  const _CreateProjectDialog();

  @override
  ConsumerState<_CreateProjectDialog> createState() =>
      _CreateProjectDialogState();
}

class _CreateProjectDialogState extends ConsumerState<_CreateProjectDialog> {
  final TextEditingController _name = TextEditingController();
  String? _path;
  bool _git = false;
  bool _submitting = false;
  String? _error;

  /// 勾选 Git 后的内部能力类型；不勾就是普通项目。
  ///
  /// 界面不再出现 CODE / WORK 字样，但接口仍以 `mode` 区分能不能派编码任务。
  String get _mode => _git ? ProjectModes.code : ProjectModes.work;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _path != null && _path!.isNotEmpty && !_submitting;

  void _toggleGit(bool value) {
    if (value == _git) {
      return;
    }
    // 两种模式的允许根目录不同（Git 走 code.allow_roots）：沿用上一个路径
    // 多半会直接越界，所以切换开关时清空已选目录与上一次的报错。
    setState(() {
      _git = value;
      _path = null;
      _error = null;
    });
  }

  Future<void> _pickDirectory() async {
    final picked = await showDirectoryPickerDialog(context, git: _git);
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _path = picked;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final client = ref.read(apiClientProvider);
    if (client == null || !_ready) {
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    // 勾了 Git 先预检：目录可能还不是能建任务分支的仓库。
    // 能让服务端现场修好的，问一句再动手——初始化会往用户目录里写 .git 与一个提交。
    var initGit = false;
    if (_git) {
      final preflight = await _loadPreflight();
      if (preflight == null) {
        return;
      }
      if (!preflight.ready) {
        if (!preflight.needsInit) {
          setState(() {
            _submitting = false;
            _error = preflight.reason ?? '这个目录不能作为 Git 项目';
          });
          return;
        }
        final confirmed = await _confirmInit(preflight);
        if (!confirmed) {
          if (mounted) {
            setState(() => _submitting = false);
          }
          return;
        }
        initGit = true;
      }
    }

    try {
      await client.postJson('/api/projects', <String, dynamic>{
        'mode': _mode,
        'path': _path,
        if (_name.text.trim().isNotEmpty) 'name': _name.text.trim(),
        if (initGit) 'init_git': true,
      });
      ref.invalidate(projectsProvider);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      // 服务端的 hint 已经是"出了什么问题 + 该怎么改"，原样展示比套一句通用文案有用。
      setState(() {
        _submitting = false;
        _error = error.userMessage;
      });
    }
  }

  /// 现取一次预检结果。失败时把原因放进 `_error` 并返回 null。
  Future<ProjectPreflight?> _loadPreflight() async {
    final client = ref.read(apiClientProvider);
    final path = _path;
    if (client == null || path == null) {
      return null;
    }
    try {
      final json = await client.getJson(
        '/api/projects/preflight',
        query: <String, String>{'mode': _mode, 'path': path},
      );
      return ProjectPreflight.fromJson(json);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = error.userMessage;
        });
      }
      return null;
    }
  }

  /// 初始化确认框。文案按 git 状态分开写：三种情况的后果不一样，不能共用一句话。
  Future<bool> _confirmInit(ProjectPreflight preflight) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('初始化这个目录？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            _initExplanation(preflight),
            style: const TextStyle(height: AppLineHeight.normal),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('初始化并创建'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  String _initExplanation(ProjectPreflight preflight) {
    final path = preflight.path;
    return switch (preflight.git) {
      GitStates.missing =>
        '$path 还不是 Git 仓库。\n\n'
            '将在该目录执行 git init（分支 main），并创建一个空提交。\n'
            '目录里已有的文件不会被提交、也不会被修改。',
      GitStates.nested =>
        '$path 属于仓库 ${preflight.gitDetail ?? '（未知）'}，但本身不是仓库根。\n\n'
            '将在这个目录里执行 git init（分支 main）并创建一个空提交，'
            '使它成为一个独立仓库；外层仓库不受影响。\n'
            '目录里已有的文件不会被提交、也不会被修改。',
      GitStates.noCommits =>
        '$path 已经是 Git 仓库，但还没有任何提交。\n\n'
            '将补一个空提交（不改动任何文件），否则编码任务建不出分支。',
      _ => preflight.reason ?? '需要初始化这个目录后才能作为 Git 项目。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return AppDialog(
      title: '新建项目',
      subtitle: Text(
        '项目绑定服务端这台电脑上的一个真实目录，会话与任务都挂在它下面。',
        style: text.hint.copyWith(color: palette.text.secondary),
      ),
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '名字（可留空）',
              hintText: '留空就用目录名',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 14),

          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: _pickDirectory,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(
                  color: _path == null
                      ? scheme.outlineVariant
                      : palette.accent.projectTint.withValues(alpha: 0.6),
                  width: _path == null ? 1 : 1.4,
                ),
                color: _path == null
                    ? Colors.transparent
                    : palette.accent.projectTint.withValues(alpha: 0.06),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _path == null
                        ? Icons.create_new_folder_outlined
                        : Icons.folder_open,
                    color: _path == null
                        ? scheme.onSurfaceVariant
                        : palette.accent.projectTint,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _path == null ? '选择服务端目录' : '已选择',
                          style: text.row.copyWith(
                            color: palette.text.secondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _path ?? (_git ? '必须是 Git 仓库根目录' : '任意目录'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: AppFontSize.base,
                            fontFamily: _path == null ? null : AppMono.family,
                            fontFamilyFallback: _path == null
                                ? null
                                : AppMono.fallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Git 能力是项目的一个选项，而不是"另一种项目"：开关行与
          // 「编辑配置」里的「支持读图」同款，勾上之后才出现仓库校验与初始化流程。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: palette.text.tertiary,
            ),
            title: Text('Git 仓库', style: text.row),
            subtitle: Text('可派编码任务、使用分支与提交；目录必须是仓库根', style: text.meta),
            value: _git,
            onChanged: _toggleGit,
          ),

          const SizedBox(height: 10),
          Text(
            _git
                ? 'Git 项目要求目录是 Git 仓库根（含 .git、有提交、不在游离 HEAD），'
                      '并且落在服务端 code.allow_roots 内。'
                : '不勾选 Git 时只要求目录存在；这里没有任何 Git 操作。',
            style: text.hint.copyWith(color: palette.text.secondary),
          ),

          // 选好目录就能看到它是"可用仓库 / 待初始化 / 用不了"，不必等到点创建才失败。
          if (_git && _path != null) ...<Widget>[
            const SizedBox(height: 10),
            _PreflightLine(
              state: ref.watch(
                projectPreflightProvider((mode: _mode, path: _path!)),
              ),
            ),
          ],

          if (_error != null) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                  height: AppLineHeight.normal,
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _ready ? _submit : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('创建项目'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 预检结果的一行提示：可用 / 待初始化 / 用不了。
class _PreflightLine extends StatelessWidget {
  const _PreflightLine({required this.state});

  final AsyncValue<ProjectPreflight> state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    Widget line(Color color, IconData icon, String message) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: text.meta.copyWith(
                color: color,
                height: AppLineHeight.code,
              ),
            ),
          ),
        ],
      );
    }

    return state.when(
      loading: () => Row(
        children: <Widget>[
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '正在检查这个目录…',
            style: text.meta.copyWith(color: palette.text.secondary),
          ),
        ],
      ),
      error: (error, _) => line(
        scheme.error,
        Icons.error_outline,
        error is ApiException ? error.userMessage : '$error',
      ),
      data: (preflight) {
        if (preflight.ready) {
          final branch = preflight.gitDetail;
          return line(
            scheme.primary,
            Icons.check_circle_outline,
            branch == null || branch.isEmpty
                ? '这个目录可以直接用作 Git 项目'
                : '已是 Git 仓库（分支 $branch），可以直接使用',
          );
        }
        if (preflight.needsInit) {
          return line(
            AppPalette.of(context).status.warning,
            Icons.warning_amber_rounded,
            '${preflight.reason ?? '这个目录还不是可用的仓库'}；创建前会先问你一次。',
          );
        }
        return line(
          scheme.error,
          Icons.block,
          preflight.reason ?? '这个目录不能作为 Git 项目',
        );
      },
    );
  }
}
