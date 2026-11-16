import 'package:jarvis_app/src/core/artifact_exporter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extensionForMime', () {
    test('常见文本类型映射到真实后缀', () {
      expect(extensionForMime('text/plain'), '.txt');
      expect(extensionForMime('text/markdown'), '.md');
      expect(extensionForMime('application/json'), '.json');
    });

    test('带 charset 的 mime 只看主类型', () {
      expect(extensionForMime('text/plain; charset=utf-8'), '.txt');
    });

    test('未知类型不猜后缀', () {
      expect(extensionForMime('application/x-weird'), '.bin');
      expect(extensionForMime(''), '.bin');
    });
  });

  group('artifactFileName', () {
    test('由 kind + id + 后缀组成', () {
      expect(
        artifactFileName(kind: 'plan_table', id: 'art_1', mime: 'text/plain'),
        'plan_table-art_1.txt',
      );
    });

    test('kind 里的非法字符被替换（避免路径/文件系统问题）', () {
      expect(
        artifactFileName(kind: 'a/b c', id: 'art_2', mime: 'application/json'),
        'a_b_c-art_2.json',
      );
    });
  });

  group('createArtifactExporter', () {
    test('手机用系统分享', () {
      expect(
        createArtifactExporter(platform: TargetPlatform.android),
        isA<MobileArtifactExporter>(),
      );
      expect(
        createArtifactExporter(platform: TargetPlatform.iOS),
        isA<MobileArtifactExporter>(),
      );
    });

    test('桌面用另存为对话框', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          createArtifactExporter(platform: platform),
          isA<DesktopArtifactExporter>(),
        );
      }
    });
  });
}
