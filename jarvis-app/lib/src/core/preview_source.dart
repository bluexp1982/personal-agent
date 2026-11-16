import 'package:flutter/foundation.dart';

import 'models.dart';

/// 一枚预览标签"看的是什么"，与标签 id 一起决定怎么取字节、怎么另存。
///
/// 之前预览标签的 id 就是文件绝对路径，隐式假设"预览的都是项目文件"。会话产物
/// 打破了这条假设：图片 / 视频不在项目目录里，靠 `/api/media/{id}/content` 取。
/// 于是把来源显式化，标签 id 仍是字符串（Key、标题表、关闭都靠它），
/// 只是含义由带前缀的约定区分：
///
/// - 项目文件：id 就是路径本身（保持既有约定，文件树高亮与测试都不用改）；
/// - 会话媒体：id 是 `media:<assetId>`，天然不会与真实路径撞上。
@immutable
class PreviewSource {
  const PreviewSource.file({required this.projectId, required this.path})
    : asset = null,
      conversationTitle = '';

  const PreviewSource.media({
    required this.asset,
    this.conversationTitle = '',
  }) : projectId = '',
       path = '';

  /// 项目内文件：所属项目 id（预览端点在路径里要它）。
  final String projectId;

  /// 项目内文件：根内相对路径或绝对路径。
  final String path;

  /// 会话媒体：非空表示这是产物预览。
  final MediaAsset? asset;

  /// 会话标题：媒体另存时的自动名要用它。
  final String conversationTitle;

  bool get isMedia => asset != null;

  /// 标签 id：项目文件用路径本身，媒体用前缀 + 资产 id。
  String get tabId => isMedia ? mediaTabId(asset!.id) : path;

  /// 媒体标签 id 的前缀。带它就不会与任何真实路径混淆。
  static String mediaTabId(String assetId) => 'media:$assetId';

  /// 标签 id 是不是媒体来源（`previewSources` 缺失时的兜底判断）。
  static bool looksLikeMediaTab(String tabId) => tabId.startsWith('media:');
}
