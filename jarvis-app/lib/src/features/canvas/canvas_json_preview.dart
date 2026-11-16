import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';

/// 导出浮层里等宽文本的最大高度：再长就在里面滚，不撑破对话框。
const double kCanvasJsonMaxHeight = 360;

/// 导出浮层的宽度。够放下一行深层嵌套的 JSON，又不至于横到压住画布。
const double kCanvasJsonWidth = 560;

/// 「导出 JSON」的只读预览。
///
/// 只展示、不落盘：这是演示页，存档 / 加载要等画布真正按项目归属之后再设计，
/// 现在写文件只会多一条没人维护的本地数据。
Future<void> showCanvasJsonPreview(
  BuildContext context, {
  required String json,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _CanvasJsonDialog(json: json),
  );
}

class _CanvasJsonDialog extends StatelessWidget {
  const _CanvasJsonDialog({required this.json});

  final String json;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) {
      return;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已复制画布 JSON'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return AlertDialog(
      title: const Text('画布 JSON'),
      content: SizedBox(
        width: kCanvasJsonWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '仅预览：不写本地文件、不上传服务端',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                height: AppLineHeight.tight,
                color: palette.text.tertiary,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(
                maxHeight: kCanvasJsonMaxHeight,
              ),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
                  style: text.mono(
                    size: AppFontSize.xs,
                    color: palette.text.secondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(onPressed: () => _copy(context), child: const Text('复制')),
      ],
    );
  }
}
