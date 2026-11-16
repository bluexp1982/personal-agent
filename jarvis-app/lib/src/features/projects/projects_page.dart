import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import 'create_project_dialog.dart';
import 'project_detail_page.dart';
import 'project_style.dart';

/// 项目列表：进入产品后的第一层。
///
/// 空状态是常态——新装用户一个项目都没有，这里必须把"项目是什么、为什么要先建"
/// 说清楚，否则用户会卡在一个只有按钮的空页面上。
class ProjectsPage extends ConsumerWidget {
  const ProjectsPage({super.key, this.topInset = 0, this.bottomInset = 0});

  /// 列表顶部额外留白。
  ///
  /// 窄屏时内容紧跟在顶栏（标题 + 标语）下面，4dp 就够；
  /// 宽屏时顶栏搬到了左侧侧栏，内容区没有东西压着，需要自己补上呼吸空间，
  /// 由 `HomeShell` 按当前布局传入。
  final double topInset;

  /// 列表底部额外留白。
  ///
  /// 窄屏底部压着悬浮导航（见 `narrow_tabs.dart`），最后一行要能滚到胶囊上方。
  /// 只在滚动内容上补，不给整页套 padding——那会把胶囊底下也垫空，
  /// 内容就透不出玻璃底了。
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);

    return projects.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorPanel(
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(projectsProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyState();
        }

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(projectsProvider),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 宽屏两列：项目是"进入某个地方"，两列比一条长列表更容易扫。
              final wide = constraints.maxWidth >= 700;
              // 两种形态的底部留白来源不同，不能相加：
              // - 宽屏没有底部导航，留白是列表自己的呼吸（96）+ 底部安全区；
              // - 窄屏由骨架传入 `kBottomNavListInset`（已含胶囊高度与下沿间距
              //   16），胶囊下沿不再随安全区上移，这里就**不再叠加安全区**，
              //   也不再叠一份 96——否则最后一行会停在离屏幕底两百多 pt 处。
              final bottom = wide
                  ? 96 + MediaQuery.paddingOf(context).bottom
                  : 32 + bottomInset;

              if (wide) {
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(20, 4 + topInset, 20, bottom),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 132,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _ProjectCard(project: items[index]),
                );
              }

              return ListView.separated(
                padding: EdgeInsets.fromLTRB(20, 4 + topInset, 20, bottom),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _ProjectCard(project: items[index]),
              );
            },
          ),
        );
      },
    );
  }
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppPalette.of(context).accent;

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: accent.projectTint.withValues(alpha: 0.22),
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: accent.projectTint.withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          hoverColor: accent.projectTint.withValues(alpha: 0.05),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProjectDetailPage(project: project),
              ),
            );
            ref.invalidate(projectsProvider);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 4,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: accent.projectGradient,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: AppFontSize.lg,
                          fontWeight: AppWeight.semiBold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 路径是这张卡里最"技术"的信息，用等宽字体显示。
                      // 不做点击复制：整张卡都是"进入项目"的命中区，路径上再叠一层
                      // 复制会在想打开项目时误触弹出一条提示。要复制走详情页的
                      // 「项目操作 → 复制路径」。
                      Text(
                        project.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.of(context).mono(
                          size: AppFontSize.sm,
                          height: AppLineHeight.tight,
                          color: AppPalette.of(context).text.tertiary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          _CountChip(
                            icon: Icons.forum_outlined,
                            label: '${project.conversationCount} 会话',
                            color: accent.projectTint,
                          ),
                          const SizedBox(width: 8),
                          _CountChip(
                            icon: Icons.task_alt,
                            label: '${project.taskCount} 任务',
                            color: accent.projectTint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              fontWeight: AppWeight.medium,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final accent = palette.accent;
    final text = AppText.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                gradient: accent.projectGradient,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: accent.projectTint.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(
                ProjectStyle.icon,
                color: palette.text.onAccent,
                size: 34,
              ),
            ),
            const SizedBox(height: 20),
            Text('还没有项目', style: text.cardTitle),
            const SizedBox(height: 8),
            Text(
              '项目绑定服务端上的一个真实目录（文档、资料、代码仓库都行）。\n'
              '会话与任务都挂在它下面，互不打扰。需要 Git 与编码任务时，'
              '新建项目时勾选「Git 仓库」即可。',
              textAlign: TextAlign.center,
              style: text.hint.copyWith(
                color: palette.text.secondary,
                height: AppLineHeight.relaxed,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => showCreateProjectDialog(context),
              icon: const Icon(Icons.add),
              label: const Text(ProjectStyle.actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
