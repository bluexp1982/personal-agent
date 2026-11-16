import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/design/app_palette.dart';
import 'composer_chip.dart';
import 'embed_node_edit.dart';

/// 输入框里的一枚路径引用芯片（quill 的 embed 节点）。
///
/// 与附件芯片的区别只有一件事：**没有上传**。文件在服务端，客户端拿不到字节，
/// 这里存的只是"引用哪一份文件"；发送时由 `composerText` 展开成相对路径文本。
/// 因此它也不能进入 `attachmentIds`——那不是附件，服务端没有它的 id。
class PathRefEmbed extends Embeddable {
  PathRefEmbed({
    required this.name,
    required this.relativePath,
    required this.absolutePath,
    required this.isDir,
  }) : super(
         pathRefEmbedType,
         jsonEncode(
           _payload(
             name: name,
             relativePath: relativePath,
             absolutePath: absolutePath,
             isDir: isDir,
           ),
         ),
       );

  /// 节点类型。与附件一样带前缀，避免和 quill 内置节点撞名。
  static const String pathRefEmbedType = 'personal-agent-path-ref';

  /// 芯片上显示的名字。
  final String name;

  /// 项目相对路径：发送时写进正文的那一段。
  final String relativePath;

  /// 服务端绝对路径：只用于悬停提示。
  final String absolutePath;

  final bool isDir;

  static Map<String, dynamic> _payload({
    required String name,
    required String relativePath,
    required String absolutePath,
    required bool isDir,
  }) {
    return <String, dynamic>{
      'name': name,
      'relative': relativePath,
      'absolute': absolutePath,
      'is_dir': isDir,
    };
  }

  /// 从节点反解；`data` 不是我们写入的 JSON 时返回 null。
  static PathRefEmbed? fromNode(Embed node) {
    if (node.value.type != pathRefEmbedType) {
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
      return PathRefEmbed.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  /// 字段缺失时退化成"一枚空名字的芯片"，不抛错：
  /// 宁可少一枚芯片，也不要让输入栏因为一条坏数据崩掉。
  factory PathRefEmbed.fromJson(Map<String, dynamic> json) {
    return PathRefEmbed(
      name: '${json['name'] ?? ''}',
      relativePath: '${json['relative'] ?? ''}',
      absolutePath: '${json['absolute'] ?? ''}',
      isDir: json['is_dir'] == true,
    );
  }
}

/// 让 quill 把 [PathRefEmbed] 渲染成一枚芯片。
class PathRefEmbedBuilder extends EmbedBuilder {
  const PathRefEmbedBuilder();

  @override
  String get key => PathRefEmbed.pathRefEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final node = embedContext.node;
    final embed = PathRefEmbed.fromNode(node);
    if (embed == null) {
      return const SizedBox.shrink();
    }

    return PathRefChip(
      embed: embed,
      onRemove: () => removeEmbedNodeAt(embedContext, node),
    );
  }
}

/// 芯片本体：文件夹 / 文件图标 + 名字 + X，外观与附件芯片同源。
class PathRefChip extends StatelessWidget {
  const PathRefChip({super.key, required this.embed, this.onRemove});

  final PathRefEmbed embed;

  /// 为空时不画 X（气泡里的只读芯片）。
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return ComposerChipFrame(
      // 完整路径只放在悬停提示里：芯片本身太窄，塞不下。
      tooltip: embed.absolutePath,
      leading: Icon(
        embed.isDir ? Icons.folder_outlined : Icons.description_outlined,
        size: 11,
        color: palette.text.tertiary,
      ),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kComposerChipLabelMaxWidth),
        child: Text(
          embed.name.isEmpty ? '路径' : embed.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: chipLabelStyle(context),
        ),
      ),
      onRemove: onRemove,
    );
  }
}
