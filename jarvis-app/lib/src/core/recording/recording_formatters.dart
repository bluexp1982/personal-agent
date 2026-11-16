/// 录音列表与详情用到的纯格式化函数。
///
/// 独立成文件是为了能直接单测：这些字符串出现在列表每一行，
/// "01:05 还是 1:05""1.2 MB 还是 1.2MB"一旦各写一套就会看起来像两个产品。
library;

/// 时长：不足一小时用 `mm:ss`，超过则 `h:mm:ss`。
String formatDuration(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round().clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}

/// 录音计时：始终 `h:mm:ss`，让人一眼看出已经录了多久。
String formatElapsed(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).floor().clamp(0, 359999);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return '$hours:${two(minutes)}:${two(seconds)}';
}

/// 文件大小，保留一位小数。
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = <String>['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 列表时间：今天只显示时分，其它显示日期。
String formatListTime(int milliseconds, {DateTime? now}) {
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final current = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final sameDay =
      time.year == current.year &&
      time.month == current.month &&
      time.day == current.day;
  if (sameDay) {
    return '${two(time.hour)}:${two(time.minute)}';
  }
  if (time.year == current.year) {
    return '${time.month}月${time.day}日';
  }
  return '${time.year}/${time.month}/${time.day}';
}

/// 分组标题：今天 / 昨天 / 本周 / 更早。
String dayGroupLabel(int milliseconds, {DateTime? now}) {
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final target = DateTime(time.year, time.month, time.day);
  final days = today.difference(target).inDays;
  if (days <= 0) {
    return '今天';
  }
  if (days == 1) {
    return '昨天';
  }
  if (days < 7) {
    return '本周';
  }
  if (time.year == current.year) {
    return '${time.month}月';
  }
  return '${time.year}年';
}

/// 片段时长，用于转写稿左侧的时间戳：`mm:ss`。
String formatSegmentStamp(int milliseconds) => formatDuration(milliseconds);
