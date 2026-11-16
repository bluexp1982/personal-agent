import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/artifact_exporter.dart';
import '../../core/design/app_palette.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../preview/image_preview_view.dart';
import 'composer_chip.dart';

/// 气泡里的附件：与输入框里那几枚同一个长相，只是不能删。
///
/// 为什么要画而不是只显示文件名：用户回头翻记录时，"我当时到底发了哪张图"
/// 是第一个问题，文件名回答不了它。图片点开可全屏看，文件点一下另存为。
class MessageAttachmentChips extends ConsumerStatefulWidget {
  const MessageAttachmentChips({super.key, required this.attachments});

  final List<MessageAttachment> attachments;

  @override
  ConsumerState<MessageAttachmentChips> createState() =>
      _MessageAttachmentChipsState();
}

class _MessageAttachmentChipsState
    extends ConsumerState<MessageAttachmentChips> {
  /// 正在取字节的那几枚：挡住连点，也让芯片能显出一个"在忙"的样子。
  final Set<String> _busy = <String>{};

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 0,
      runSpacing: 4,
      children: <Widget>[
        for (final attachment in widget.attachments)
          _chip(context, attachment),
      ],
    );
  }

  Widget _chip(BuildContext context, MessageAttachment attachment) {
    final palette = AppPalette.of(context);

    return ComposerChipFrame(
      tooltip: _tooltip(attachment),
      busy: _busy.contains(attachment.id),
      leading: Icon(
        attachment.isImage ? Icons.image_outlined : Icons.description_outlined,
        size: 11,
        color: palette.text.tertiary,
      ),
      // 用 `GestureDetector` 而不是 `InkWell`：芯片是自绘的胶囊，水波纹会溢出
      // 圆角；而且气泡外的某些宿主没有 `Material` 祖先，`InkWell` 会直接断言失败。
      label: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(attachment),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              attachment.name.isEmpty ? '附件' : attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: chipLabelStyle(context),
            ),
          ),
        ),
      ),
    );
  }

  String _tooltip(MessageAttachment attachment) {
    final type = attachment.isImage
        ? '图片'
        : (attachment.mime.isEmpty ? '文件' : attachment.mime);
    final action = attachment.isImage ? '点击查看' : '点击另存为';
    return '${attachment.name}\n$type · ${formatByteSize(attachment.bytes)}\n$action';
  }

  Future<void> _open(MessageAttachment attachment) async {
    if (_busy.contains(attachment.id)) {
      return;
    }
    final client = ref.read(apiClientProvider);
    if (client == null) {
      _notify('服务未连接');
      return;
    }

    setState(() => _busy.add(attachment.id));
    try {
      final result = await client.getBytes(
        '/api/attachments/${Uri.encodeComponent(attachment.id)}/content',
        query: attachment.isImage
            ? null
            : const <String, String>{'download': 'true'},
      );
      if (!mounted) {
        return;
      }
      if (attachment.isImage) {
        await _preview(attachment, result.bytes);
      } else {
        await _export(attachment, result.bytes);
      }
    } on ApiException catch (error) {
      _notify(error.userMessage);
    } catch (error) {
      _notify('打开失败：$error');
    } finally {
      if (mounted) {
        setState(() => _busy.remove(attachment.id));
      }
    }
  }

  Future<void> _preview(MessageAttachment attachment, Uint8List bytes) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: MobileAppBar(title: attachment.name),
          body: ImagePreviewView(path: attachment.id, bytes: bytes),
        ),
      ),
    );
  }

  Future<void> _export(MessageAttachment attachment, Uint8List bytes) async {
    try {
      final result = await ref.read(artifactExporterProvider).export(
            suggestedName: attachment.name,
            bytes: bytes,
            mime: attachment.mime,
            shareOrigin: _shareOrigin(context),
          );
      if (result.outcome == ExportOutcome.saved) {
        _notify('已保存到 ${result.path}');
      }
    } catch (error) {
      _notify('保存失败：$error');
    }
  }

  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

Rect? _shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}
