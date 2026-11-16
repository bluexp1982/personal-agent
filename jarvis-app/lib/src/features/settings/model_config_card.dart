import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/model_providers.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import 'model_edit_dialog.dart';
import 'settings_widgets.dart';

/// 设置页的「模型」卡片。
///
/// 用户在这里维护多份第三方模型配置，并指定其中一份生效。切换后对话、任务、
/// 记忆抽取、录音摘要下一轮全部跟着换，不需要重启服务。
///
/// 卡片自己持有列表状态（与技能包卡片一致）：设置页其它部分与它无关，
/// 没必要把一次列表请求提到页面级 provider 上。
class ModelConfigCard extends ConsumerStatefulWidget {
  const ModelConfigCard({super.key});

  @override
  ConsumerState<ModelConfigCard> createState() => _ModelConfigCardState();
}

class _ModelConfigCardState extends ConsumerState<ModelConfigCard> {
  ModelListView _view = ModelListView.empty;
  bool _loading = true;
  String? _error;

  /// 正在切换的配置 id：只让那一行显示进度，别让整张卡片转圈。
  String? _activating;

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
      final view = await client.listModels();
      if (!mounted) {
        return;
      }
      setState(() {
        _view = view;
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

  Future<void> _activate(ModelProfileView profile) async {
    final client = ref.read(apiClientProvider);
    if (client == null || _activating != null) {
      return;
    }

    setState(() => _activating = profile.id);
    try {
      final switched = await client.activateModel(profile.id);
      await _reload();
      if (!mounted) {
        return;
      }
      setState(() => _activating = null);
      // 切过去了但用不了（缺密钥、地址空）必须当场说清：否则用户会以为
      // 自己选了新模型，实际回答已经退回确定性实现。
      if (!switched.available) {
        _toast('已切换到「${switched.name}」，但它现在不可用：${switched.reason ?? '原因未知'}');
      } else {
        _toast('已切换为「${switched.name}」');
      }
      invalidateModels(ref);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _activating = null);
      _toast(_message(error));
    }
  }

  Future<void> _test(ModelProfileView profile) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }
    _toast('正在测试「${profile.name}」…');
    try {
      final result = await client.testModel(id: profile.id);
      _toast('${profile.name}：${result.userText}');
    } catch (error) {
      _toast(_message(error));
    }
  }

  Future<void> _openEditor([ModelProfileView? existing]) async {
    final changed = await showModelEditDialog(context, existing: existing);
    if (changed == true && mounted) {
      await _reload();
      invalidateModels(ref);
    }
  }

  Future<void> _delete(ModelProfileView profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这份模型配置？'),
        content: Text(
          profile.active
              ? '「${profile.name}」是当前生效的配置。删除后会回落到默认配置，'
                    '之后所有对话与任务都改用默认模型。服务端保存的密钥会一并删除。'
              : '「${profile.name}」及其密钥会从服务端删除，不影响其它配置。',
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

    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }
    try {
      await client.deleteModel(profile.id);
      await _reload();
      if (!mounted) {
        return;
      }
      if (profile.active) {
        _toast('已删除「${profile.name}」，当前模型回落到默认配置');
      } else {
        _toast('已删除「${profile.name}」');
      }
      invalidateModels(ref);
    } catch (error) {
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
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final active = _view.active;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsCardHeader(
            icon: Icons.hub_outlined,
            title: '模型',
            subtitle: _headerSubtitle(context, palette, text, active),
          ),
          if (!_view.persisted && !_loading) ...<Widget>[
            const Divider(height: 1),
            SettingsBanner(
              icon: Icons.schedule,
              message: '服务端没有配置文件：本次改动只在当前进程内生效，重启后会丢',
              color: palette.status.warning,
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
                style: text.meta.copyWith(color: palette.status.danger),
              ),
            )
          else
            ..._view.models.map((profile) => _profileRow(context, profile)),
          const Divider(height: 1),
          InkWell(
            onTap: () => _openEditor(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                children: <Widget>[
                  Icon(Icons.add, size: 18, color: palette.text.tertiary),
                  const SizedBox(width: 8),
                  Text(
                    '新增配置',
                    style: text.row.copyWith(
                      fontWeight: AppWeight.medium,
                      color: palette.text.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerSubtitle(
    BuildContext context,
    AppPalette palette,
    AppText text,
    ModelProfileView? active,
  ) {
    if (active == null) {
      return Text(
        _loading ? '读取中…' : '还没有可用的模型配置',
        style: text.meta,
      );
    }

    final dot = active.available ? palette.status.success : palette.status.danger;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              active.displayModel.isEmpty
                  ? '当前：${active.name}'
                  : '当前：${active.name} · ${active.displayModel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.meta.copyWith(
                color: active.available
                    ? palette.text.tertiary
                    : palette.status.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileRow(BuildContext context, ModelProfileView profile) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final switching = _activating == profile.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Divider(height: 1),
        Container(
          // 当前项行首一道强调色竖条：比整行着色更轻，也不会和悬停底打架。
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 2,
                color: profile.active ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.row.copyWith(
                                fontWeight: AppWeight.medium,
                              ),
                            ),
                          ),
                          if (profile.active) ...<Widget>[
                            const SizedBox(width: 6),
                            SettingsTag(label: '当前', color: scheme.primary),
                          ],
                          if (!profile.enabled) ...<Widget>[
                            const SizedBox(width: 6),
                            SettingsTag(
                              label: '已停用',
                              color: palette.status.neutral,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        profile.summaryLine,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.mono(
                          size: AppFontSize.sm,
                          height: AppLineHeight.normal,
                          color: palette.text.tertiary,
                        ),
                      ),
                      if (!profile.available) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          profile.reason ?? '不可用',
                          style: text.meta.copyWith(
                            color: palette.status.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (switching)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 10, 8, 0),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  _rowMenu(context, profile),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _rowMenu(BuildContext context, ModelProfileView profile) {
    return AgentMenu<String>(
      width: AgentMenuStyle.panelMinWidth,
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(
        AgentMenuStyle.panelMinWidth,
      ),
      // 触发器是自带 onPressed 的 IconButton：组件只管开合，否则一次点击既开又关。
      triggerHandlesTap: false,
      groups: <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          items: <AgentMenuItem<String>>[
            AgentMenuItem<String>(
              value: 'activate',
              label: '设为当前',
              icon: Icons.check_circle_outline,
              enabled: !profile.active,
              key: Key('model-activate-${profile.id}'),
            ),
            AgentMenuItem<String>(
              value: 'test',
              label: '测试连接',
              icon: Icons.network_check,
              key: Key('model-test-${profile.id}'),
            ),
            AgentMenuItem<String>(
              value: 'edit',
              label: '编辑',
              icon: Icons.edit_outlined,
              key: Key('model-edit-${profile.id}'),
            ),
            AgentMenuItem<String>(
              value: 'delete',
              label: '删除',
              icon: Icons.delete_outline,
              enabled: !profile.builtin,
              key: Key('model-delete-${profile.id}'),
              dividerBefore: true,
            ),
          ],
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'activate':
            _activate(profile);
          case 'test':
            _test(profile);
          case 'edit':
            _openEditor(profile);
          case 'delete':
            _delete(profile);
        }
      },
      builder: (context, controller, open, hovering) => IconButton(
        key: Key('model-menu-${profile.id}'),
        tooltip: '更多操作',
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_horiz),
      ),
    );
  }

}
