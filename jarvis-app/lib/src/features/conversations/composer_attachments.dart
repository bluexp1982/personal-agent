import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/models.dart';
import 'attachment_embed.dart';
import 'composer_menus.dart';
import 'composer_text.dart';

/// 单枚附件的字节上限。与服务端 `attachment.max_bytes` 的默认值一致。
///
/// 两边各判一次不是重复劳动：客户端先拦是为了"选完立刻告诉用户不行"，
/// 服务端再判是因为只信客户端等于没有边界。
const int kAttachmentMaxBytes = 20 * 1024 * 1024;

/// 一条消息的附件数量上限。与服务端 `attachment.max_count` 一致。
const int kAttachmentMaxCount = 8;

/// 同时上传几个附件。
///
/// 2 是"别把上行带宽全占满"与"多选十张图别排到天荒地老"之间的折中；
/// 桌面端多选一批截图时，用户能看着它们两两变成缩略图。
const int _uploadConcurrency = 2;

/// 缩略图小图宽度（像素）。芯片里画 14dp，2x 屏给到 28 就够，取 56 留余量。
const int _thumbWidth = 56;

/// 输入栏的附件入口：三条来源共用同一套校验、上传与插入流程。
///
/// 为什么是一个普通类而不是 widget：它没有任何视觉，全是"读文件 → 校验 →
/// 插入芯片 → 后台上传 → 原地替换"这条流程；绑在 widget 上反而要为三处回调
/// 各开一个 State。输入栏持有它，芯片删除时回调它清服务端那份。
class ComposerAttachmentIntake {
  ComposerAttachmentIntake({
    required this.controller,
    required this.clientOf,
    required this.notify,
  });

  /// 附件芯片写进哪个文档。读写一律走 `composer_text.dart` 的助手。
  final QuillController controller;

  /// 当前 API 客户端。延迟取：登录完成前它可能是 null。
  final ApiClient? Function() clientOf;

  /// 面向用户的一句话（容量超限、上传失败等）。
  final void Function(String message) notify;

  final Queue<_UploadJob> _queue = Queue<_UploadJob>();
  int _active = 0;
  int _localSeq = 0;

  /// 「+」菜单里的「文件」：系统文件选择器，可多选。
  Future<void> pickFiles() async {
    try {
      final files = await openFiles();
      if (files.isEmpty) {
        return;
      }
      await addFiles(files);
    } catch (error) {
      notify('打开文件选择器失败：$error');
    }
  }

  /// 「+」菜单里的「粘贴图片」：移动端没有 Cmd/Ctrl+V 的按键事件，走这里。
  Future<void> pasteImage() async {
    final clipboard = await _readClipboard();
    if (clipboard.text != null && clipboard.text!.trim().isNotEmpty) {
      // 图文都有时按文本粘贴处理：用户多半是在粘一段话，
      // 顺手把剪贴板里的旧图也贴进来会很意外。
      notify('剪贴板里是文字，请直接粘贴到输入框');
      return;
    }
    if (clipboard.image != null) {
      await _addBytes(
        name: _pastedName(clipboard.imageMime),
        mime: clipboard.imageMime,
        bytes: clipboard.image!,
      );
      return;
    }
    // 桌面端能拿到"在文件管理器里复制的文件"的真实路径；
    // Android 拿到的是 `content://` URI，`XFile` 读不了，跳过这一支。
    if (composerDesktopPlatform && clipboard.files.isNotEmpty) {
      await addFiles(
        clipboard.files.map((path) => XFile(path)).toList(growable: false),
      );
      return;
    }
    notify('剪贴板里没有图片或文件');
  }

  /// 键盘 Cmd/Ctrl+V：只在"剪贴板里是图片、且没有文字"时接管。
  ///
  /// 有文字时不碰——让 quill 走它自己的粘贴路径，富文本、换行、
  /// 语法高亮的处理都比我们转一手强。
  Future<void> pasteFromShortcut() async {
    final clipboard = await _readClipboard();
    if (clipboard.text != null && clipboard.text!.trim().isNotEmpty) {
      return;
    }
    if (clipboard.image != null) {
      await _addBytes(
        name: _pastedName(clipboard.imageMime),
        mime: clipboard.imageMime,
        bytes: clipboard.image!,
      );
    }
  }

  /// 系统拖入的文件。
  Future<void> addDropped(DropDoneDetails details) async {
    await addFiles(details.files);
  }

  /// 逐个校验并加入。任一枚超限只跳过它自己，不影响同一批的其他文件。
  Future<void> addFiles(List<XFile> files) async {
    for (final file in files) {
      await _addFile(file);
    }
  }

  /// 用户点了芯片上的 X：文档那边已经删了节点，这里清服务端那份。
  ///
  /// 失败只记日志：文件留在盘上由服务端按 TTL 清，不该弹一个用户无从处理的错误。
  Future<void> discard(AttachmentEmbed embed) async {
    final id = embed.id;
    if (id.isEmpty) {
      return;
    }
    await _deleteRemote(id);
  }

  Future<void> _addFile(XFile file) async {
    final name = file.name.trim().isEmpty ? '附件' : file.name.trim();
    int size;
    try {
      size = await file.length();
    } catch (error) {
      notify('读不到 $name：$error');
      return;
    }
    if (size <= 0) {
      notify('$name 是空文件');
      return;
    }
    if (size > kAttachmentMaxBytes) {
      notify('$name 超过 ${formatByteSize(kAttachmentMaxBytes)}，未添加');
      return;
    }

    try {
      final bytes = await file.readAsBytes();
      await _addBytes(
        name: name,
        mime: _guessMime(name, file.mimeType),
        bytes: bytes,
      );
    } catch (error) {
      notify('读不到 $name：$error');
    }
  }

  /// 插入芯片并排队上传。字节已经在内存里，芯片立刻可见。
  Future<void> _addBytes({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      notify('$name 是空文件');
      return;
    }
    if (bytes.length > kAttachmentMaxBytes) {
      notify('$name 超过 ${formatByteSize(kAttachmentMaxBytes)}，未添加');
      return;
    }
    if (attachmentEmbeds(controller).length >= kAttachmentMaxCount) {
      notify('一条消息最多带 $kAttachmentMaxCount 个附件');
      return;
    }

    final kind = mime.startsWith('image/') ? 'image' : 'file';
    final probe = kind == 'image' ? await _probeImage(bytes) : null;

    _localSeq += 1;
    final embed = AttachmentEmbed(
      localId: 'local-${DateTime.now().microsecondsSinceEpoch}-$_localSeq',
      name: name,
      kind: kind,
      mime: mime,
      bytes: bytes.length,
      width: probe?.width,
      height: probe?.height,
      thumbBase64: probe?.thumb,
    );

    insertAttachmentEmbed(controller, embed);
    _queue.add(_UploadJob(embed: embed, bytes: bytes));
    _pump();
  }

  void _pump() {
    while (_active < _uploadConcurrency && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active += 1;
      unawaited(
        _upload(job).whenComplete(() {
          _active -= 1;
          _pump();
        }),
      );
    }
  }

  Future<void> _upload(_UploadJob job) async {
    final client = clientOf();
    if (client == null) {
      _fail(job.embed, '服务未连接');
      return;
    }

    final embed = job.embed;
    try {
      final json = await client.postBytes(
        '/api/attachments',
        job.bytes,
        contentType: embed.mime,
        query: <String, String>{
          'name': embed.name,
          if (embed.width != null) 'w': '${embed.width}',
          if (embed.height != null) 'h': '${embed.height}',
        },
      );
      final uploaded = MessageAttachment.fromJson(json);
      if (uploaded.id.isEmpty) {
        _fail(embed, '服务端没有返回附件 id');
        return;
      }

      final replaced = replaceAttachmentEmbed(
        controller,
        embed.localId,
        embed.complete(id: uploaded.id),
      );
      if (!replaced) {
        // 上传期间用户把芯片删了：刚传上去的那份没人引用，顺手清掉。
        await _deleteRemote(uploaded.id);
      }
    } on ApiException catch (error) {
      _fail(embed, error.userMessage);
    } catch (error) {
      _fail(embed, '上传失败：$error');
    }
  }

  void _fail(AttachmentEmbed embed, String reason) {
    final replaced = replaceAttachmentEmbed(
      controller,
      embed.localId,
      embed.failed(reason),
    );
    if (!replaced) {
      // 芯片已经不在了（用户等不及删掉）：不必再打扰他。
      return;
    }
    notify('${embed.name}：$reason');
  }

  Future<void> _deleteRemote(String id) async {
    final client = clientOf();
    if (client == null) {
      return;
    }
    try {
      await client.delete('/api/attachments/${Uri.encodeComponent(id)}');
    } on ApiException {
      // 已绑定到消息（409）或已被清理（404）都无所谓：文件的去留由服务端决定。
    } catch (_) {
      // 网络问题同理：不该因为一次清理失败打断用户。
    }
  }

  /// 解码出原图尺寸与一张小缩略图。
  ///
  /// 用 `ImageDescriptor` 先读尺寸再降采样：先整张解码一张 4K 截图会吃掉几十 MB，
  /// 而输入框里只需要一枚 14dp 的小方块。
  Future<({String thumb, int? width, int? height})?> _probeImage(
    Uint8List bytes,
  ) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      codec = await descriptor.instantiateCodec(targetWidth: _thumbWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        return null;
      }
      return (
        thumb: base64Encode(data.buffer.asUint8List()),
        width: width,
        height: height,
      );
    } catch (_) {
      // 解不出来的图片照样能上传：芯片退回文档图标即可，
      // 不必因为一张格式怪的图挡住用户。
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  String _pastedName(String mime) {
    final stamp = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final ext = switch (mime) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    return '粘贴的图片 ${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}.$ext';
  }
}

/// 一次待上传。
class _UploadJob {
  const _UploadJob({required this.embed, required this.bytes});

  final AttachmentEmbed embed;
  final Uint8List bytes;
}

/// 剪贴板里与附件有关的三样东西。
typedef _Clipboard = ({
  String? text,
  Uint8List? image,
  String imageMime,
  List<String> files,
});

/// 读剪贴板。任何一项读失败都按"没有"处理：剪贴板是外部状态，读不到不该报错。
Future<_Clipboard> _readClipboard() async {
  String? text;
  Uint8List? image;
  List<String> files = const <String>[];
  try {
    text = await Pasteboard.text;
  } catch (_) {
    text = null;
  }
  try {
    image = await Pasteboard.image;
  } catch (_) {
    image = null;
  }
  try {
    files = await Pasteboard.files();
  } catch (_) {
    files = const <String>[];
  }
  return (
    text: text,
    image: image,
    imageMime: image == null ? 'image/png' : _sniffImageMime(image),
    files: files,
  );
}

/// 按文件头判断图片格式。
///
/// 剪贴板接口只给字节、不给 mime；猜错会让气泡里的 `<img>` 用错解码器，
/// 也会让服务端按错误的 `content-type` 回给客户端。
String _sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  // 认不出来就按 PNG 报：解码失败时输入框会退回文档图标，
  // 而错标成 image/png 至少还能让服务端把它当图片存。
  return 'image/png';
}

/// 由扩展名猜 mime。拖拽与选择器给的 `mimeType` 经常是 null 或
/// `application/octet-stream`，只认它会把 `.md` 当二进制。
String _guessMime(String name, String? declared) {
  final trimmed = declared?.trim() ?? '';
  if (trimmed.isNotEmpty && !trimmed.startsWith('application/octet-stream')) {
    return trimmed;
  }
  final ext = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'pdf' => 'application/pdf',
    'md' || 'markdown' => 'text/markdown',
    'txt' || 'log' || 'csv' => 'text/plain',
    'json' => 'application/json',
    'yaml' || 'yml' => 'application/yaml',
    'toml' => 'application/toml',
    'html' || 'htm' => 'text/html',
    'css' => 'text/css',
    'js' => 'application/javascript',
    'ts' || 'tsx' || 'jsx' => 'application/typescript',
    'dart' || 'rs' || 'py' || 'go' || 'java' || 'kt' || 'swift' || 'c' ||
    'h' || 'cpp' || 'sh' => 'text/plain',
    _ => 'application/octet-stream',
  };
}
