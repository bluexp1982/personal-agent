import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../shell/shell_layout_state.dart';
import 'video_controls.dart';
import 'video_playback.dart';
import 'video_scrub_bar.dart';

/// 视频查看器：画面 + 底栏控件。
///
/// 与图片 / PDF 查看器同一套契约：只接收"要看的东西"，不负责下载、
/// 不自己判断宿主。数据从哪来由外面决定（右栏标签走项目文件，
/// 会话产物走媒体端点），于是同一个组件在两处表现一致。
///
/// 全屏也交回宿主：右栏里是沉浸模式（`immersiveFullscreenProvider`），
/// 会话里"打开"进来的本身就是一条满屏路由，不需要再叠一层。
/// 起播前那张封面的稳定锚点（测试按它判断"有没有铺上封面"）。
const Key kVideoPosterKey = Key('video-preview-poster');

class VideoPreviewView extends ConsumerStatefulWidget {
  const VideoPreviewView({
    super.key,
    required this.path,
    required this.file,
    this.poster,
    this.onToggleFullscreen,
    this.onOpenWithSystem,
    this.immersive = false,
  });

  /// 文件标识，只用于"换了文件就重开播放器"以及错误提示。
  final String path;

  /// 已落盘的本地文件。不直接吃网络地址：服务端的字节端点不支持 Range，
  /// 交给播放器拖动进度会失效。
  final File file;

  /// 封面（服务端抽的第一帧）。起播前铺在画面上，避免先黑一块再出画；
  /// 为空时保持原来的黑底。
  final Uint8List? poster;

  /// 双击画面时切换全屏。为空表示宿主已经满屏（会话里"打开"进来的独立
  /// 预览路由），此时双击不响应，单击播停保持零延迟。
  final VoidCallback? onToggleFullscreen;

  /// 解码失败时的兜底：交给系统播放器。为空时错误页只给一句说明。
  final VoidCallback? onOpenWithSystem;

  /// 宿主已满屏（沉浸模式）。
  ///
  /// 满屏时整条底栏不渲染，只在画面底部留一条半透明细进度条：全屏就是
  /// "只剩视频"，播放键 / 时间 / 音量 / 倍速都不该再占画面。播停仍可
  /// 空格或点画面，退出全屏仍是双击画面或 Esc。
  final bool immersive;

  @override
  ConsumerState<VideoPreviewView> createState() => _VideoPreviewViewState();
}

class _VideoPreviewViewState extends ConsumerState<VideoPreviewView> {
  VideoPlayback? _playback;

  /// 建播放器或打开文件失败的提示（与解码错误分开：这条来自我们自己的调用）。
  String? _openError;

  /// 空格播停的落点：只有焦点落在这棵子树里才响应。
  ///
  /// 不做成全局快捷键是刻意的——右栏常与聊天输入框同屏，全局吃空格会
  /// 把用户打字的空格变成"暂停"，那是不能接受的副作用。
  final FocusNode _focus = FocusNode(debugLabel: 'video-preview');

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant VideoPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _disposePlayback();
      _start();
    }
  }

  @override
  void dispose() {
    _disposePlayback();
    _focus.dispose();
    super.dispose();
  }

  /// 空格 = 播放 / 暂停。
  ///
  /// 只认按下那一刻（`KeyDownEvent`）：跟着 `KeyRepeatEvent` 走的话，长按
  /// 空格会在播放与暂停之间反复横跳。焦点落在底栏按钮上时，按钮自己的
  /// `ActivateIntent` 会先把事件消费掉，不会冒泡到这里变成"双触发"。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final playback = _playback;
    if (playback == null || playback.error != null) {
      return KeyEventResult.ignored;
    }
    unawaited(toggleVideoPlayback(playback));
    return KeyEventResult.handled;
  }

  void _disposePlayback() {
    final playback = _playback;
    _playback = null;
    playback?.dispose();
  }

  void _start() {
    _openError = null;
    try {
      final playback = ref.read(videoPlaybackFactoryProvider)();
      _playback = playback;
      // `open` 是异步的：失败时把原因留在界面上，不要让异常冒到 zone 里
      // （那会是一条红屏，用户拿不到"这段视频为什么放不了"）。
      playback.open(widget.file).catchError((Object error) {
        if (!mounted) {
          return;
        }
        setState(() => _openError = '视频打开失败：$error');
      });
    } catch (error) {
      _openError = '视频内核不可用：$error';
    }
  }

  void _retry() {
    setState(() {
      _disposePlayback();
      _start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    if (playback == null) {
      return _errorStage(_openError ?? '视频打开失败');
    }

    // 焦点只圈住预览器这一块。`autofocus` 用的是 Flutter 原生语义：所属
    // scope 里已经有别人拿着焦点时不会抢，所以右栏开着视频、用户在聊天框
    // 打字时不会被打断；点一下画面则明确把焦点要过来，空格从此作用于它。
    return Focus(
      focusNode: _focus,
      autofocus: true,
      // 不参与 Tab 顺序：该被 Tab 走到的是底栏那几枚按钮。
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: AnimatedBuilder(
        animation: playback,
        builder: (context, _) {
          return Column(
            children: <Widget>[
              Expanded(child: _stage(context, playback)),
              // 槽位恒定：用占位而不是"immersive 就不加这个子级"。
              // 子级数量一变，`Expanded` 会换到另一个槽位上被当成新子树，
              // 播放器跟着重开——双击进出全屏时视频会从头开始。
              if (widget.immersive)
                const SizedBox.shrink()
              else
                VideoControls(playback: playback),
            ],
          );
        },
      ),
    );
  }

  /// 画面区。纯黑底不走主题：视频四周的 letterbox 是内容的一部分，
  /// 浅色主题下换成白底会把画面衬得像没加载出来。
  Widget _stage(BuildContext context, VideoPlayback playback) {
    final error = _openError ?? playback.error;
    if (error != null) {
      return _errorStage(error);
    }

    final toggleFullscreen = widget.onToggleFullscreen;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GestureDetector(
            // 点画面播放 / 暂停：桌面与移动端都是最直觉的那一下。
            behavior: HitTestBehavior.opaque,
            onTap: () {
              // 点画面同时是在"选中这块内容"：顺手把键盘焦点要过来，
              // 否则空格没有落点，用户还得先 Tab 一圈。
              _focus.requestFocus();
              unawaited(toggleVideoPlayback(playback));
            },
            // 双击进 / 退沉浸全屏。挂了双击之后，Flutter 的 tap 识别器要等
            // `kDoubleTapTimeout`（约 300ms）才能确认"这只是一次单击"，于是
            // 单击播停会慢约 300ms——主流播放器同样如此，换来的是双击不会
            // 顺带改播放状态。满屏路由（回调为空）没有全屏语义，此时压根不
            // 挂双击识别器，单击保持零延迟。
            onDoubleTap: toggleFullscreen == null
                ? null
                : () {
                    _focus.requestFocus();
                    toggleFullscreen();
                  },
            child: playback.buildSurface(),
          ),
          // 还没起播（缓冲区里还没有第一帧）时铺封面：比黑屏更早告诉用户
          // "这段视频长什么样"。一旦播过或拖过进度就撤掉，不遮住当前画面。
          if (widget.poster != null &&
              !playback.playing &&
              playback.position == Duration.zero)
            IgnorePointer(
              child: Image.memory(
                widget.poster!,
                key: kVideoPosterKey,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          if (!playback.ready || playback.buffering)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
            ),
          // 满屏时底栏整条没了，进度只剩这条线。放在最后：它要压在画面与
          // 封面之上，否则全屏起播前那一下点不到。
          if (widget.immersive)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoScrubBar(playback: playback),
            ),
        ],
      ),
    );
  }

  Widget _errorStage(String message) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_outlined, size: 28, color: palette.text.tertiary),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                height: AppLineHeight.relaxed,
                color: palette.text.tertiary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                TextButton(onPressed: _retry, child: const Text('重试')),
                if (widget.onOpenWithSystem != null)
                  TextButton(
                    onPressed: widget.onOpenWithSystem,
                    child: const Text('用系统应用打开'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
