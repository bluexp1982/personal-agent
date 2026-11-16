import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_models.dart';
import '../shell/shell_layout_state.dart';
import 'recording_navigation.dart';
import 'recording_waveform.dart';

/// 全局录音状态条。
///
/// 录音不随页面销毁，用户切到项目/终端后仍然需要知道"还在录"，
/// 并且要能一键回去或结束。挂在 `HomeShell` 的骨架层。
class RecordingMiniBar extends ConsumerWidget {
  const RecordingMiniBar({super.key, this.wide = false});

  /// 宽屏有中栏：回到录音页 / 去详情都在中栏原地切换；
  /// 窄屏没有中栏，仍整页推入。
  final bool wide;

  void _openSession(BuildContext context, WidgetRef ref) {
    if (wide) {
      ref
          .read(shellTargetProvider.notifier)
          .select(const RecordingSessionTarget());
      return;
    }
    unawaited(openRecordingSession(context));
  }

  Future<void> _openDetail(
    BuildContext context,
    WidgetRef ref,
    LocalRecording recording,
  ) async {
    if (wide) {
      ref
          .read(shellTargetProvider.notifier)
          .select(RecordingDetailTarget(local: recording));
      return;
    }
    await openRecordingDetail(context, local: recording);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordingControllerProvider);
    if (!session.active) {
      return const SizedBox.shrink();
    }

    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final color = session.paused
        ? palette.status.warning
        : palette.status.danger;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        elevation: 8,
        shadowColor: Theme.of(context).colorScheme.shadow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _openSession(context, ref),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: palette.status.borderOf(color)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.fiber_manual_record, size: 12, color: color),
                const SizedBox(width: 8),
                Text(
                  session.paused ? '已暂停' : '正在录音',
                  style: text.row.copyWith(fontWeight: AppWeight.medium),
                ),
                const SizedBox(width: 12),
                Text(formatElapsed(session.elapsedMs), style: text.mono()),
                const SizedBox(width: 8),
                // 5 根迷你柱：离开录音页也能感到"还在收音"。只跟 levels 走，
                // 不引入动画控制器，避免整个外壳跟着每帧重建。
                SizedBox(
                  width: 34,
                  height: 16,
                  child: RecordingWaveform(
                    levels: session.levels,
                    color: color,
                    height: 16,
                    active: !session.paused,
                    slots: 5,
                    barWidth: 2,
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => _openSession(context, ref),
                  child: const Text('打开'),
                ),
                IconButton(
                  tooltip: '停止并保存',
                  onPressed: () async {
                    final recording = await ref
                        .read(recordingControllerProvider.notifier)
                        .stop();
                    if (recording != null && context.mounted) {
                      await _openDetail(context, ref, recording);
                    }
                  },
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
