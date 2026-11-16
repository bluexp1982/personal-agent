import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_models.dart';

/// 录音状态用什么色。
///
/// **正常态的强调走主题强调色，不借 `status.success` / `info`**：那两档在多数
/// 主题包里是绿/蓝，借来当"已转写""转写中"的标记，换到暖纸、琥珀或靛蓝主题
/// 后整页会留下一块与主题无关的绿。黄（待转写、部分失败）与红（录音中、
/// 转写失败）仍走状态语义——异常必须一眼可读，这两种颜色是刻意"跳出主题"的。
///
/// 列表页与详情页共用这一处映射，避免改一处漏一处。
Color recordingStatusColor(RecordingStatus status, AppPalette palette) =>
    switch (status) {
      RecordingStatus.recording => palette.status.danger,
      RecordingStatus.recorded => palette.status.warning,
      RecordingStatus.transcribing => palette.accent.projectStart,
      RecordingStatus.ready => palette.accent.projectStart,
      RecordingStatus.partial => palette.status.warning,
      RecordingStatus.failed => palette.status.danger,
    };

/// 录音状态胶囊。底与描边都必须由同一个状态色派生（见 UI 规范）。
class RecordingStatusChip extends StatelessWidget {
  const RecordingStatusChip({
    super.key,
    required this.label,
    required this.color,
    this.compact = false,
  });

  final String label;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppPalette.of(context).status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: AppPalette.of(context).status.borderOf(color),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: AppText.of(context).badge.copyWith(color: color),
      ),
    );
  }
}
