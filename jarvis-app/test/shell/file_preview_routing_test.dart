import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/media_cache.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/features/preview/image_preview_view.dart';
import 'package:jarvis_app/src/features/preview/markdown_preview_view.dart';
import 'package:jarvis_app/src/features/preview/video_playback.dart';
import 'package:jarvis_app/src/features/preview/video_preview_view.dart';
import 'package:jarvis_app/src/features/shell/file_preview_view.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

import '../support/fake_video_playback.dart';
import '../support/test_images.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

class _FixedTarget extends ShellTargetController {
  @override
  ShellTarget? build() => const ProjectTarget(_project);
}

/// 记录两个端点各被请求了什么：路由错了会立刻暴露成"图片问了 /file"。
class _Calls {
  final List<String> text = <String>[];
  final List<String> bytes = <String>[];
}

Widget _harness({
  required String path,
  required _Calls calls,
  required Uint8List png,
  /// 传了就按视频跑：播放源换成这个路径，内核换成假实现。
  FakeVideoPlayback? playback,
  /// 传了就按会话产物跑：字节走 `/api/media`，与项目端点无关。
  MediaAsset? asset,
}) {
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(_FixedTarget.new),
      projectFileContentProvider.overrideWith((ref, key) {
        calls.text.add(key.path);
        return FileContent(
          path: key.path,
          size: 12,
          text: 'hello world\n',
        );
      }),
      projectFileBytesProvider.overrideWith((ref, key) {
        calls.bytes.add(key.path);
        return ProjectFileBytes(
          bytes: png,
          size: png.length,
          contentType: 'image/png',
        );
      }),
      if (playback != null) ...[
        // 真实现要下载到临时目录并碰 libmpv：测试里只验"路由到视频查看器"。
        videoFileProvider.overrideWith((ref, key) => File(path)),
        videoPlaybackFactoryProvider.overrideWithValue(() => playback),
      ],
      if (asset != null)
        mediaImageBytesProvider.overrideWith((ref, id) => png),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: FilePreviewView(path: path, asset: asset),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('图片只请求原始字节端点，不碰文本端点', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _harness(
        path: '/tmp/hello-demo/pic.png',
        calls: calls,
        png: testPngBytes,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImagePreviewView), findsOneWidget);
    expect(calls.bytes, <String>['/tmp/hello-demo/pic.png']);
    expect(
      calls.text,
      isEmpty,
      reason: '图片若先请求 /file，用户会先看到一次"二进制文件无法预览"',
    );
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
  });

  testWidgets('文本仍走文本端点，不请求字节', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _harness(
        path: '/tmp/hello-demo/note.txt',
        calls: calls,
        png: testPngBytes,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello world'), findsOneWidget);
    expect(calls.text, <String>['/tmp/hello-demo/note.txt']);
    expect(calls.bytes, isEmpty);
    // 文本预览与图片 / PDF 一样有整窗全屏与另存为：入口在同一张文件头上。
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
  });

  testWidgets('Markdown 走文档渲染查看器，并给出源码开关', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _harness(
        path: '/tmp/hello-demo/README.md',
        calls: calls,
        png: testPngBytes,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownPreviewView), findsOneWidget);
    // 仍然只请求文本端点：渲染是客户端的事，不需要原始字节。
    expect(calls.text, <String>['/tmp/hello-demo/README.md']);
    expect(calls.bytes, isEmpty);
    expect(find.byKey(kMarkdownSourceToggleKey), findsOneWidget);
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
  });

  testWidgets('视频走视频查看器，不去请求文本端点', (tester) async {
    final calls = _Calls();
    final playback = FakeVideoPlayback();

    await tester.pumpWidget(
      _harness(
        path: '/tmp/hello-demo/clip.mp4',
        calls: calls,
        png: testPngBytes,
        playback: playback,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(VideoPreviewView), findsOneWidget);
    expect(playback.opens, 1);
    expect(
      calls.text,
      isEmpty,
      reason: '视频若先请求 /file，用户会先吃一次"二进制文件无法预览"',
    );
    expect(
      calls.bytes,
      isEmpty,
      reason: '视频不走整片进内存的字节 provider',
    );
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
  });

  testWidgets('会话产物来源：图片走 /api/media，不碰项目端点', (tester) async {
    final calls = _Calls();

    await tester.pumpWidget(
      _harness(
        path: 'img_1',
        calls: calls,
        png: testPngBytes,
        asset: const MediaAsset(
          id: 'img_1',
          kind: 'image',
          mime: 'image/png',
          bytes: 2048,
          width: 8,
          height: 8,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImagePreviewView), findsOneWidget);
    expect(
      calls.bytes,
      isEmpty,
      reason: '产物不在项目目录里，不该请求 /api/projects/{id}/raw',
    );
    expect(calls.text, isEmpty);
    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
  });

  testWidgets('不支持的格式给出明确文案，并可另存为', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _harness(
        path: '/tmp/hello-demo/logo.svg',
        calls: calls,
        png: testPngBytes,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('暂不支持该格式'), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
    // 不支持的类型没有"全屏"——点开也只会是一屏同样的提示。
    expect(find.byKey(kPreviewFullscreenKey), findsNothing);
  });
}
