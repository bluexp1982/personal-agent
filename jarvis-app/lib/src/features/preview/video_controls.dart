import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/ui/menu/agent_menu.dart';
import '../../core/ui/menu/menu_model.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/shell_layout_state.dart';
import 'video_playback.dart';

/// 视频底栏：播放 / 暂停、进度、时间、音量、倍速。
///
/// 与图片 / PDF 的 [PreviewToolbar] 分开：那一行表达的是"看图的倍率"，
/// 这一行表达的是"播放的时间轴"，混成一条只会在两处都塞不下。
///
/// 底栏不再放全屏键：进 / 出全屏由文件头按钮、Esc 与"双击画面"承担，
/// 那里才是用户看着画面时手会落到的位置。
///
/// 进度条自己持有拖动中的临时值：`onChanged` 期间如果直接吃播放器的
/// position，滑块会被 200ms 一次的位置回调拽回去，拖起来像卡住。
class VideoControls extends StatefulWidget {
  const VideoControls({super.key, required this.playback});

  final VideoPlayback playback;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  /// 拖动中的位置（毫秒）。null = 没在拖，显示播放器的真实位置。
  double? _scrubbing;

  static final ButtonStyle _buttonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  void _togglePlay() {
    unawaited(toggleVideoPlayback(widget.playback));
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final durationMs = playback.duration.inMilliseconds;
    final positionMs = _scrubbing ?? playback.position.inMilliseconds.toDouble();

    final textStyle = TextStyle(
      fontSize: AppFontSize.xs,
      color: palette.text.secondary,
      // 时间和倍速都是数字：固定字宽避免整条底栏左右抖。
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    Widget iconButton({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
    }) {
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        style: _buttonStyle,
        iconSize: kPaneHeaderIconSize,
        icon: Icon(icon),
      );
    }

    final progress = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        key: kVideoProgressKey,
        // 时长未知时禁用：给一条滑不到头的轨道比转圈更让人困惑。
        value: durationMs <= 0
            ? 0
            : positionMs.clamp(0, durationMs.toDouble()).toDouble(),
        max: durationMs <= 0 ? 1 : durationMs.toDouble(),
        onChanged: durationMs <= 0
            ? null
            : (value) => setState(() => _scrubbing = value),
        onChangeStart: durationMs <= 0
            ? null
            : (value) => setState(() => _scrubbing = value),
        onChangeEnd: durationMs <= 0
            ? null
            : (value) {
                setState(() => _scrubbing = null);
                playback.seek(Duration(milliseconds: value.round()));
              },
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 音量条取 120~160：够宽时按上限铺开（拖动更细腻），窄下来先收到 120，
        // 再窄就连 120 都挤不出来——那时退回"只留静音按钮"，音量仍可一键切换。
        // 阈值由同一组常量推导，别在别处再写一个魔法数字。
        final volumeWidth =
            (constraints.maxWidth -
                    kVideoControlsChromeWidth -
                    kVideoProgressMinWidth)
                .clamp(
                  kVideoVolumeWidthMin.toDouble(),
                  kVideoVolumeWidthMax.toDouble(),
                );
        final showVolumeSlider =
            constraints.maxWidth >=
            kVideoControlsChromeWidth +
                kVideoProgressMinWidth +
                kVideoVolumeWidthMin;

        return Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(
            children: <Widget>[
              iconButton(
                key: kVideoPlayPauseKey,
                // 空格是同一个动作的键盘入口，写进提示里才有人发现。
                tooltip: playback.playing ? '暂停（空格）' : '播放（空格）',
                icon: playback.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                onPressed: _togglePlay,
              ),
              Text(
                '${formatDuration(positionMs.round())} / '
                '${formatDuration(durationMs)}',
                style: textStyle,
              ),
              const SizedBox(width: 8),
              Expanded(child: progress),
              iconButton(
                key: kVideoMuteKey,
                tooltip: playback.volume <= 0 ? '取消静音' : '静音',
                icon: playback.volume <= 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                onPressed: () =>
                    playback.setVolume(playback.volume <= 0 ? 1 : 0),
              ),
              if (showVolumeSlider)
                SizedBox(
                  width: volumeWidth,
                  child: Slider(
                    key: kVideoVolumeKey,
                    value: playback.volume.clamp(0, 1).toDouble(),
                    onChanged: playback.setVolume,
                  ),
                ),
              // 走全站菜单组件：`PopupMenuButton` 那套白底 + 系统矩形悬停块
              // 与其它入口（会话「⋯」、录音倍速）不是一种语言。这里与录音
              // 详情页的倍速菜单逐项对齐：右对齐、120 宽、当前档打勾。
              AgentMenu<double>(
                width: kVideoSpeedMenuWidth,
                tooltip: '倍速',
                alignment: AlignmentDirectional.bottomEnd,
                alignmentOffset: AgentMenuStyle.rightAlignedOffset(
                  kVideoSpeedMenuWidth,
                ),
                // 触发器自己是 InkWell：再让组件接管点击会一次点击既开又关。
                triggerHandlesTap: false,
                groups: <AgentMenuGroup<double>>[
                  AgentMenuGroup<double>(
                    items: <AgentMenuItem<double>>[
                      for (final value in kVideoSpeedOptions)
                        AgentMenuItem<double>(
                          value: value,
                          label: '${_speedLabel(value)}×',
                          selected: playback.speed == value,
                        ),
                    ],
                  ),
                ],
                onSelected: playback.setSpeed,
                builder: (context, controller, open, hovering) => InkWell(
                  key: kVideoSpeedKey,
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '${_speedLabel(playback.speed)}×',
                      style: textStyle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// `1.0` / `1.5`：整数倍也要带一位小数，否则 1× 与 1.5× 的字宽差会让整行跳。
String _speedLabel(double speed) => speed.toStringAsFixed(1);

/// 倍速菜单的档位与宽度（与录音详情页的倍速菜单同一套口径）。
const List<double> kVideoSpeedOptions = <double>[0.5, 1, 1.5, 2];
const double kVideoSpeedMenuWidth = 120;

/// 音量滑条的宽度区间。
///
/// 76 宽拖动一格要跳十几个百分点，手指在触控板上几乎没法微调；160 大约
/// 是"一像素 < 1%"那档。再宽就得从进度条身上抢，进度条才是这一行的主角，
/// 所以封顶 160，而 120 是"还看得出是根滑条"的下限。
const double kVideoVolumeWidthMin = 120;
const double kVideoVolumeWidthMax = 160;

/// 进度条的弹性下限：被音量条挤到比这更窄时，进度条就拖不动了。
const double kVideoProgressMinWidth = 120;

/// 底栏两侧的固定开销（不含进度条与音量条）：
/// 左右内边距 24 + 播放键 24 + 时间文本 ≈110（`00:00:00 / 00:00:00`，
/// xs 等宽数字的最宽形态）+ 间隙 8 + 静音键 24 + 倍速 ≈34。
/// 是个估算值：宁可多留几像素，也不要让 Row 在长视频的时间文本上溢出。
const double kVideoControlsChromeWidth = 224;

/// 底栏上的稳定锚点：测试按 Key 找，不按图标字形找。
const Key kVideoPlayPauseKey = Key('video-play-pause');
const Key kVideoProgressKey = Key('video-progress');
const Key kVideoMuteKey = Key('video-mute');
const Key kVideoVolumeKey = Key('video-volume');
const Key kVideoSpeedKey = Key('video-speed');
