import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/browser/browser_controller.dart';
import '../../core/browser/browser_targets.dart';
import '../../core/preview_source.dart';
import 'file_pane_state.dart';
import 'panel_page.dart';

/// 在浏览器面板里打开一个地址。
///
/// 三个入口共用这一份实现：会话里产物卡的「打开」、AI 要求打开页面
/// （`open_url` 事件）、文件树右键「预览」。各自写一遍的话，
/// "宽屏开右栏、窄屏推整页、同页复用标签"的规则迟早分叉。
///
/// **不能**交给系统浏览器：它既没有 Bearer，也连不上服务端的自签 HTTPS，
/// 而预览站的地址在服务端回环上，手机的系统浏览器根本到不了。
///
/// [wide] 由调用方算：它取决于"当前是整页形态还是三栏形态"，这个判断在
/// 会话页与文件面板里不是同一句代码。
/// [display] 是可读的逻辑地址（项目名 + 相对路径），真实地址里的随机端口
/// 与访问令牌不出现在地址栏。
/// [pushPanelOnNarrow] 窄屏时要不要把面板推上来。文件树自己就长在面板里，
/// 再推一层会叠出两个 PanelPage——那时只切标签就够了。
Future<void> openPreviewInPanel(
  BuildContext context,
  WidgetRef ref, {
  required String url,
  required bool wide,
  String? display,
  bool pushPanelOnNarrow = true,
}) async {
  final uri = Uri.tryParse(url);
  // 服务端已经拦过一次；客户端不执行非 http(s) 的地址，哪怕对面说可以。
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return;
  }
  if (!context.mounted) {
    return;
  }

  // 同一个页面已经在右栏开着就复用那个标签：同一张产物卡点几次都不该
  // 堆出一排同名标签。命中后仍然用**本次**的地址重开——文件可能刚重新
  // 生成过，预览令牌也可能已经换了，只切过去会看到旧内容或直接 403。
  final tabs = ref.read(filePaneTabProvider.notifier);
  final existing = existingPreviewTab(ref, url: url, display: display);
  final tabId = existing ?? tabs.openNewBrowser();
  if (existing != null) {
    tabs.activateBrowser(existing);
  }

  if (wide) {
    // 先让右栏出现再加载：面板收起时浏览器页还没挂载，
    // 加载会落在一个没有宿主的会话上。
    ref.read(filePaneVisibleProvider.notifier).show();
  }

  await ref
      .read(browserSessionProvider(tabId).notifier)
      .open(browserInputFromUrl(url), display: display);

  // 窄屏：通道建好之后再把整页面板推上来，`BrowserPane` 初始化时
  // 就能读到 `internalUri`，不用等一次额外的重载。
  if (!wide && pushPanelOnNarrow && context.mounted) {
    unawaited(openPanelPage(context));
  }
}

/// 把一个"内容预览"（不是网页）落到右栏，并按需把右栏亮出来。
///
/// 与 [openPreviewInPanel] 同一套口径，差别只在落点：网页进浏览器标签，
/// 文件 / 图片 / 视频进预览标签。会话产物卡的「打开」统一走这里——
/// 不再 push 全屏路由，因为"看东西"这件事在右栏已经有一等公民的位置。
///
/// [wide] 由调用方算（取决于整页形态还是三栏形态）；
/// [pushPanelOnNarrow] 给"本身就在面板里"的调用方关掉，避免叠两层整页。
Future<void> revealPreviewTab(
  BuildContext context,
  WidgetRef ref, {
  required PreviewSource source,
  required String title,
  required bool wide,
  bool pushPanelOnNarrow = true,
}) async {
  final tabs = ref.read(filePaneTabProvider.notifier);
  if (source.isMedia) {
    tabs.openMediaPreview(
      asset: source.asset!,
      title: title,
      conversationTitle: source.conversationTitle,
    );
  } else {
    tabs.openPreview(
      path: source.path,
      title: title,
      projectId: source.projectId,
    );
  }

  if (wide) {
    ref.read(filePaneVisibleProvider.notifier).show();
    return;
  }
  if (pushPanelOnNarrow && context.mounted) {
    await openPanelPage(context);
  }
}

/// 右栏里已经打开同一页面的浏览器标签；没有返回 null。
///
/// 只扫 [FilePaneTabState.browserTabs]（保持插入顺序），命中第一个。
/// 历史遗留的重复标签不主动关闭：那是用户开过的页，关不关由用户决定。
String? existingPreviewTab(
  WidgetRef ref, {
  required String url,
  String? display,
}) {
  for (final id in ref.read(filePaneTabProvider).browserTabs) {
    final session = ref.read(browserSessionProvider(id));
    if (isSamePreviewPage(
      url: url,
      display: display,
      tabDisplay: session.addressOverride,
      tabInternalUri: session.internalUri?.toString(),
    )) {
      return id;
    }
  }
  return null;
}

/// 这一页是不是 [tabDisplay] / [tabInternalUri] 那个标签正在看的页。
///
/// 判据是「页面身份」，不是标题：不同文件的页面可以同名，标题在加载完成前
/// 还是空的，页内导航也会把它改掉——按标题判会跳到错误的标签。
///
/// 两边都是预览站地址时以路径为准（见 [_previewPathKey]）：路径里有项目 /
/// 会话 id，不同会话里的同名草稿（`草稿/cat.html`）才不会互相顶掉。
/// 其余地址（dev server、公网页面）比服务端给的展示地址：真实地址里带随机
/// 端口与访问令牌，同一个文件每次打开都可能不同，没法直接比。
bool isSamePreviewPage({
  required String url,
  String? display,
  String? tabDisplay,
  String? tabInternalUri,
}) {
  final pathKey = _previewPathKey(url);
  final tabPathKey = _previewPathKey(tabInternalUri);
  if (pathKey != null && tabPathKey != null) {
    return pathKey == tabPathKey;
  }

  final label = display?.trim() ?? '';
  final tabLabel = tabDisplay?.trim() ?? '';
  return label.isNotEmpty && tabLabel == label;
}

/// 预览站地址去掉端口与令牌后的路径：`/f/<token>/<项目id>/<相对路径>` →
/// `f/<项目id>/<相对路径>`，草稿的 `/d/<token>/<会话id>/...` 同理。
///
/// 不是预览站形状（dev server、公网地址）时返回 null，交给展示地址判。
String? _previewPathKey(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.length < 4) {
    return null;
  }
  final scope = segments.first;
  if (scope != 'f' && scope != 'd') {
    return null;
  }
  return <String>[scope, segments[2], ...segments.skip(3)].join('/');
}
