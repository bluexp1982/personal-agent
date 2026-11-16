import 'package:flutter/material.dart';

import '../../core/file_preview_kind.dart';

/// 预览类型的图标。
///
/// 标签栏与文件头都要用：一个地方给"图片"、另一个给"文档"的话，
/// 用户会以为点开的不是同一份内容。形状跟着 [FilePreviewKind] 走，
/// 颜色仍由调用方按选中态传。
IconData previewIconOf(FilePreviewKind kind) {
  return switch (kind) {
    FilePreviewKind.image => Icons.image_outlined,
    FilePreviewKind.pdf => Icons.picture_as_pdf_outlined,
    FilePreviewKind.video => Icons.movie_outlined,
    FilePreviewKind.unsupported => Icons.insert_drive_file_outlined,
    FilePreviewKind.text => Icons.description_outlined,
    FilePreviewKind.markdown => Icons.article_outlined,
  };
}
