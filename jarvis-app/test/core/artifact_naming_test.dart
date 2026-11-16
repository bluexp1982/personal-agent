import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/artifact_naming.dart';

void main() {
  group('时间戳', () {
    test('按本地时区格式化为 yyyyMMdd-HHmmss', () {
      final created = DateTime(2026, 11, 5, 15, 30, 12).millisecondsSinceEpoch;
      expect(artifactTimestamp(created), '20261105-153012');
    });

    test('毫秒为 0 时回退传入的当前时间', () {
      expect(
        artifactTimestamp(0, now: DateTime(2026, 1, 2, 3, 4, 5)),
        '20260102-030405',
      );
    });

    test('个位数月份与时间补零', () {
      final created = DateTime(2026, 2, 3, 4, 5, 6).millisecondsSinceEpoch;
      expect(artifactTimestamp(created), '20260203-040506');
    });
  });

  group('标题清洗', () {
    test('路径分隔符、保留字符与换行都折成下划线', () {
      expect(artifactTitleSegment('季度/复盘: 第2版'), '季度_复盘_第2版');
      expect(artifactTitleSegment('a\nb\tc'), 'a_b_c');
    });

    test('连续分隔符合并，首尾不留下划线或点', () {
      // 首尾的点必须去掉：名字以点开头就是隐藏文件，服务端会拒绝。
      expect(artifactTitleSegment('  ..季度  //  复盘..  '), '季度_复盘');
      expect(artifactTitleSegment('///'), '会话');
    });

    test('空标题回退「会话」，避免自动名以分隔符开头', () {
      expect(artifactTitleSegment(''), '会话');
      expect(artifactTitleSegment('   '), '会话');
    });

    test('超长标题按字符截断并去掉结尾下划线', () {
      final long = '盘' * 60;
      final segment = artifactTitleSegment(long);
      expect(segment.runes.length, 40);
      expect(segment.endsWith('_'), isFalse);
    });
  });

  group('自动命名', () {
    test('会话标题_工具名_时间戳.扩展名', () {
      final created = DateTime(2026, 11, 5, 15, 30, 12).millisecondsSinceEpoch;
      expect(
        automaticArtifactName(
          conversationTitle: '季度复盘',
          kind: 'image',
          createdAtMs: created,
          mime: 'image/png',
        ),
        '季度复盘_generate_image_20261105-153012.png',
      );
    });

    test('视频用 generate_video 与记录里的 mime 后缀', () {
      final created = DateTime(2026, 11, 5, 15, 30, 12).millisecondsSinceEpoch;
      expect(
        automaticArtifactName(
          conversationTitle: '海边日落',
          kind: 'video',
          createdAtMs: created,
          mime: 'video/mp4',
        ),
        '海边日落_generate_video_20261105-153012.mp4',
      );
    });

    test('未知 mime 落到 .bin，不猜一个可能错的后缀', () {
      final created = DateTime(2026, 11, 5, 15, 30, 12).millisecondsSinceEpoch;
      expect(
        automaticArtifactName(
          conversationTitle: 'x',
          kind: 'image',
          createdAtMs: created,
          mime: 'application/octet-stream',
        ),
        endsWith('.bin'),
      );
    });
  });

  group('手动名校验', () {
    test('合法名字放行', () {
      expect(validateArtifactName('季度复盘_generate_image_20261105-153012.png'), isNull);
      expect(validateArtifactName('a.png'), isNull);
    });

    test('空名、以点开头、含分隔符或控制字符都拒绝', () {
      expect(validateArtifactName(''), isNotNull);
      expect(validateArtifactName('   '), isNotNull);
      expect(validateArtifactName('.env'), isNotNull);
      expect(validateArtifactName('a/b.png'), isNotNull);
      expect(validateArtifactName('a\\b.png'), isNotNull);
      expect(validateArtifactName('a:b.png'), isNotNull);
      expect(validateArtifactName('a\nb.png'), isNotNull);
    });

    test('超长名字拒绝', () {
      expect(validateArtifactName('长' * (maxArtifactNameChars + 1)), isNotNull);
      expect(validateArtifactName('长' * maxArtifactNameChars), isNull);
    });
  });
}
