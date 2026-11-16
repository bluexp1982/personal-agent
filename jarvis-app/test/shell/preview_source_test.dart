import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/preview_source.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';

const MediaAsset _image = MediaAsset(
  id: 'img_1',
  kind: 'image',
  mime: 'image/png',
  bytes: 2048,
  width: 8,
  height: 8,
);

const MediaAsset _video = MediaAsset(
  id: 'vid_1',
  kind: 'video',
  mime: 'video/mp4',
  bytes: 4096,
  durationMs: 5000,
  resolution: '480P',
);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('媒体预览：id 带前缀，来源里带资产与会话标题', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openMediaPreview(
      asset: _image,
      title: '图片 10:00',
      conversationTitle: '季度复盘',
    );

    final state = container.read(filePaneTabProvider);
    expect(state.previews.single.path, PreviewSource.mediaTabId('img_1'));
    expect(state.previewTitle(PreviewSource.mediaTabId('img_1')), '图片 10:00');
    final source = state.previewSourceOf(PreviewSource.mediaTabId('img_1'));
    expect(source?.isMedia, isTrue);
    expect(source?.asset?.id, 'img_1');
    expect(source?.conversationTitle, '季度复盘');
  });

  test('同一个资产重复打开只切标签，不新增', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openMediaPreview(asset: _video, title: '视频 10:00');
    tabs.openMediaPreview(asset: _video, title: '视频 10:01');

    final state = container.read(filePaneTabProvider);
    expect(state.tabs.where((tab) => tab.kind == FilePaneTab.preview).length, 1);
    // 最新一次打开的标题要覆盖旧值：产物可能在两次打开之间重新生成过。
    expect(state.previewTitle(PreviewSource.mediaTabId('vid_1')), '视频 10:01');
  });

  test('项目文件预览：显式带上项目 id，右侧栏不再靠 shell 目标猜', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openPreview(path: 'notes.md', title: 'notes.md', projectId: 'p1');

    final state = container.read(filePaneTabProvider);
    expect(state.previews.single.path, 'notes.md');
    expect(state.previewSourceOf('notes.md')?.projectId, 'p1');
  });

  test('不带项目 id 的文件预览不登记来源（保持文件树的隐式口径）', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openPreview(path: '/tmp/a.txt', title: 'a.txt');

    final state = container.read(filePaneTabProvider);
    expect(state.previewSourceOf('/tmp/a.txt'), isNull);
  });

  test('关掉标签会连来源一起清掉', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openMediaPreview(asset: _image, title: '图片 10:00');
    tabs.closePreview(PreviewSource.mediaTabId('img_1'));

    final state = container.read(filePaneTabProvider);
    expect(state.previews, isEmpty);
    expect(state.previewSources, isEmpty);
  });

  test('切项目会关掉预览并清空来源表', () {
    final container = _container();
    final tabs = container.read(filePaneTabProvider.notifier);

    tabs.openPreview(path: 'notes.md', title: 'notes.md', projectId: 'p1');
    tabs.resetForProject();

    final state = container.read(filePaneTabProvider);
    expect(state.hasPreview, isFalse);
    expect(state.previewSources, isEmpty);
    expect(state.previewTitles, isEmpty);
  });

  test('媒体标签 id 不会与真实路径混淆', () {
    expect(PreviewSource.mediaTabId('img_1'), 'media:img_1');
    expect(PreviewSource.looksLikeMediaTab('media:img_1'), isTrue);
    expect(PreviewSource.looksLikeMediaTab('/tmp/media:img_1'), isFalse);
  });
}
