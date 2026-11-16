import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_settings.dart';

/// 首次进入录音模块的一次性告知。
///
/// 不做成"每次录音都弹"：那样用户会条件反射点同意，反而失去告知意义。
/// 读过之后常驻入口在页面顶部横幅与设置页，随时可改。
Future<bool> showRecordingPrivacySheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _PrivacyDialog(ref: ref),
  );
  if (result == null) {
    return false;
  }
  await ref.read(recordingPreferencesProvider.notifier).markDisclosureSeen();
  return result;
}

class _PrivacyDialog extends StatelessWidget {
  const _PrivacyDialog({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return AlertDialog(
      title: Text('录音会先留在这台电脑', style: text.section),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Point(
              icon: Icons.mic_none_outlined,
              title: '音频默认只存本地',
              body: '按静音断句分段保存，随时可以在详情页删除；不上传也能正常录音与播放。',
              color: palette.status.info,
            ),
            const SizedBox(height: 16),
            _Point(
              icon: Icons.cloud_off_outlined,
              title: '上传需要你显式打开',
              body: '开关默认关闭。关着的时候录音不会产生任何网络请求，界面会标「仅本地」。',
              color: palette.status.warning,
            ),
            const SizedBox(height: 16),
            _Point(
              icon: Icons.translate_outlined,
              title: '转写会把音频发给模型厂商',
              body: '开启后，音频经你的服务端转发给 ASR 厂商；转写稿存回服务端，音频作归档。',
              color: palette.status.danger,
            ),
            const SizedBox(height: 20),
            Text('这个开关在「设置 → 录音」里随时可以关掉；关掉后已上传的内容不受影响。', style: text.hint),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            await ref
                .read(recordingPreferencesProvider.notifier)
                .setUploadEnabled(false);
            if (context.mounted) {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text('先只存本地'),
        ),
        FilledButton(
          onPressed: () async {
            await ref
                .read(recordingPreferencesProvider.notifier)
                .setUploadEnabled(true);
            if (context.mounted) {
              Navigator.of(context).pop(true);
            }
          },
          child: const Text('允许上传转写'),
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: palette.status.surfaceOf(color),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: text.row.copyWith(fontWeight: AppWeight.medium),
              ),
              const SizedBox(height: 4),
              Text(body, style: text.hint),
            ],
          ),
        ),
      ],
    );
  }
}
