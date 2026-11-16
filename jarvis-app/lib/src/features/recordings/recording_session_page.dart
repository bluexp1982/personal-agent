import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_models.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'recording_detail_page.dart';
import 'recording_waveform.dart';

/// 正在录音的页面。
///
/// 录音本身在全局控制器里，这一页只是它的一个视图：返回/收起不会停止录音，
/// 真正结束必须按「停止并保存」。
///
/// [embedded] 为真时嵌在宽屏中栏：不画 AppBar，改用三栏统一的细栏头；
/// 「收起」与「停止后去详情」都交给外壳（[onCollapse] / [onStopped]），
/// 否则 `Navigator.pop` 会把整个窗口的路由弹掉。
class RecordingSessionPage extends ConsumerStatefulWidget {
  const RecordingSessionPage({
    super.key,
    this.embedded = false,
    this.onCollapse,
    this.onStopped,
  });

  final bool embedded;

  /// 收起这一页（录音继续）。宽屏下回到录音列表。
  final VoidCallback? onCollapse;

  /// 停止并保存之后，带着这条录音去详情。
  final ValueChanged<LocalRecording>? onStopped;

  @override
  ConsumerState<RecordingSessionPage> createState() =>
      _RecordingSessionPageState();
}

class _RecordingSessionPageState extends ConsumerState<RecordingSessionPage> {
  /// 栏头图标按钮：命中区 24、8dp 圆角方形，与中栏其它页同一份规格。
  static final ButtonStyle _headerButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  bool _stopping = false;

  Future<void> _stop() async {
    if (_stopping) {
      return;
    }
    setState(() => _stopping = true);
    final recording = await ref
        .read(recordingControllerProvider.notifier)
        .stop();
    if (!mounted) {
      return;
    }
    setState(() => _stopping = false);

    final error = ref.read(recordingControllerProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }

    // 内嵌形态没有"上一页"：让外壳把中栏切到详情（或退回列表）。
    if (widget.embedded) {
      if (recording == null) {
        widget.onCollapse?.call();
        return;
      }
      widget.onStopped?.call(recording);
      return;
    }

    // 先取出 navigator 再 pop：pop 之后本页会被销毁，
    // 继续用它的 context 去 push 详情会拿到已失活的 Element。
    final navigator = Navigator.of(context);
    navigator.pop();
    if (recording == null) {
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailPage(local: recording),
      ),
    );
  }

  /// 收起：内嵌时回列表，整页时退掉这一层路由。录音都不受影响。
  void _collapse() {
    final collapse = widget.onCollapse;
    if (collapse != null) {
      collapse();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(recordingControllerProvider);
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final recording = session.recording;

    if (recording == null) {
      return AppPageScaffold(
        backgroundColor: widget.embedded
            ? paneSurfaceColor(Theme.of(context).colorScheme)
            : null,
        appBar: widget.embedded
            ? null
            : const MobileAppBar(title: '录音'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.embedded) _header('录音', null),
            Expanded(
              child: Center(child: Text('录音已经结束', style: text.body)),
            ),
          ],
        ),
      );
    }

    final mode = recording.mode;
    final segments = recording.segments;
    final liveText = segments
        .where((segment) => segment.text.trim().isNotEmpty)
        .map((segment) => segment.text.trim())
        .join('\n');

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时底色由骨架的渐变透上来；
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded
          ? paneSurfaceColor(Theme.of(context).colorScheme)
          : null,
      // 内嵌形态不画第二层 AppBar：外层已经是三栏统一的细栏头。
      appBar: widget.embedded
          ? null
          : MobileAppBar(
              leading: MobileTopBarButton(
                icon: Icons.keyboard_arrow_down,
                tooltip: '收起（录音继续）',
                onPressed: _collapse,
              ),
              title: _titleOf(mode),
              actions: <Widget>[_statusText(session)],
            ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.embedded) _header(_titleOf(mode), session),
            if (session.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _ErrorBanner(message: session.error!),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (!session.paused)
                        _PulsingDot(color: palette.status.danger),
                      const SizedBox(width: 8),
                      Text(
                        formatElapsed(session.elapsedMs),
                        // 计时是这一页唯一的主视觉，走展示型字阶；
                        // 不为了"大一点"新造 38 这种裸字号。
                        style: text.mono(
                          size: AppFontSize.displayLg,
                          height: AppLineHeight.tight,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  RecordingWaveform(
                    levels: session.levels,
                    color: session.paused
                        ? palette.status.warning
                        : palette.status.danger,
                    active: !session.paused,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _progressLine(recording),
                    textAlign: TextAlign.center,
                    style: text.meta,
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          mode == RecordingMode.realtime
                              ? Icons.subtitles_outlined
                              : Icons.schedule_outlined,
                          size: 16,
                          color: palette.text.tertiary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          mode == RecordingMode.realtime ? '实时转写' : '录音结束后统一转写',
                          style: text.meta,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: mode == RecordingMode.realtime
                          ? _LiveTranscript(text: liveText)
                          : Center(
                              child: Text(
                                '这一段不会上传。\n停止后按 ${formatElapsed(session.elapsedMs)} 整体上传并转写。',
                                textAlign: TextAlign.center,
                                style: text.hint,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: session.paused
                          ? () => ref
                                .read(recordingControllerProvider.notifier)
                                .resume()
                          : () => ref
                                .read(recordingControllerProvider.notifier)
                                .pause(),
                      icon: Icon(
                        session.paused ? Icons.play_arrow : Icons.pause,
                        size: 18,
                      ),
                      label: Text(session.paused ? '继续' : '暂停'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _stopping ? null : _stop,
                      icon: _stopping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop_circle_outlined, size: 18),
                      label: Text(_stopping ? '正在保存…' : '停止并保存'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _titleOf(RecordingMode mode) =>
      mode == RecordingMode.realtime ? '实时记录' : '批量录音';

  /// 「录音中 / 已暂停」：两种形态共用一份，字形与颜色只在这里改。
  Widget _statusText(RecordingSessionState session) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Text(
          session.paused ? '已暂停' : '录音中',
          style: text.meta.copyWith(
            color: session.paused
                ? palette.status.warning
                : palette.status.danger,
          ),
        ),
      ),
    );
  }

  /// 内嵌形态的栏头：左侧收起箭头，右侧录音状态。
  Widget _header(String title, RecordingSessionState? session) {
    return EmbeddedToolbar(
      title: title,
      leading: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: IconButton(
          tooltip: '收起（录音继续）',
          onPressed: _collapse,
          style: _headerButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ),
      actions: <Widget>[if (session != null) _statusText(session)],
    );
  }

  String _progressLine(LocalRecording recording) {
    if (recording.mode == RecordingMode.batch) {
      return '已录 ${recording.segments.length} 段 · 停止前不产生上传';
    }
    if (recording.segments.isEmpty) {
      return '等待第一段声音…';
    }
    final pending = recording.segments.length - recording.uploadedCount;
    if (pending <= 0) {
      return '${recording.segments.length} 段已上传 · 分段保存在本机';
    }
    return '已上传 ${recording.uploadedCount}/${recording.segments.length} 段 · 剩余 $pending 段在排队';
  }
}

class _LiveTranscript extends StatelessWidget {
  const _LiveTranscript({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final body = AppText.of(context);
    if (text.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('还在等第一段结束…说几个字，安静半秒就会出稿。', style: body.hint),
      );
    }
    return SingleChildScrollView(
      reverse: true,
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(text, style: body.body),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(palette.status.danger),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: palette.status.borderOf(palette.status.danger),
        ),
      ),
      child: Text(message, style: text.hint),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.35,
        end: 1,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
