import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定「现在」，避免跨分钟/跨天边界导致的偶发失败。
final DateTime _now = DateTime(2026, 10, 26, 12, 0);

/// 把「相对现在的分钟数」换算成时间戳，正数表示过去。
int _ago(Duration duration) => _now.subtract(duration).millisecondsSinceEpoch;

String _format(Duration ago) => formatRailTime(_ago(ago), now: _now);

void main() {
  group('formatRailTime 各档刻度', () {
    test('时间戳缺失给破折号', () {
      expect(formatRailTime(0, now: _now), '—');
      expect(formatRailTime(-1, now: _now), '—');
    });

    test('不满一分钟是「刚刚」', () {
      expect(_format(Duration.zero), '刚刚');
      expect(_format(const Duration(seconds: 59)), '刚刚');
    });

    test('未来时间按「刚刚」，不出现负数', () {
      expect(
        formatRailTime(
          _now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: _now,
        ),
        '刚刚',
      );
    });

    test('分钟档', () {
      expect(_format(const Duration(minutes: 1)), '1分钟');
      expect(_format(const Duration(minutes: 59)), '59分钟');
    });

    test('小时档', () {
      expect(_format(const Duration(hours: 1)), '1小时');
      expect(_format(const Duration(hours: 9)), '9小时');
      expect(_format(const Duration(hours: 23, minutes: 59)), '23小时');
    });

    test('天档', () {
      expect(_format(const Duration(days: 1)), '1天');
      expect(_format(const Duration(days: 3, hours: 5)), '3天');
      expect(_format(const Duration(days: 29)), '29天');
    });

    test('个月档向下取整', () {
      expect(_format(const Duration(days: 30)), '1个月');
      expect(_format(const Duration(days: 59)), '1个月');
      expect(_format(const Duration(days: 60)), '2个月');
      expect(_format(const Duration(days: 364)), '12个月');
    });

    test('年档向下取整', () {
      expect(_format(const Duration(days: 365)), '1年');
      expect(_format(const Duration(days: 400)), '1年');
      expect(_format(const Duration(days: 800)), '2年');
    });
  });

  test('文案保持紧凑：不带「前」、数字与单位之间不留空格', () {
    final samples = <Duration>[
      const Duration(seconds: 30),
      const Duration(minutes: 5),
      const Duration(hours: 9),
      const Duration(days: 1),
      const Duration(days: 45),
      const Duration(days: 400),
    ];
    for (final ago in samples) {
      final text = _format(ago);
      expect(text.contains('前'), isFalse, reason: '$text 不该带「前」');
      expect(text.contains(' '), isFalse, reason: '$text 不该有空格');
    }
  });
}
