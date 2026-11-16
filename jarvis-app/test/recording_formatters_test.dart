import 'package:jarvis_app/src/core/recording/recording_formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatDuration 按时长选择 mm:ss 或 h:mm:ss', () {
    expect(formatDuration(0), '00:00');
    expect(formatDuration(65_000), '01:05');
    expect(formatDuration(3_600_000), '1:00:00');
    expect(formatDuration(3_725_000), '1:02:05');
  });

  test('formatElapsed 始终带小时位', () {
    expect(formatElapsed(0), '0:00:00');
    expect(formatElapsed(65_000), '0:01:05');
    expect(formatElapsed(3_725_000), '1:02:05');
  });

  test('formatBytes 保留一位小数并切换单位', () {
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
  });

  test('formatListTime 今天只显示时分', () {
    final now = DateTime(2026, 10, 28, 15, 0);
    final morning = DateTime(2026, 10, 28, 9, 5).millisecondsSinceEpoch;
    expect(formatListTime(morning, now: now), '09:05');

    final yesterday = DateTime(2026, 10, 27, 9, 5).millisecondsSinceEpoch;
    expect(formatListTime(yesterday, now: now), '10月27日');
  });

  test('dayGroupLabel 覆盖今天/昨天/本周/更早', () {
    final now = DateTime(2026, 10, 28, 15, 0);
    expect(
      dayGroupLabel(DateTime(2026, 10, 28, 8).millisecondsSinceEpoch, now: now),
      '今天',
    );
    expect(
      dayGroupLabel(DateTime(2026, 10, 27, 8).millisecondsSinceEpoch, now: now),
      '昨天',
    );
    expect(
      dayGroupLabel(DateTime(2026, 10, 24, 8).millisecondsSinceEpoch, now: now),
      '本周',
    );
    expect(
      dayGroupLabel(DateTime(2026, 9, 1, 8).millisecondsSinceEpoch, now: now),
      '9月',
    );
    expect(
      dayGroupLabel(DateTime(2025, 9, 1, 8).millisecondsSinceEpoch, now: now),
      '2025年',
    );
  });
}
