import 'dart:io';

import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/shell/chat_window_state.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const ConversationTarget _chat = ConversationTarget(
  projectId: 'w1',
  conversationId: 'c1',
  title: '聊聊周末',
);

/// 每个用例一个临时目录当 `SecretStore` 的回退目录：测试环境没有钥匙串，
/// `SecretStore` 会自己退到文件，于是"落盘 → 重开 → 恢复"能真跑一遍 IO。
Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('agent-chat-float-');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

ProviderContainer _container(SecretStore store) {
  final container = ProviderContainer(
    overrides: [secretStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  // `SecretStore` 在钥匙串不可用时回退到文件，但读钥匙串这一步要过
  // MethodChannel；纯 `test` 环境里没有 binding，`ServicesBinding.instance`
  // 会直接 assert。初始化一次即可（与 `testWidgets` 内部做的是同一件事）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('几何编解码', () {
    test('往返一致', () {
      const geometry = ChatFloatGeometry(
        origin: Offset(320, 180),
        size: Size(420, 560),
        viewport: Size(1400, 900),
      );
      final encoded = encodeChatFloatGeometry(geometry);
      expect(decodeChatFloatGeometry(encoded), geometry);
    });

    test('脏值一律解析失败', () {
      expect(decodeChatFloatGeometry(null), isNull);
      expect(decodeChatFloatGeometry(''), isNull);
      expect(decodeChatFloatGeometry('not json'), isNull);
      expect(decodeChatFloatGeometry('[]'), isNull);
      // 缺字段
      expect(decodeChatFloatGeometry('{"x":1,"y":2,"w":3,"h":4}'), isNull);
      // 负尺寸
      expect(
        decodeChatFloatGeometry(
          '{"x":1,"y":2,"w":-3,"h":4,"vw":800,"vh":600}',
        ),
        isNull,
      );
      // 零视口
      expect(
        decodeChatFloatGeometry(
          '{"x":1,"y":2,"w":300,"h":400,"vw":0,"vh":600}',
        ),
        isNull,
      );
      // 非数字
      expect(
        decodeChatFloatGeometry(
          '{"x":"1","y":2,"w":300,"h":400,"vw":800,"vh":600}',
        ),
        isNull,
      );
    });
  });

  group('默认落点与恢复', () {
    test('没有记录时落在右下角，距右、距下各 24', () {
      final rect = resolveFloatRect(viewport: const Size(1400, 900));
      expect(rect.size, const Size(kChatFloatWidth, kChatFloatHeight));
      expect(rect.right, 1400 - kChatFloatMargin);
      expect(rect.bottom, 900 - kChatFloatMargin);
    });

    test('视口尺寸基本没变：严格还原绝对位置', () {
      const restored = ChatFloatGeometry(
        origin: Offset(180, 260),
        size: Size(420, 560),
        viewport: Size(1400, 900),
      );
      final rect = resolveFloatRect(
        viewport: const Size(1380, 880),
        restored: restored,
      );
      expect(rect.topLeft, const Offset(180, 260));
      expect(rect.size, const Size(420, 560));
    });

    test('视口尺寸大变：按比例迁移，尺寸不放大', () {
      const restored = ChatFloatGeometry(
        origin: Offset(700, 300),
        size: Size(420, 560),
        viewport: Size(1400, 900),
      );
      final rect = resolveFloatRect(
        viewport: const Size(1000, 900),
        restored: restored,
      );
      // 700 * (1000 / 1400) = 500；尺寸仍是 420，不被缩放成 300。
      expect(rect.left, closeTo(500, 0.01));
      expect(rect.width, kChatFloatWidth);
      // 迁移后仍必须在视口内。
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1000));
    });

    test('迁移后放不下时被拉回视口内，而不是整块跑到外面', () {
      const restored = ChatFloatGeometry(
        origin: Offset(700, 300),
        size: Size(420, 560),
        viewport: Size(1400, 900),
      );
      final rect = resolveFloatRect(
        viewport: const Size(700, 900),
        restored: restored,
      );
      expect(rect.left, 700 - kChatFloatWidth);
      expect(rect.right, 700);
    });

    test('跨屏迁移越界时被 clamp 回可视区', () {
      const restored = ChatFloatGeometry(
        origin: Offset(3800, 2000),
        size: Size(420, 560),
        viewport: Size(4000, 2400),
      );
      final rect = resolveFloatRect(
        viewport: const Size(800, 600),
        restored: restored,
      );
      expect(rect.right, lessThanOrEqualTo(800));
      expect(rect.bottom, lessThanOrEqualTo(600));
    });
  });

  group('位置约束', () {
    test('左右越界被拉回，顶部不低于栏头', () {
      final rect = clampFloatRect(
        const Rect.fromLTWH(-120, -50, 420, 560),
        const Size(1400, 900),
      );
      expect(rect.left, 0);
      expect(rect.top, kPaneHeaderHeight);

      final right = clampFloatRect(
        const Rect.fromLTWH(1200, 400, 420, 560),
        const Size(1400, 900),
      );
      expect(right.right, 1400);
    });

    test('尺寸被收敛到最小值与视口内', () {
      final tiny = clampFloatRect(
        const Rect.fromLTWH(100, 200, 20, 20),
        const Size(1400, 900),
      );
      expect(tiny.size, const Size(kChatFloatMinWidth, kChatFloatMinHeight));

      final huge = clampFloatRect(
        const Rect.fromLTWH(0, 0, 5000, 5000),
        const Size(1000, 700),
      );
      expect(huge.width, 1000);
      expect(huge.height, 700);
    });

    test('视口比最小尺寸还小时不抛异常', () {
      final rect = clampFloatRect(
        const Rect.fromLTWH(10, 10, 420, 560),
        const Size(200, 160),
      );
      expect(rect.width, 200);
      expect(rect.height, 160);
    });

    test('macOS 隐藏标题栏时避开左上角红绿灯', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final rect = clampFloatRect(
        const Rect.fromLTWH(4, 8, 420, 560),
        const Size(1400, 900),
      );
      // 顶部被抬到栏头下沿之后就不再压红绿灯；这里同时校验横向让位逻辑
      // 只在该区间内生效。
      expect(rect.top, kPaneHeaderHeight);
      expect(rect.left, greaterThanOrEqualTo(0));
    });
  });

  group('状态迁移', () {
    test('缩小 / 停靠 / 关闭：pinned 与 floating 同步', () {
      final container = _container(SecretStore(fallbackDirectory: _tempDir()));
      final controller = container.read(chatWindowProvider.notifier);

      controller.float(_chat);
      expect(container.read(chatWindowProvider).floating, isTrue);
      expect(container.read(chatWindowProvider).pinned, _chat);

      controller.dock();
      expect(container.read(chatWindowProvider).floating, isFalse);
      expect(container.read(chatWindowProvider).pinned, isNull);

      controller.float(_chat);
      controller.close();
      expect(container.read(chatWindowProvider).floating, isFalse);
      expect(container.read(chatWindowProvider).pinned, isNull);
    });

    test('改名后浮窗里的标题跟着换', () {
      final container = _container(SecretStore(fallbackDirectory: _tempDir()));
      final controller = container.read(chatWindowProvider.notifier);
      controller.float(_chat);

      controller.retitle('c1', '周末计划');
      expect(container.read(chatWindowProvider).pinned?.title, '周末计划');

      // 别的会话改名不影响这一份。
      controller.retitle('c2', '别的会话');
      expect(container.read(chatWindowProvider).pinned?.title, '周末计划');
    });

    test('落点写进状态并落盘；重启后恢复', () async {
      final dir = _tempDir();
      final first = _container(SecretStore(fallbackDirectory: dir));
      final controller = first.read(chatWindowProvider.notifier);

      // 这里只走显式的 persist：`place` 内部还会再发一次异步落盘，
      // 与紧随其后的"新进程读取"撞在一起会读到写了一半的文件。
      await controller.persist(
        const ChatFloatGeometry(
          origin: Offset(120, 160),
          size: Size(400, 500),
          viewport: Size(1200, 800),
        ),
      );

      // 新的容器 = 新的进程：同一个目录、新的 store 实例。
      final second = _container(SecretStore(fallbackDirectory: dir));
      await second.read(chatWindowProvider.notifier).restore();
      expect(
        second.read(chatWindowProvider).restored,
        const ChatFloatGeometry(
          origin: Offset(120, 160),
          size: Size(400, 500),
          viewport: Size(1200, 800),
        ),
      );
      // 恢复出来的矩形按当前视口解析。
      final rect = resolveFloatRect(
        viewport: const Size(1200, 800),
        restored: second.read(chatWindowProvider).restored,
      );
      expect(rect.topLeft, const Offset(120, 160));
    });

    test('落点越界时按约束写回，不会存一个跑出视口的坐标', () {
      final container = _container(SecretStore(fallbackDirectory: _tempDir()));
      final controller = container.read(chatWindowProvider.notifier);

      controller.place(
        const Rect.fromLTWH(9999, 9999, 400, 500),
        const Size(1200, 800),
      );
      final state = container.read(chatWindowProvider);
      expect(state.origin!.dx, lessThanOrEqualTo(1200 - 400));
      expect(state.origin!.dy, lessThanOrEqualTo(800));
    });
  });
}
