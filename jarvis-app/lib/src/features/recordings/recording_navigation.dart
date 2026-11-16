import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_models.dart';
import 'recording_detail_page.dart';
import 'recording_session_page.dart';
import 'recordings_page.dart';

/// 录音笔记列表（整页）。
///
/// 只给窄屏与设置页这类"没有中栏可占"的入口用：宽屏左栏走
/// `shellTargetProvider` 的 `RecordingsTarget`，三页都在中栏原地切换。
Future<void> openRecordingsPage(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const RecordingsPage()));
}

/// 正在录音的页面。从列表页开始录音后推入，也可从全局状态条回来。
Future<void> openRecordingSession(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const RecordingSessionPage()));
}

/// 一条录音的详情。`local` 与 `server` 至少给一个：
/// - 本地录的：拿音频文件与上传状态；
/// - 只在服务端存在的（另一台设备录的）：从 `/audio` 下载归档。
Future<void> openRecordingDetail(
  BuildContext context, {
  LocalRecording? local,
  ServerRecording? server,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RecordingDetailPage(local: local, server: server),
    ),
  );
}

/// 启动后恢复录音账本：把被中断的录音标记完成，并续传未完成的上传。
///
/// 包在 `RootGate` 外层而不是塞进 `HomeShell` 的 build：`build` 会被调用很多次，
/// 而恢复只该在每个进程里跑一次。
class RecordingBootstrap extends ConsumerStatefulWidget {
  const RecordingBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RecordingBootstrap> createState() => _RecordingBootstrapState();
}

class _RecordingBootstrapState extends ConsumerState<RecordingBootstrap>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(recordingControllerProvider.notifier).restore();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/关窗口前把正在说的那段写盘。进程被系统杀掉时，
    // 至少已经闭合的分段都在，重启后能恢复并续传。
    //
    // 这里**不停止采集**：iOS 靠 Info.plist 的 `UIBackgroundModes: audio`
    // 保持进程与 AVAudioSession 存活，Android 靠录音期间的前台服务
    // （`recording_foreground.dart`），两端在锁屏/后台都会继续收 PCM；
    // 贸然 stop 会让回到前台后接不上（`AudioRecorder` 的 stop 不可逆）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(recordingControllerProvider.notifier).flushPartial());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
