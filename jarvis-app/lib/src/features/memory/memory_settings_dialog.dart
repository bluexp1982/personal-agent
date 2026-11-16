import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/design/app_tokens.dart';
import '../../core/memory/memory_models.dart';
import '../../core/memory/memory_providers.dart';
import 'memory_navigation.dart';

/// 记忆设置：静音类别、每日打扰上限、常驻摘要开关。
///
/// 用居中的 [Dialog] 而不是底部抽屉：与「新建项目」同一套弹窗形态——
/// 标题 + 说明 + 内容 + 底部主按钮，桌面端鼠标够得着，右上角也有稳定的关闭落点。
Future<void> showMemorySettingsDialog(BuildContext context) {
  return showAppDialog<void>(
    context,
    builder: (_) => const _MemorySettingsDialog(),
  );
}

class _MemorySettingsDialog extends ConsumerStatefulWidget {
  const _MemorySettingsDialog();

  @override
  ConsumerState<_MemorySettingsDialog> createState() =>
      _MemorySettingsDialogState();
}

class _MemorySettingsDialogState extends ConsumerState<_MemorySettingsDialog> {
  final Set<NotificationCategory> _mute = <NotificationCategory>{};
  int _dailyLimit = 2;
  bool _digestEnabled = true;
  bool _loaded = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final state = ref.watch(memoryStateProvider).value;

    if (!_loaded && state != null) {
      // 首次拿到快照时同步一次本地状态；之后以本地为准，避免每帧回写。
      _loaded = true;
      _dailyLimit = state.heartbeat.dailyLimit;
    }

    return AppDialog(
      title: '记忆设置',
      subtitle: Text(
        '助手什么时候可以打断你、常驻摘要要不要带上，都在这里调。',
        style: AppText.of(context).hint
            .copyWith(color: AppPalette.of(context).text.secondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        // 标题行搬进 `AppDialog` 之后，正文不再需要为 40 宽的关闭钮让出
        // 右侧 10：四周统一 20，与另外两个表单弹窗一致。
        children: <Widget>[
          Text('不打扰的类别', style: text.row),
          const SizedBox(height: 4),
          Text('静音的类别仍然记录，只是不投递', style: text.hint),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final category in NotificationCategory.values)
                _chip(
                  label: category.label,
                  selected: _mute.contains(category),
                  onTap: () => setState(() {
                    if (!_mute.remove(category)) {
                      _mute.add(category);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('每天最多打扰', style: text.row),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final value in <int>[0, 1, 2, 3, 5])
                _chip(
                  label: value == 0 ? '不打扰' : '$value 条',
                  selected: _dailyLimit == value,
                  onTap: () => setState(() => _dailyLimit = value),
                ),
            ],
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _digestEnabled,
            onChanged: (value) => setState(() => _digestEnabled = value),
            title: Text('常驻记忆摘要', style: text.row),
            subtitle: Text('每轮对话前注入画像、偏好与近期事件', style: text.hint),
          ),
          const Divider(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined, size: 18),
            title: Text('执行授权', style: text.row),
            subtitle: Text('撤销后下一次同类操作会重新询问', style: text.hint),
            onTap: () {
              Navigator.of(context).pop();
              openGrantsPage(context);
            },
          ),

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(label, style: text.row),
      ),
    );
  }

  Future<void> _save() async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await api.updateSettings(
        mute: _mute.toList(),
        dailyLimit: _dailyLimit,
        digestEnabled: _digestEnabled,
      );
      ref.invalidate(memoryStateProvider);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.hint)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
