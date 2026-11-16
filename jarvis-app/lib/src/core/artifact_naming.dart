/// 会话产物的文件命名规则（纯函数，便于单测）。
///
/// 自动名固定为 `会话标题_工具名_时间戳.扩展名`，例如
/// `季度复盘_generate_image_20261105-153012.png`。三段的来源分别是：
/// - 会话标题：`ChatPage` 当前标题（服务端持久化的那一份）；
/// - 工具名：与后端 `local_tools/media_gen.rs` 的工具 id 一致，便于回溯是哪次生成；
/// - 时间戳：`MediaAsset.createdAt`（本地时区），为 0 时回退当前时间。
///
/// 为什么会话标题要清洗：标题是用户随手写的，可能带 `/`、`:`、换行，
/// 直接拼进路径轻则保存失败，重则在项目里造出子目录。
library;

import 'artifact_exporter.dart';

/// 文件名长度上限。与后端 `api::media::MAX_SAVE_NAME_CHARS` 保持一致：
/// 两边都拦，避免"客户端过了、服务端报错"的割裂体验。
const int maxArtifactNameChars = 180;

/// 标题段的上限：再长会把扩展名挤出可见区域，时间戳也失去意义。
const int _maxTitleChars = 40;

/// 路径分隔符与 Windows 保留字符：与后端拒绝的那一组一致。
const List<String> _forbiddenChars = <String>[
  '/',
  '\\',
  ':',
  '*',
  '?',
  '"',
  '<',
  '>',
  '|',
];

/// 会话产物对应的工具 id。
///
/// 与后端工具名对齐（`generate_image` / `generate_video`），而不是写成
/// 「文生图」：文件名里带的是**可检索的标识**，中文标签改一次文案就全变了。
String artifactToolName(String kind) => switch (kind) {
  'video' => 'generate_video',
  _ => 'generate_image',
};

/// 把会话标题压成可用的文件名片段。
///
/// 规则：分隔符/保留字符/控制字符/空白一律折成 `_`，连续 `_` 合并，首尾去 `_`，
/// 超长截断；清洗后为空时回退「会话」——空片段会让自动名变成
/// `_generate_image_...`，看起来像程序出错。
String artifactTitleSegment(String rawTitle, {int maxChars = _maxTitleChars}) {
  final buffer = StringBuffer();
  var lastUnderscore = false;

  for (final rune in rawTitle.trim().runes) {
    final char = String.fromCharCode(rune);
    final replace =
        _forbiddenChars.contains(char) ||
        char.trim().isEmpty ||
        rune < 0x20 ||
        rune == 0x7F;
    if (replace) {
      // 连续的分隔符合并成一个：`a  /  b` 不该变成 `a_____b`。
      if (!lastUnderscore && buffer.isNotEmpty) {
        buffer.write('_');
        lastUnderscore = true;
      }
      continue;
    }
    buffer.write(char);
    lastUnderscore = false;
  }

  // 首尾的 `_` 与 `.` 都要去掉：前者会让名字出现 `_generate_image` 这种断头片段，
  // 后者会把它变成隐藏文件——服务端会直接拒绝以点开头的文件名。
  var segment = buffer
      .toString()
      .replaceAll(RegExp(r'^[._]+|[._]+$'), '');

  final runes = segment.runes.toList(growable: false);
  if (runes.length > maxChars) {
    segment = String.fromCharCodes(runes.sublist(0, maxChars)).replaceAll(
      RegExp(r'[._]+$'),
      '',
    );
  }

  return segment.isEmpty ? '会话' : segment;
}

/// `yyyyMMdd-HHmmss`（本地时区）。
///
/// 用连字符分开日期与时间：纯数字串 `20261105153012` 人眼很难读，
/// 而文件名本来就是给人看的。毫秒为 0 / 负值时回退 [now]。
String artifactTimestamp(int createdAtMs, {DateTime? now}) {
  final millis = createdAtMs > 0
      ? createdAtMs
      : (now ?? DateTime.now()).millisecondsSinceEpoch;
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}'
      '-${two(time.hour)}${two(time.minute)}${two(time.second)}';
}

/// 自动文件名：`会话标题_工具名_时间戳.扩展名`。
String automaticArtifactName({
  required String conversationTitle,
  required String kind,
  required int createdAtMs,
  required String mime,
  DateTime? now,
}) {
  final title = artifactTitleSegment(conversationTitle);
  final tool = artifactToolName(kind);
  final stamp = artifactTimestamp(createdAtMs, now: now);
  return '${title}_${tool}_$stamp${extensionForMime(mime)}';
}

/// 预览标签上的显示名：`图片 15:30` / `视频 15:30`。
///
/// 不用完整自动名（`会话标题_工具名_时间戳.png`）：标签最宽 180，带标题与工具名
/// 只会被压成省略号，用户唯一能分辨的还是时间；具体文件在预览页的文件头里。
String artifactTabTitle({required String kind, required int createdAtMs}) {
  final label = kind == 'video' ? '视频' : '图片';
  final millis = createdAtMs > 0
      ? createdAtMs
      : DateTime.now().millisecondsSinceEpoch;
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '$label ${two(time.hour)}:${two(time.minute)}';
}

/// 手动命名的校验。
///
/// 返回 null 表示可用，否则是直接展示给用户的原因。客户端不依赖服务端兜底：
/// 等一次网络往返才说"名字里不能有斜杠"太慢，而且用户改的是输入框。
String? validateArtifactName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) {
    return '文件名不能为空';
  }
  if (name.runes.length > maxArtifactNameChars) {
    return '文件名太长（上限 $maxArtifactNameChars 个字符）';
  }
  if (name.startsWith('.')) {
    return '文件名不能以点开头';
  }
  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    if (_forbiddenChars.contains(char)) {
      return '文件名不能包含 / \\ : * ? " < > |';
    }
    if (rune < 0x20 || rune == 0x7F) {
      return '文件名不能包含控制字符';
    }
  }
  return null;
}
