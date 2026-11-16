import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../core/models.dart';
import '../../core/project_paths.dart';
import 'attachment_embed.dart';
import 'path_ref_embed.dart';
import 'skill_embed.dart';

/// quill 用这个字符表示一个 embed 节点。
///
/// `Document.toPlainText()` 里每个 embed 都是一个它，占一个字符位置——
/// 这也是"从 `toPlainText` 的下标能直接当 document 偏移用"的原因。
const String kEmbedPlaceholder = '\uFFFC';

/// 输入栏的纯文本（发送出去的正文）。
///
/// 不同 embed 的去留不同：
/// - 技能标签：名字走 [firstSkillName] 单独传，正文里不出现；
/// - 附件芯片：id 走 `attachmentIds` 单独传，正文里同样不出现；
/// - 路径引用：**正文就是它的意义**，展开成项目相对路径（`styles/theme.css`）。
///
/// 不能再用 `toPlainText().replaceAll(占位符, '')`：那样拖进来的路径会被静默丢掉。
String composerText(QuillController controller) {
  final buffer = StringBuffer();
  for (final op in controller.document.toDelta().toList()) {
    final data = op.data;
    if (data is String) {
      buffer.write(data);
      continue;
    }
    if (data is Map && data.containsKey(PathRefEmbed.pathRefEmbedType)) {
      final raw = data[PathRefEmbed.pathRefEmbedType];
      if (raw is String) {
        final embed = _decode(raw, PathRefEmbed.fromJson);
        if (embed != null) {
          buffer.write(embed.relativePath);
        }
      }
    }
  }
  return buffer.toString().trim();
}

/// 整段替换。空态页把一句话交接过来时用。
void setComposerText(QuillController controller, String text) {
  // 文档末尾固定有一个 `\n`，能删的上限是长度减一。
  final length = (controller.document.toPlainText().length - 1).clamp(
    0,
    1 << 31,
  );
  controller.replaceText(
    0,
    length,
    text,
    TextSelection.collapsed(offset: text.length),
  );
}

/// 清空并复位光标。
void clearComposer(QuillController controller) {
  setComposerText(controller, '');
}

/// 文档里所有技能标签，按出现顺序。
List<SkillEmbed> skillEmbeds(QuillController controller) {
  return _scan(controller, SkillEmbed.skillEmbedType, SkillEmbed.fromJson)
      .where((item) => item.embed.skillName.isNotEmpty)
      .map((item) => item.embed)
      .toList(growable: false);
}

/// 第一个技能标签的名字；没有则为 null。
///
/// **这是"当前选中的技能"的唯一真相**：不另存一份状态，
/// 否则用户退格删掉标签后，状态里还留着它，会按技能去派任务。
String? firstSkillName(QuillController controller) {
  final found = skillEmbeds(controller);
  return found.isEmpty ? null : found.first.skillName;
}

/// 文档里所有附件芯片，按出现顺序。
List<AttachmentEmbed> attachmentEmbeds(QuillController controller) {
  return _scan(
    controller,
    AttachmentEmbed.attachmentEmbedType,
    AttachmentEmbed.fromJson,
  ).map((item) => item.embed).toList(growable: false);
}

/// 文档里所有路径引用芯片，按出现顺序。
///
/// 与 [attachmentEmbeds] 分开：路径引用没有服务端 id，也不能算进附件数量。
List<PathRefEmbed> pathRefEmbeds(QuillController controller) {
  return _scan(
    controller,
    PathRefEmbed.pathRefEmbedType,
    PathRefEmbed.fromJson,
  ).map((item) => item.embed).toList(growable: false);
}

/// 可以发送的附件 id（按芯片顺序）。上传中或失败的不会出现在这里。
///
/// 与技能标签同一条真理来源：**文档里没有的就不发**。用户退格删掉芯片后，
/// 这一枚自然不在列表里，不需要额外的"取消勾选"状态。
List<String> attachmentIds(QuillController controller) {
  return attachmentEmbeds(controller)
      .where((embed) => embed.ready)
      .map((embed) => embed.id)
      .toList(growable: false);
}

/// 还在上传中的附件数量。非零时发送按钮要让位给"正在处理"。
int pendingAttachmentCount(QuillController controller) {
  return attachmentEmbeds(controller).where((embed) => embed.uploading).length;
}

/// 文档里有没有"可以发出去的东西"：正文，或至少一枚已就绪的附件。
///
/// 只发附件不写文字是合法输入，发送按钮不能只按正文判空。
bool composerHasContent(QuillController controller) {
  return composerText(controller).isNotEmpty ||
      attachmentIds(controller).isNotEmpty;
}

/// 在光标处插入一枚附件芯片，返回它的 `localId`。
///
/// 上传成功后用 [replaceAttachmentEmbed] 就地换成带服务端 id 的那一枚——
/// 位置不变，用户看到的是同一枚芯片从转圈变成缩略图。
String insertAttachmentEmbed(QuillController controller, AttachmentEmbed embed) {
  final selection = controller.selection;
  final limit = (controller.document.toPlainText().length - 1).clamp(
    0,
    1 << 31,
  );
  final index = selection.isValid
      ? selection.end.clamp(0, limit)
      : limit;

  controller.replaceText(
    index,
    0,
    embed,
    TextSelection.collapsed(offset: index + 1),
  );

  // 与技能标签同一理由：紧跟一个空格，embed 才不会独占一行被判定为 block。
  controller.replaceText(
    index + 1,
    0,
    ' ',
    TextSelection.collapsed(offset: index + 2),
  );

  return embed.localId;
}

/// 按 `localId` 就地替换一枚附件芯片。找不到（用户已经删掉它）返回 false。
///
/// 找不到是正常竞态：上传慢了半拍，用户等不及点了 X。此时不该报错，
/// 调用方顺手把刚上传的那份删掉即可。
bool replaceAttachmentEmbed(
  QuillController controller,
  String localId,
  AttachmentEmbed next,
) {
  final found = _scan(
    controller,
    AttachmentEmbed.attachmentEmbedType,
    AttachmentEmbed.fromJson,
  );
  for (final item in found) {
    if (item.embed.localId != localId) {
      continue;
    }
    controller.replaceText(
      item.offset,
      1,
      next,
      TextSelection.collapsed(offset: item.offset + 1),
    );
    return true;
  }
  return false;
}

/// 在光标处插入一枚路径引用芯片。
///
/// 与附件芯片同一套光标夹取与尾随空格：芯片后面不留空格的话，quill 会把它
/// 当成独占一行的块级节点，光标会跳到最右侧。
void insertPathRefEmbed(
  QuillController controller,
  ProjectPathReference ref,
) {
  final selection = controller.selection;
  final limit = (controller.document.toPlainText().length - 1).clamp(
    0,
    1 << 31,
  );
  final index = selection.isValid ? selection.end.clamp(0, limit) : limit;

  controller.replaceText(
    index,
    0,
    PathRefEmbed(
      name: ref.name,
      relativePath: ref.relativePath,
      absolutePath: ref.absolutePath,
      isDir: ref.isDir,
    ),
    TextSelection.collapsed(offset: index + 1),
  );
  controller.replaceText(
    index + 1,
    0,
    ' ',
    TextSelection.collapsed(offset: index + 2),
  );
}

/// 在光标处插入一枚技能标签，并保证全文档只有一个。
///
/// 只允许一个：派任务的状态是单值，多个标签就得定义"谁优先"，
/// 那是产品决策，不该由 UI 悄悄决定。
void insertSkillEmbed(QuillController controller, SkillInfo skill) {
  clearSkillEmbeds(controller);

  final selection = controller.selection;
  final limit = (controller.document.toPlainText().length - 1).clamp(
    0,
    1 << 31,
  );
  final index = selection.isValid ? selection.end.clamp(0, limit) : limit;

  controller.replaceText(
    index,
    0,
    SkillEmbed(skill: skill),
    TextSelection.collapsed(offset: index + 1),
  );

  // 紧跟一个空格。quill 把"独占一行的 embed"判定为 block：光标会跳到最右侧、
  // 换行也不自然。补一个文本节点之后它就始终与文字同行，按 inline 渲染。
  controller.replaceText(
    index + 1,
    0,
    ' ',
    TextSelection.collapsed(offset: index + 2),
  );
}

/// 删掉所有技能标签，返回删掉的个数。
int clearSkillEmbeds(QuillController controller) {
  final found = _scan(controller, SkillEmbed.skillEmbedType, SkillEmbed.fromJson);
  // 从后往前删：先删前面的会让后面的偏移整体左移。
  for (final item in found.reversed) {
    controller.replaceText(
      item.offset,
      1,
      '',
      TextSelection.collapsed(offset: item.offset),
    );
  }
  return found.length;
}

/// 扫一遍 Delta，记下某种 embed 的绝对偏移与解析结果。
///
/// 不用 `document.root.children` 递归：这里只关心"扁平文档里的第几个字符"，
/// Delta 本身就是按顺序的字符流，走一遍就能算准，也不会被行/块结构干扰。
///
/// [decode] 返回 null 表示"这不是我们写进去的数据"：宁可少一枚芯片，
/// 也不要让输入栏因为一条坏数据抛错。
List<({int offset, T embed})> _scan<T>(
  QuillController controller,
  String type,
  T? Function(Map<String, dynamic> json) decode,
) {
  final found = <({int offset, T embed})>[];
  var offset = 0;

  for (final op in controller.document.toDelta().toList()) {
    final data = op.data;

    if (data is String) {
      offset += data.length;
      continue;
    }

    // 任何非字符串的 op 都是 embed（技能、附件，或 quill 内置的图片）。
    // 它们在纯文本里**一律**占一个字符位置；漏算一种就会让后面的偏移整体错位，
    // 表现出来是"删掉这枚芯片，删的却是旁边那一枚"。
    if (data is Map && data.containsKey(type)) {
      final raw = data[type];
      if (raw is String) {
        final parsed = _decode(raw, decode);
        if (parsed != null) {
          found.add((offset: offset, embed: parsed));
        }
      }
    }
    offset += 1;
  }

  return found;
}

T? _decode<T>(String raw, T? Function(Map<String, dynamic> json) decode) {
  try {
    final json = jsonDecode(raw);
    if (json is Map<String, dynamic>) {
      return decode(json);
    }
  } on FormatException {
    return null;
  }
  return null;
}
