import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/file_preview_kind.dart';

void main() {
  test('位图扩展名全部路由到图片查看器，且不区分大小写', () {
    for (final name in <String>[
      'a.png',
      'b.PNG',
      'c.jpg',
      'd.jpeg',
      'e.gif',
      'f.webp',
      'g.bmp',
      '/tmp/dir/x.JpEg',
    ]) {
      expect(previewKindOf(name), FilePreviewKind.image, reason: name);
    }
  });

  test('pdf 路由到 PDF 查看器', () {
    expect(previewKindOf('report.pdf'), FilePreviewKind.pdf);
    expect(previewKindOf('/tmp/扫描件.PDF'), FilePreviewKind.pdf);
  });

  test('视频容器路由到视频查看器，且不区分大小写', () {
    for (final name in <String>[
      'clip.mp4',
      'clip.MP4',
      'clip.m4v',
      'clip.mov',
      'clip.webm',
      'clip.mkv',
      '/tmp/dir/剪辑.MoV',
    ]) {
      expect(previewKindOf(name), FilePreviewKind.video, reason: name);
    }
  });

  test('解不了的格式明确标为不支持，而不是退回文本', () {
    for (final name in <String>[
      'logo.svg',
      'scan.tiff',
      'scan.TIF',
      'IMG_0001.heic',
      'IMG_0002.heif',
    ]) {
      expect(previewKindOf(name), FilePreviewKind.unsupported, reason: name);
    }
  });

  test('文本与无扩展名文件走原有文本预览', () {
    for (final name in <String>[
      'main.rs',
      'Makefile',
      '/tmp/proj.with.dot/Makefile',
      'app.min.js',
    ]) {
      expect(previewKindOf(name), FilePreviewKind.text, reason: name);
    }
  });

  test('Markdown 走文档渲染查看器，且不区分大小写', () {
    for (final name in <String>[
      'README.md',
      'docs/guide.markdown',
      '/tmp/说明.MD',
      'page.mdx',
    ]) {
      expect(previewKindOf(name), FilePreviewKind.markdown, reason: name);
    }
  });

  test('结尾是点或空路径不越界', () {
    expect(previewKindOf('weird.'), FilePreviewKind.text);
    expect(previewKindOf(''), FilePreviewKind.text);
    expect(previewKindOf('/tmp/'), FilePreviewKind.text);
  });
}
