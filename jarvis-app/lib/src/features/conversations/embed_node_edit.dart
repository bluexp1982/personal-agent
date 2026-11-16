import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// 删掉一个 embed 节点，并顺手吃掉紧随其后的那个空格。
///
/// 插入芯片时统一补过一个空格（见 [insertAttachmentEmbed] / `insertPathRefEmbed`）：
/// 不清掉的话，每删一枚芯片就在正文里留一个看不见的空格，攒几次之后
/// `composerText` 会因为它非空而一直让发送按钮亮着。
///
/// 附件与路径引用的 builder 共用这一份：两处各写一遍，迟早只修好一边。
void removeEmbedNodeAt(EmbedContext context, Node node) {
  final offset = node.documentOffset;
  final plain = context.controller.document.toPlainText();
  context.controller.replaceText(
    offset,
    1,
    '',
    TextSelection.collapsed(offset: offset),
  );
  if (offset < plain.length && plain[offset] == ' ') {
    context.controller.replaceText(
      offset,
      1,
      '',
      TextSelection.collapsed(offset: offset),
    );
  }
}
