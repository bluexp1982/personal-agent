import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/models.dart';
import 'artifact_card.dart';

/// 生成文件产物卡片。
///
/// 与图片 / 视频共用 [ArtifactCard] 外壳：图标 + 标题 + 状态胶囊 + 等宽路径 +
/// `落点 · 大小` + 备份/过期附加行 + 右下动作区。
///
/// 待确认（目标已存在）时给两个按钮：覆盖 / 取消。服务端已经把待写内容落库，
/// 点一下就能完成写入，不需要模型再参与一轮。
///
/// 「打开」由调用方按落点与类型决定要不要给（草案里的非网页文件打不开），
/// 这里只按 `onOpen == null` 置灰/隐藏，不做类型判断——类型规则属于会话页。
class FileWriteArtifactCard extends StatelessWidget {
  const FileWriteArtifactCard({
    super.key,
    required this.write,
    this.busy = false,
    this.onDecide,
    this.onOpen,
    this.onSave,
  });

  final FileWriteView write;

  /// 决策请求进行中：按钮置灰，避免连点产生两次写入。
  final bool busy;

  final void Function(FileWriteView write, bool approve)? onDecide;

  /// 打开预览（为空表示这个文件不可预览）。
  final ValueChanged<FileWriteView>? onOpen;

  /// 另存到本机（为空表示不可保存）。
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final status = _statusOf(palette);
    final expiry = _expiryHint();

    return ArtifactCard(
      icon: write.isPending
          ? Icons.file_present_outlined
          : Icons.insert_drive_file_outlined,
      title: write.isPending ? '要覆盖已有文件' : '生成文件',
      chip: ArtifactStatusChip(label: status.label, color: status.color),
      primaryLine: write.path,
      detailLine: _detailLine(),
      extraLines: <String>[
        if (write.backupPath case final backup?) '原文件已备份：$backup',
        ?expiry,
      ],
      tone: write.isPending ? palette.status.warning : null,
      actions: _actions(),
    );
  }

  /// 「会话草稿 · 3.2 KB」；覆盖时说清两边大小。
  String _detailLine() {
    final location = write.scopeLabel;
    if (write.existingBytes > 0 && write.isPending) {
      return '$location · 原 ${formatFileSize(write.existingBytes)} → '
          '新 ${formatFileSize(write.bytes)}';
    }
    return '$location · ${formatFileSize(write.bytes)}';
  }

  /// 过一个时间点就作废的提示。不在卡片里跑定时器：
  /// 用户停留多久都只是显示"还剩几分钟"，真正失效由服务端判定。
  String? _expiryHint() {
    if (!write.isPending) {
      return null;
    }
    final expiresAt = write.expiresAt;
    if (expiresAt == null || expiresAt <= 0) {
      return null;
    }
    final left = expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      return '已过期，请重新生成';
    }
    final minutes = (left / 60000).ceil();
    return '$minutes 分钟内有效';
  }

  List<Widget> _actions() {
    if (write.isPending) {
      return <Widget>[
        OutlinedButton(
          onPressed: busy || onDecide == null
              ? null
              : () => onDecide!(write, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy || onDecide == null
              ? null
              : () => onDecide!(write, true),
          child: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('覆盖'),
        ),
      ];
    }

    if (!write.isWritten) {
      return const <Widget>[];
    }

    // 顺序与图片 / 视频卡一致：保存在前、打开在后（打开是主操作，靠右收尾）。
    return <Widget>[
      if (onSave != null)
        ArtifactActionButton(
          key: kFileSaveKey,
          icon: Icons.save_alt,
          label: '保存',
          onPressed: onSave,
        ),
      if (onOpen != null)
        ArtifactActionButton(
          key: kFileOpenKey,
          icon: kArtifactOpenIcon,
          label: '打开',
          onPressed: () => onOpen!(write),
        ),
    ];
  }

  ({String label, Color color}) _statusOf(AppPalette palette) {
    return switch (write.status) {
      'written' => (label: '已写入', color: palette.status.success),
      'pending' => (label: '待确认覆盖', color: palette.status.warning),
      'rejected' => (label: '已取消', color: palette.status.neutral),
      'expired' => (label: '已过期', color: palette.status.neutral),
      'failed' => (label: '写入失败', color: palette.status.danger),
      _ => (label: '已被替代', color: palette.status.neutral),
    };
  }
}

/// 文件卡动作的稳定锚点。
const Key kFileOpenKey = Key('artifact-file-open');
const Key kFileSaveKey = Key('artifact-file-save');
