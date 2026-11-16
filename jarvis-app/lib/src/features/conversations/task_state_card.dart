import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';

/// 会话里通过 `@技能` 派出的一项任务。
///
/// 与「建议卡」的区别：建议卡是模型提议、带 `reason`；这里是用户自己选的技能，
/// 带的是"参数没解析出来哪些字段"。两者共用同一套状态色，文案各说各的事。
class AtTaskView {
  AtTaskView({required this.key, required this.skill});

  /// 本地标识（`at:<时间戳>:<技能>`），同一技能连发两次也不冲突。
  final String key;
  final String skill;

  /// `creating` / `created` / `failed`
  String state = 'creating';

  /// 服务端建出来的任务；`creating` 与 `failed` 时为空。
  TaskView? task;

  /// 派单失败时的可读原因（`ApiException.userMessage`）。
  ///
  /// 不放进 toast：toast 几秒就消失，而"为什么没派出去"是用户会反复看的信息。
  String? error;

  /// 技能声明需要、这次没解析出来的字段（`url` / `city` / `pattern` …）。
  List<String> missing = const <String>[];
}

/// 任务状态卡：一行标题 + 状态徽标，必要时补一句原因。
class AtTaskCard extends StatelessWidget {
  const AtTaskCard({super.key, required this.entry, required this.onOpen});

  final AtTaskView entry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    final (label, color) = _status(entry, palette);

    return Material(
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: entry.task == null ? null : onOpen,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.assignment_outlined,
                    size: 14,
                    color: palette.text.tertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已派出：${entry.skill}',
                      style: text.row.copyWith(fontWeight: AppWeight.medium),
                    ),
                  ),
                  _pill(context, label, color),
                  if (entry.task != null) ...<Widget>[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: palette.text.tertiary,
                    ),
                  ],
                ],
              ),
              if (_note(entry, palette) case final note?) ...<Widget>[
                const SizedBox(height: 6),
                Text(note.$1, style: text.meta.copyWith(color: note.$2)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 状态文案与配色。每一步都按"用户此刻该关心什么"取色，不做装饰。
  (String, Color) _status(AtTaskView entry, AppPalette palette) {
    if (entry.state == 'creating') {
      return ('创建中', palette.text.tertiary);
    }
    if (entry.state == 'failed') {
      return ('失败', palette.status.danger);
    }

    final task = entry.task;
    if (task == null) {
      return ('已派出', palette.status.neutral);
    }

    return switch (task.state) {
      'queued' => ('排队中', palette.status.neutral),
      'running' => ('执行中', palette.status.info),
      'needs_approval' || 'needs_input' => ('等你确认', palette.status.warning),
      'succeeded' => ('已完成', palette.status.success),
      'canceled' => ('已取消', palette.status.neutral),
      _ => ('失败', palette.status.danger),
    };
  }

  /// 需要额外说一句时的文案与颜色；不需要返回 null。
  ///
  /// 优先级：失败原因 > 参数缺口。两者都可能存在，但一次只说最要紧的那句。
  (String, Color)? _note(AtTaskView entry, AppPalette palette) {
    if (entry.state == 'failed') {
      final reason = entry.error;
      return (
        reason == null
            ? '没派出去：可以重试，或到任务页手动派'
            : '没派出去：$reason',
        palette.status.danger,
      );
    }

    final task = entry.task;
    if (task != null && task.state == 'failed' && task.errorHint != null) {
      return (task.errorHint!, palette.status.danger);
    }

    if (entry.missing.isNotEmpty) {
      final fields = entry.missing.map(_fieldLabel).join('、');
      return (
        '没解析出$fields，技能可能读不到资料；可以直接把内容贴进来，或在任务页手动填',
        palette.status.warning,
      );
    }

    return null;
  }

  static String _fieldLabel(String field) => switch (field) {
    'url' => '网址',
    'city' => '城市',
    'query' => '关键词',
    'path' => '路径',
    'pattern' => '匹配模式',
    _ => field,
  };

  Widget _pill(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppFontSize.xs,
          height: AppLineHeight.tight,
          fontWeight: AppWeight.medium,
          color: color,
        ),
      ),
    );
  }
}
