import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/media_cache.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/features/preview/code_view.dart';
import 'package:jarvis_app/src/features/preview/image_preview_view.dart';
import 'package:jarvis_app/src/features/preview/preview_toolbar.dart';
import 'package:jarvis_app/src/features/preview/video_controls.dart';
import 'package:jarvis_app/src/features/preview/video_playback.dart';
import 'package:jarvis_app/src/features/preview/video_scrub_bar.dart';
import 'package:jarvis_app/src/features/shell/file_preview_view.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

import '../support/fake_video_playback.dart';
import '../support/test_images.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

const String _path = '/tmp/hello-demo/pic.png';

class _FixedTarget extends ShellTargetController {
  @override
  ShellTarget? build() => const ProjectTarget(_project);
}

Widget _app({bool immersive = false}) {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(_FixedTarget.new),
      projectFileBytesProvider.overrideWith(
        (ref, key) => ProjectFileBytes(
          bytes: testPngBytes,
          size: testPngBytes.length,
          contentType: 'image/png',
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: FilePreviewView(path: _path, immersive: immersive),
        ),
      ),
    ),
  );
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

const String _videoPath = '/tmp/hello-demo/clip.mp4';

/// 模拟 `HomeShell`：沉浸状态由 provider 决定，再作为 `immersive` 传下去。
///
/// 直接给 `FilePreviewView` 传一个固定值测不出"点全屏后布局真的换了"——
/// 真实链路是 provider 变化驱动外壳重算 `immersive`。
class _VideoHost extends ConsumerWidget {
  const _VideoHost({required this.playback});

  final FakeVideoPlayback playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final immersive = ref.watch(immersiveFullscreenProvider) != null;
    return SizedBox(
      width: 400,
      height: 600,
      child: FilePreviewView(path: _videoPath, immersive: immersive),
    );
  }
}

Widget _videoApp({required FakeVideoPlayback playback}) {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(_FixedTarget.new),
      // 播放源直接给一个本地文件：真实现去下载 / 建临时目录，与这里要验证
      // 的"布局切换有没有重建播放器"无关。
      videoFileProvider.overrideWith((ref, key) async => File(_videoPath)),
      videoPlaybackFactoryProvider.overrideWithValue(() => playback),
    ],
    child: MaterialApp(
      home: Scaffold(body: _VideoHost(playback: playback)),
    ),
  );
}

const String _textPath = '/tmp/hello-demo/main.dart';

/// 文本预览也走同一个沉浸状态：进入后文件头收起，代码正文撑满。
class _TextHost extends ConsumerWidget {
  const _TextHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final immersive = ref.watch(immersiveFullscreenProvider) != null;
    return SizedBox(
      width: 400,
      height: 600,
      child: FilePreviewView(path: _textPath, immersive: immersive),
    );
  }
}

Widget _textApp() {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(_FixedTarget.new),
      projectFileContentProvider.overrideWith(
        (ref, key) => FileContent(
          path: key.path,
          size: 32,
          text: 'void main() {\n  print("hi");\n}\n',
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: _TextHost())),
  );
}

void main() {
  testWidgets('点全屏进的是面板的沉浸模式，不另开页面', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(_container(tester).read(immersiveFullscreenProvider), isNull);

    await tester.tap(find.byKey(kPreviewFullscreenKey));
    await tester.pumpAndSettle();

    expect(
      _container(tester).read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
      reason: '与终端同一个状态：进入后由 HomeShell 收掉左栏、中栏与标签栏',
    );
    // 没有 push 新路由：同一个预览组件仍在树里。
    expect(find.byType(FilePreviewView), findsOneWidget);
  });

  testWidgets('沉浸模式下文件头收起，内容与底栏保留', (tester) async {
    await tester.pumpWidget(_app(immersive: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(kPreviewFullscreenKey),
      findsNothing,
      reason: '文件头整条不渲染，全屏按钮也跟着没了',
    );
    expect(find.byKey(kPreviewSaveKey), findsNothing);
    // 内容与底栏还在：满屏之后仍要能缩放。
    expect(find.byType(ImagePreviewView), findsOneWidget);
    expect(find.byType(PreviewToolbar), findsOneWidget);
  });

  testWidgets('视频进沉浸态收掉底栏，且不重建播放器', (tester) async {
    final playback = FakeVideoPlayback();
    await tester.pumpWidget(_videoApp(playback: playback));
    await tester.pumpAndSettle();

    expect(find.byKey(kVideoPlayPauseKey), findsOneWidget);
    expect(playback.opens, 1);

    await tester.tap(find.byKey(kPreviewFullscreenKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kVideoPlayPauseKey), findsNothing, reason: '满屏只剩画面');
    expect(find.byKey(kVideoScrubKey), findsOneWidget);
    // 文件头换成占位后 `Expanded` 槽位不变：播放器实例应当还活着。
    expect(playback.opens, 1, reason: '切全屏不该让视频从头重开');
    expect(playback.disposed, isFalse);
  });

  testWidgets('文本预览也能整窗全屏，沉浸态收起文件头但保留正文', (tester) async {
    await tester.pumpWidget(_textApp());
    await tester.pumpAndSettle();

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);

    await tester.tap(find.byKey(kPreviewFullscreenKey));
    await tester.pumpAndSettle();

    expect(
      _container(tester).read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
      reason: '文本与图片共用同一个沉浸状态，不另造一套全屏',
    );
    expect(find.byKey(kPreviewFullscreenKey), findsNothing);
    expect(find.byKey(kPreviewSaveKey), findsNothing);
    // 槽位用占位保住，正文组件不重建：代码与滚动位置都还在。
    expect(find.byType(CodeView), findsOneWidget);
    expect(find.textContaining('void main', findRichText: true), findsWidgets);
  });

  testWidgets('退出沉浸模式是幂等的', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final controller = _container(tester).read(
      immersiveFullscreenProvider.notifier,
    );
    await controller.enter(ImmersiveSurface.panel);
    await tester.pumpAndSettle();
    expect(
      _container(tester).read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
    );

    controller.exit();
    controller.exit();
    await tester.pumpAndSettle();
    expect(_container(tester).read(immersiveFullscreenProvider), isNull);
  });
}
