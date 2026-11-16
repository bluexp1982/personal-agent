/// 一个文件该用哪种查看器。
///
/// 枚举而不是直接返回 widget：路由是纯数据判断，能脱离界面单测；
/// 界面层只按结果分发，不再自己嗅探扩展名。
enum FilePreviewKind {
  /// 纯文本 / 代码（含无扩展名的 Makefile / LICENSE 这类）。
  ///
  /// 走带行号与语法高亮的查看器；语言按扩展名猜，猜不到就只上等宽字体。
  text,

  /// Markdown 文档：默认渲染成排版后的样子，可一键切回带高亮的源码。
  markdown,

  /// 位图：png / jpg / jpeg / gif / webp / bmp。
  image,

  /// PDF 文档。
  pdf,

  /// 视频：mp4 / mov / m4v / webm / mkv。
  video,

  /// 内置查看器解不了，但文件本身有效（svg / tiff / heic…）：
  /// 给「另存为 / 系统应用打开」，比白屏或"二进制文件无法预览"的报错有用。
  unsupported,
}

/// 扩展名到查看器的**唯一**映射。
///
/// 只留这一份：文件树判断一次、预览页再判断一次的话，两边迟早不一致——
/// 最典型的坏结果是点了图片却先请求文本端点，用户先吃一次"二进制文件"的报错。
///
/// 未知扩展名归到 [FilePreviewKind.text]：服务端会按 UTF-8 判定，
/// 非文本会返回可直接展示的提示，客户端不必自己维护一份全量文本后缀表。
FilePreviewKind previewKindOf(String path) {
  final name = path.toLowerCase();
  final dot = name.lastIndexOf('.');
  final slash = name.lastIndexOf('/');
  // 点必须在最后一段里：`dir.with.dot/Makefile` 的文件名本身没有扩展名。
  if (dot < 0 || dot < slash || dot + 1 >= name.length) {
    return FilePreviewKind.text;
  }

  return switch (name.substring(dot + 1)) {
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' =>
      FilePreviewKind.image,
    'pdf' => FilePreviewKind.pdf,
    // 视频交给 media_kit（libmpv）：容器格式覆盖面比"只认 mp4"宽得多，
    // 这里列的是实际会遇到的几种，其余仍按文本处理并给出可读提示。
    'mp4' || 'm4v' || 'mov' || 'webm' || 'mkv' => FilePreviewKind.video,
    // Markdown 必须先于 `_` 兜底：它仍然走 `/file` 文本端点，
    // 只是渲染方式不同，不该因为"未知扩展名"落进纯文本查看器。
    'md' || 'markdown' || 'mdx' => FilePreviewKind.markdown,
    // Flutter 没有原生 SVG 渲染，TIFF / HEIC 也不在 Image 的解码器里：
    // 塞进 Image.memory 只会拿到一张破图，不如明确说不支持。
    'svg' || 'tif' || 'tiff' || 'heic' || 'heif' => FilePreviewKind.unsupported,
    _ => FilePreviewKind.text,
  };
}
