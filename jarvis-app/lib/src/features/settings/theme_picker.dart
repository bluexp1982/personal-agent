import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_theme_spec.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/theme_mode.dart';
import '../../core/theme_packs.dart';
import 'settings_widgets.dart';

/// 主题四段选择器，以及选中「个性主题」时原位展开的主题包面板。
///
/// 自绘而不是用 `SegmentedButton`：四个中文标签在 360dp 上会被它压缩到溢出，
/// Material 默认的方块样式也与本应用的胶囊风格不一致。
class ThemePicker extends ConsumerWidget {
  const ThemePicker({super.key});

  /// 顺序即展示顺序：内置主题在前、个性主题在最后。
  ///
  /// 「浅色 / 深色」就是两个内置主题——它们的行为与改造前完全一致，
  /// 只是从"模式"变成了"主题清单里的前两项"。
  static const List<(ThemeChoice, String)> options = <(ThemeChoice, String)>[
    (ThemeChoice.system, '跟随系统'),
    (ThemeChoice.light, '浅色'),
    (ThemeChoice.dark, '深色'),
    (ThemeChoice.custom, '个性主题'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(themeSelectionProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              for (final (choice, label) in options)
                Expanded(
                  child: _ThemeSegment(
                    label: label,
                    selected: choice == selection.choice,
                    onTap: () => ref
                        .read(themeSelectionProvider.notifier)
                        .selectMode(choice),
                  ),
                ),
            ],
          ),
        ),
        // 原位展开而不是弹层：选主题时用户想同时看到"当前有哪些包可用"。
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: selection.choice == ThemeChoice.custom
              ? const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: ThemePackPanel(),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  const _ThemeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          // 竖向 11 + 14px 字，命中高度约 40dp，配合外层 4px padding 已足够手指点。
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.semiBold,
                color: selected
                    ? scheme.onPrimary
                    : AppPalette.of(context).text.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 已安装主题包列表 + 安装入口 + 失效提示。
class ThemePackPanel extends ConsumerStatefulWidget {
  const ThemePackPanel({super.key});

  @override
  ConsumerState<ThemePackPanel> createState() => _ThemePackPanelState();
}

class _ThemePackPanelState extends ConsumerState<ThemePackPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _install() async {
    const typeGroup = XTypeGroup(
      label: '主题包',
      extensions: <String>['zip'],
    );

    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null || !mounted) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await file.readAsBytes();
      final page = await ref
          .read(themePacksProvider.notifier)
          .install(bytes);
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      // 装完直接切过去：用户选文件的意图就是"用这个主题"。
      final installed = page.items.isEmpty ? null : page.items.first;
      if (installed != null) {
        await ref.read(themeSelectionProvider.notifier).selectTheme(installed);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _select(AppThemeSpec spec) async {
    await ref.read(themeSelectionProvider.notifier).selectTheme(spec);
  }

  Future<void> _remove(AppThemeSpec spec) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除主题包？'),
        content: Text(
          '「${spec.name}」会从所有已配对设备上消失；'
          '如果正在使用，界面会回落到跟随系统。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.of(context).status.danger,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _busy = true);
    try {
      final page = await ref
          .read(themePacksProvider.notifier)
          .remove(spec.id);
      if (!mounted) {
        return;
      }
      // 删掉的正是当前主题：平滑回落到跟随系统，而不是留着一个"个性主题"
      // 标签却没有任何颜色可用。
      final selection = ref.read(themeSelectionProvider);
      if (selection.themeId == spec.id && page.byId(spec.id) == null) {
        await ref.read(themeSelectionProvider.notifier).clearCustom();
      }
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _message(error);
      });
    }
  }

  String _message(Object error) {
    if (error is ApiException) {
      return error.userMessage;
    }
    return '$error';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final packs = ref.watch(themePacksProvider);
    final selection = ref.watch(themeSelectionProvider);
    final page = packs.asData?.value ?? ThemePage.empty;
    // 一次都没成功过才算"加载失败"：失败后重试成功过就有值，不该继续报错。
    final loadFailed = packs.hasError && packs.asData?.value == null;
    final gone = selection.isCustom &&
        selection.themeId != null &&
        packs.hasValue &&
        page.byId(selection.themeId) == null;

    if (packs.isLoading && !packs.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (gone) ...<Widget>[
          SettingsBanner(
            icon: Icons.link_off,
            message: '当前主题已失效（服务端上已删除），仍在用本地缓存着色；'
                '重新选一个主题或删掉它即可',
            color: palette.status.warning,
            boxed: true,
          ),
          const SizedBox(height: 8),
        ],
        if (loadFailed) ...<Widget>[
          SettingsBanner(
            icon: Icons.cloud_off,
            message: '主题包列表加载失败；当前主题仍按本地缓存显示，稍后可重开此页重试',
            color: palette.status.warning,
            boxed: true,
          ),
          const SizedBox(height: 8),
        ],
        if (_error != null) ...<Widget>[
          SettingsBanner(
            icon: Icons.error_outline,
            message: _error!,
            color: palette.status.danger,
            boxed: true,
          ),
          const SizedBox(height: 8),
        ],
        if (page.items.isEmpty && !loadFailed)
          const _EmptyState()
        else if (page.items.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              // 宽屏两列：主题卡信息量小，单列会在 720dp 上留出大段空白。
              final columns = constraints.maxWidth >= 560 ? 2 : 1;
              final width = columns == 1
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  for (final spec in page.items)
                    SizedBox(
                      width: width,
                      child: _ThemeCard(
                        spec: spec,
                        selected: selection.themeId == spec.id,
                        busy: _busy,
                        onTap: _busy ? null : () => _select(spec),
                        onDelete: _busy ? null : () => _remove(spec),
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 12),
        _InstallButton(onTap: _busy ? null : _install, busy: _busy),
        const SizedBox(height: 4),
        Text(
          '主题包是一个含 theme.json 的 zip：可改主色、文字灰阶、状态色、'
          '代码高亮、消息与终端配色。圆角与字号不开放。',
          style: text.meta,
        ),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.spec,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onDelete,
  });

  final AppThemeSpec spec;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: BoxDecoration(
            // 选中底与卡片列表同一口径：主色 8% 预乘到卡底上，不叠第二层半透明。
            color: selected
                ? Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.08),
                    scheme.surfaceContainerLowest,
                  )
                : scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      spec.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.row.copyWith(
                        fontWeight: AppWeight.medium,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String>[
                        if (spec.author.isNotEmpty) spec.author,
                        'v${spec.version}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.meta,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _BrightnessBadge(brightness: spec.brightness),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.check, size: 16, color: scheme.primary),
                ),
              IconButton(
                tooltip: '删除主题包',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: busy ? null : onDelete,
                icon: Icon(Icons.delete_outline, color: palette.text.tertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主题卡的「深色 / 浅色」标签：尺寸与设置页其它标签同源。
class _BrightnessBadge extends StatelessWidget {
  const _BrightnessBadge({required this.brightness});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dark = brightness == Brightness.dark;
    return SettingsTag(
      label: dark ? '深色' : '浅色',
      color: dark ? palette.status.neutral : palette.status.info,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Icon(Icons.palette_outlined, size: 28, color: palette.text.tertiary),
          const SizedBox(height: 8),
          Text(
            '还没有安装主题包',
            textAlign: TextAlign.center,
            style: text.row.copyWith(
              fontWeight: AppWeight.medium,
              color: palette.text.secondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '主题包是一个含 theme.json 的 zip，'
            '装上之后就会出现在这里，点一下即可换肤。',
            textAlign: TextAlign.center,
            style: text.hint,
          ),
        ],
      ),
    );
  }
}

class _InstallButton extends StatelessWidget {
  const _InstallButton({required this.onTap, required this.busy});

  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: scheme.outlineVariant),
            color: scheme.surfaceContainerLowest,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (busy) ...<Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('正在安装…', style: text.rowSecondary),
              ] else ...<Widget>[
                Icon(Icons.add, size: 16, color: palette.text.secondary),
                const SizedBox(width: 6),
                Text(
                  '安装主题包（.zip）',
                  style: text.row.copyWith(
                    fontWeight: AppWeight.medium,
                    color: palette.text.secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
