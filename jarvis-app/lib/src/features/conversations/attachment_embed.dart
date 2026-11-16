import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import 'composer_chip.dart';
import 'embed_node_edit.dart';

/// 输入框里的一枚附件芯片（quill 的 embed 节点）。
///
/// 与 [SkillEmbed] 同构：data 是 JSON 字符串，渲染、删除都靠节点自身。
/// 不同之处是它有**上传状态**——用户拖进来的那一刻就出现，上传成功后原地换成
/// 带服务端 id 的那一枚。这样"文件已经在输入框里"与"文件已经传上去"是两件事，
/// 后者慢的时候界面不会什么都不发生。
///
/// [localId] 是上传期间的唯一身份：id 还是空串时靠它定位并替换这一枚。
class AttachmentEmbed extends Embeddable {
  AttachmentEmbed({
    required this.localId,
    required this.name,
    required this.kind,
    required this.mime,
    required this.bytes,
    this.id = '',
    this.width,
    this.height,
    this.thumbBase64,
    this.uploading = true,
    this.error,
  }) : super(attachmentEmbedType, jsonEncode(_payload(
          localId: localId,
          id: id,
          name: name,
          kind: kind,
          mime: mime,
          bytes: bytes,
          width: width,
          height: height,
          thumbBase64: thumbBase64,
          uploading: uploading,
          error: error,
        )));

  /// 节点类型。带前缀避免与 quill 内置的 image/video 撞名。
  static const String attachmentEmbedType = 'personal-agent-attachment';

  final String localId;

  /// 服务端 id。上传中为空串——空串就意味着"还不能发送"。
  final String id;
  final String name;
  final String kind;
  final String mime;
  final int bytes;
  final int? width;
  final int? height;

  /// 图片缩略图（PNG 的 base64）。只用于输入框里那一枚小图标。
  ///
  /// 存进节点而不是另挂状态：节点会被 quill 复制、拆分、重建，
  /// 旁挂的 Map 一旦漏同步，缩略图就会变成空白方块。
  final String? thumbBase64;

  final bool uploading;

  /// 上传失败的原因（面向用户）。非空时芯片标红。
  final String? error;

  bool get isImage => kind == 'image';

  /// 上传完成、可以被发送。
  bool get ready => !uploading && error == null && id.isNotEmpty;

  Uint8List? get thumbBytes {
    final raw = thumbBase64;
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      return base64Decode(raw);
    } on FormatException {
      return null;
    }
  }

  /// 上传成功后换出的那枚。
  AttachmentEmbed complete({required String id}) {
    return AttachmentEmbed(
      localId: localId,
      id: id,
      name: name,
      kind: kind,
      mime: mime,
      bytes: bytes,
      width: width,
      height: height,
      thumbBase64: thumbBase64,
      uploading: false,
    );
  }

  /// 上传失败后换出的那枚：保留缩略图与名字，标红并说明原因。
  AttachmentEmbed failed(String reason) {
    return AttachmentEmbed(
      localId: localId,
      id: id,
      name: name,
      kind: kind,
      mime: mime,
      bytes: bytes,
      width: width,
      height: height,
      thumbBase64: thumbBase64,
      uploading: false,
      error: reason,
    );
  }

  /// 发送时交给服务端的那份元信息。
  MessageAttachment toModel() {
    return MessageAttachment(
      id: id,
      name: name,
      kind: kind,
      mime: mime,
      bytes: bytes,
      width: width,
      height: height,
    );
  }

  static Map<String, dynamic> _payload({
    required String localId,
    required String id,
    required String name,
    required String kind,
    required String mime,
    required int bytes,
    required int? width,
    required int? height,
    required String? thumbBase64,
    required bool uploading,
    required String? error,
  }) {
    return <String, dynamic>{
      'local_id': localId,
      'id': id,
      'name': name,
      'kind': kind,
      'mime': mime,
      'bytes': bytes,
      'width': ?width,
      'height': ?height,
      'thumb': ?thumbBase64,
      if (uploading) 'uploading': true,
      'error': ?error,
    };
  }

  /// 从节点反解；`data` 不是我们写入的 JSON 时返回 null。
  static AttachmentEmbed? fromNode(Embed node) {
    if (node.value.type != attachmentEmbedType) {
      return null;
    }
    final data = node.value.data;
    if (data is! String) {
      return null;
    }
    try {
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic>) {
        return null;
      }
      return AttachmentEmbed.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// 只在解析与测试里用：字段缺失时退化成"一枚空名字的芯片"，不会抛。
  factory AttachmentEmbed.fromJson(Map<String, dynamic> json) {
    return AttachmentEmbed(
      localId: '${json['local_id'] ?? ''}',
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      kind: '${json['kind'] ?? 'file'}',
      mime: '${json['mime'] ?? 'application/octet-stream'}',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      thumbBase64: json['thumb'] as String?,
      uploading: json['uploading'] == true,
      error: json['error'] as String?,
    );
  }
}

/// 让 quill 把 [AttachmentEmbed] 渲染成一枚芯片。
///
/// 删除由芯片自己的 X 完成：`EmbedContext` 直接给了 controller 与节点，
/// 算出绝对偏移后删掉这一个字符即可。[onRemoved] 只用来通知上传侧
/// "把服务端那份也删掉"，不影响文档。
class AttachmentEmbedBuilder extends EmbedBuilder {
  const AttachmentEmbedBuilder({this.onRemoved});

  final ValueChanged<AttachmentEmbed>? onRemoved;

  @override
  String get key => AttachmentEmbed.attachmentEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final node = embedContext.node;
    final embed = AttachmentEmbed.fromNode(node);
    if (embed == null) {
      return const SizedBox.shrink();
    }

    return AttachmentChip(
      embed: embed,
      onRemove: () {
        removeEmbedNodeAt(embedContext, node);
        onRemoved?.call(embed);
      },
    );
  }
}

/// 芯片本体：缩略图或文档图标 + 文件名 + X。
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.embed, this.onRemove});

  final AttachmentEmbed embed;

  /// 为空时不画 X（气泡里的只读芯片）。
  final VoidCallback? onRemove;

  /// 文件名在芯片里的最大宽度。与路径引用芯片同源，并排放着宽度才对得上。
  static const double maxLabelWidth = kComposerChipLabelMaxWidth;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return ComposerChipFrame(
      tooltip: _tooltip(),
      error: embed.error != null,
      busy: embed.uploading,
      leading: _leading(context, palette),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxLabelWidth),
        child: Text(
          embed.name.isEmpty ? '附件' : embed.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: chipLabelStyle(
            context,
            color: embed.error != null ? palette.status.danger : null,
          ),
        ),
      ),
      onRemove: onRemove,
    );
  }

  Widget _leading(BuildContext context, AppPalette palette) {
    if (embed.uploading) {
      return const SizedBox(
        width: 11,
        height: 11,
        child: CircularProgressIndicator(strokeWidth: 1.2),
      );
    }

    final thumb = embed.thumbBytes;
    if (thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Image.memory(
          thumb,
          width: 14,
          height: 14,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    return Icon(
      embed.isImage ? Icons.image_outlined : Icons.description_outlined,
      size: 11,
      color: palette.text.tertiary,
    );
  }

  String _tooltip() {
    final spec = formatByteSize(embed.bytes);
    if (embed.error != null) {
      return '${embed.name}\n上传失败：${embed.error}';
    }
    if (embed.uploading) {
      return '${embed.name}\n$spec · 正在上传…';
    }
    final type = embed.isImage ? '图片' : (embed.mime.isEmpty ? '文件' : embed.mime);
    return '${embed.name}\n$type · $spec';
  }
}
