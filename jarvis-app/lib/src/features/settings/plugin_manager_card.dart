import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/capability_revision.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import 'settings_widgets.dart';

/// 设置页的「技能包」卡片。
///
/// 只列**插件**：内置技能随应用发布，不需要装也不能卸，列出来只是噪音。
/// 空态里会说明这一点，避免用户以为技能列表是空的。
///
/// 三态徽标是这张卡片的重点：`unsupported` 的技能依赖本机没有的工具
/// （Bash、写文件），装上去了也跑不了——必须在这里说清原因，
/// 而不是让它出现在新建任务下拉里、点进去产出幻觉。
class PluginManagerCard extends ConsumerStatefulWidget {
  const PluginManagerCard({super.key});

  @override
  ConsumerState<PluginManagerCard> createState() => _PluginManagerCardState();
}

class _PluginManagerCardState extends ConsumerState<PluginManagerCard> {
  PluginPage _page = PluginPage.empty;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '还没连上服务端';
        });
      }
      return;
    }

    try {
      final page = await client.listPlugins();
      if (!mounted) {
        return;
      }
      setState(() {
        _page = page;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _install() async {
    const typeGroup = XTypeGroup(
      label: '技能包',
      extensions: <String>['zip'],
    );

    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null || !mounted) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      _toast('还没连上服务端');
      return;
    }

    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final page = await client.installPlugin(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _page = page;
        _busy = false;
      });
      // 让 `@` 候选、任务页下拉这些地方重新拉技能清单——否则它们停在
      // 首次加载的结果上，用户只看到"设置里装了，聊天里没有"。
      ref.read(capabilityRevisionProvider.notifier).bump();
      _toast('已安装 ${file.name}');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _toast(_message(error));
    }
  }

  Future<void> _toggle(PluginInfo plugin, bool enabled) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    // 先乐观更新：开关是高频操作，等一次往返再变会显得卡。
    final previous = _page;
    setState(() {
      _page = PluginPage(
        pendingReload: _page.pendingReload || !enabled,
        items: _page.items
            .map(
              (item) => item.id == plugin.id
                  ? PluginInfo(
                      id: item.id,
                      name: item.name,
                      version: item.version,
                      enabled: enabled,
                      author: item.author,
                      description: item.description,
                      skills: item.skills,
                    )
                  : item,
            )
            .toList(growable: false),
      );
    });

    try {
      final page = await client.setPluginEnabled(plugin.id, enabled);
      if (!mounted) {
        return;
      }
      setState(() => _page = page);
      ref.read(capabilityRevisionProvider.notifier).bump();
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 回滚：失败后界面停在"已切换"是最容易误导人的状态。
      // 这里**不 bump**——清单没变，让消费方白刷一次只是浪费。
      setState(() => _page = previous);
      _toast(_message(error));
    }
  }

  Future<void> _remove(PluginInfo plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('卸载技能包？'),
        content: Text(
          '「${plugin.name}」提供的技能会立即从新建任务中消失；'
          '正在跑的任务不受影响。',
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
            child: const Text('卸载'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      await client.deletePlugin(plugin.id);
      await _reload();
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ref.read(capabilityRevisionProvider.notifier).bump();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _toast(_message(error));
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _message(Object error) {
    if (error is ApiException) {
      return error.userMessage;
    }
    return '$error';
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsCardHeader(
            icon: Icons.extension_outlined,
            title: '安装技能包',
            subtitle: const SettingsDescription(
              '选择 .zip 技能包，装完不用重启应用。'
              'Claude Code、Codex 的合规技能包可以直接装。',
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_circle_outline, size: 18),
            enabled: !_busy,
            onTap: _busy ? null : _install,
          ),
          if (_page.pendingReload) ...<Widget>[
            const Divider(height: 1),
            SettingsBanner(
              icon: Icons.schedule,
              message: '已生效，但有任务在跑：执行进程空闲后才会重新加载技能',
              color: AppPalette.of(context).status.warning,
            ),
          ],
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                _error!,
                style: text.meta.copyWith(
                  color: AppPalette.of(context).status.danger,
                ),
              ),
            )
          else if (_page.items.isEmpty)
            _empty(context)
          else
            ..._page.items.map((plugin) => _pluginSection(context, plugin)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.extension_outlined,
            size: 28,
            color: palette.text.tertiary,
          ),
          const SizedBox(height: 8),
          Text(
            '还没有安装技能包。技能随包一起提供，装完不用重启应用。',
            textAlign: TextAlign.center,
            style: text.hint,
          ),
          const SizedBox(height: 4),
          Text(
            '内置技能（出行方案、账单解读）随应用发布，不需要安装。',
            textAlign: TextAlign.center,
            style: text.meta,
          ),
        ],
      ),
    );
  }

  Widget _pluginSection(BuildContext context, PluginInfo plugin) {
    final palette = AppPalette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Divider(height: 1),
        SettingsSwitchRow(
          icon: plugin.enabled ? Icons.inventory_2_outlined : Icons.inventory_2,
          title: plugin.name,
          description:
              '${plugin.version}${plugin.author.isEmpty ? '' : ' · ${plugin.author}'}'
              ' · ${plugin.skills.length} 个技能',
          value: plugin.enabled,
          onChanged: _busy ? null : (value) => _toggle(plugin, value),
        ),
        ...plugin.skills.map((skill) => _skillRow(context, skill)),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
            child: TextButton.icon(
              onPressed: _busy ? null : () => _remove(plugin),
              style: TextButton.styleFrom(
                foregroundColor: palette.status.danger,
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('卸载'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _skillRow(BuildContext context, SkillInfo skill) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(skill.name, style: text.row)),
              const SizedBox(width: 8),
              _riskBadge(context, skill.riskLevel),
              const SizedBox(width: 6),
              _statusBadge(context, skill.support),
            ],
          ),
          if (skill.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(skill.description, style: text.meta),
            ),
          // 不支持或降级时必须说清原因：用户看到"不支持"却不知道为什么，
          // 下一步只能去翻日志。
          ...skill.reasons.map(
            (reason) => Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                reason,
                style: text.meta.copyWith(
                  color: skill.support == SkillSupport.unsupported
                      ? palette.status.danger
                      : palette.status.warning,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _riskBadge(BuildContext context, String riskLevel) {
    final palette = AppPalette.of(context);
    final (label, color) = switch (riskLevel) {
      'irreversible_write' => ('不可逆', palette.status.danger),
      'reversible_write' => ('可撤销', palette.status.warning),
      _ => ('只读', palette.status.success),
    };
    return SettingsTag(label: label, color: color);
  }

  Widget _statusBadge(BuildContext context, SkillSupport support) {
    final palette = AppPalette.of(context);
    final color = switch (support) {
      SkillSupport.supported => palette.status.neutral,
      SkillSupport.degraded => palette.status.warning,
      SkillSupport.unsupported => palette.status.danger,
    };
    return SettingsTag(label: support.label, color: color);
  }
}
