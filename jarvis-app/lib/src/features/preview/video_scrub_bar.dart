import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_formatters.dart';
import '../shell/shell_layout_state.dart';
import 'video_playback.dart';

/// 沉浸全屏下的替身进度条：一条 3dp 的半透明白细线 + 右端一行极小的时间。
///
/// 全屏时底栏（播放键 / 时间 / 音量 / 倍速）整条不渲染，这里只回答"播到哪了"。
/// 但"能拖"这件事不能丢——为了调进度先退出全屏是会骂人的，所以视觉上看不见
/// 的命中区放宽到 12dp：线还是细线，鼠标 / 手指却好按。
///
/// 静息态刻意淡到"几乎只剩一道白边"：全屏是看片，不是调参；鼠标移进来
/// （悬停整条，含时间行）才恢复到可读的清晰度。触摸端没有悬停，就一直是淡态。
///
/// 为什么不用 `Slider`：Material 滑块自带的最小轨道高度、滑块圆点与覆盖层会
/// 把"3dp 细线 + 零内边距铺满"直接顶掉，样式也压不到这么干净。
class VideoScrubBar extends StatefulWidget {
  const VideoScrubBar({super.key, required this.playback});

  final VideoPlayback playback;

  @override
  State<VideoScrubBar> createState() => _VideoScrubBarState();
}

class _VideoScrubBarState extends State<VideoScrubBar> {
  /// 拖动中的位置（毫秒）。null = 没在拖，显示播放器的真实位置。
  ///
  /// 与底栏进度条同一个理由：拖动期间直接吃播放器的 position，会被
  /// 200ms 一次的位置回调拽回去，拖起来像卡住。
  double? _dragging;

  /// 鼠标是否停在整条上（线条 + 时间）。只影响透明度，不影响布局。
  bool _hovering = false;

  void _setHovering(bool value) {
    if (!mounted || _hovering == value) {
      return;
    }
    setState(() => _hovering = value);
  }

  void _updateFrom(double dx, double width) {
    final durationMs = widget.playback.duration.inMilliseconds;
    if (durationMs <= 0 || width <= 0) {
      return;
    }
    setState(() {
      _dragging = (dx / width).clamp(0.0, 1.0) * durationMs;
    });
  }

  /// 松手（或点完）才交给播放器：拖动过程只动本地值。
  void _commit() {
    final value = _dragging;
    setState(() => _dragging = null);
    if (value == null) {
      return;
    }
    widget.playback.seek(Duration(milliseconds: value.round()));
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.playback.duration.inMilliseconds;
    final enabled = durationMs > 0;
    final positionMs =
        _dragging ?? widget.playback.position.inMilliseconds.toDouble();
    final fraction = enabled
        ? (positionMs / durationMs).clamp(0.0, 1.0).toDouble()
        : 0.0;

    // "用户正在关心进度"的三个时刻：暂停、鼠标悬停、正在拖动。三者共用同一档
    // 亮度——暂停本身就是"要看一眼进度"，没理由比悬停还淡。
    final active = !widget.playback.playing || _hovering || _dragging != null;
    final trackAlpha = active ? _kTrackAlphaActive : _kTrackAlphaPlaying;
    final playedAlpha = active ? _kPlayedAlphaActive : _kPlayedAlphaPlaying;

    // 时间只在同一批时刻出现。播放中整行不渲染（不是把字调透明）：看片时
    // 角落里常驻一串数字，比一条淡线更碍眼。
    final showTime = active;

    return MouseRegion(
      // 只做悬停感知：opaque 为假，画面底部的点击还落得到下面那层播停 / 双击。
      opaque: false,
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => _setHovering(true),
      onExit: (_) => _setHovering(false),
      child: SizedBox(
        height: kVideoScrubBarHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: <Widget>[
                // 时间行永不拦事件：它压在画面右下角，那一小块仍要能播停 /
                // 双击全屏。取色直接复用 `playedAlpha`：时间是进度条的一部分，
                // 跟已播段同色，不单独设档——否则会出现"线条极淡、时间很亮"
                // 的割裂感。
                // 槽位必须恒定，只换里面的子件：这里如果用 `if (showTime)`
                // 把它从 Stack 里摘掉，后面那个 `Positioned`（命中带）会被顶到
                // 另一个槽位上重建——正在进行的拖动手势随之作废，松手收不到
                // `onHorizontalDragEnd`，`_dragging` 就永远停在那里。
                Positioned(
                  right: kPaneContentInset,
                  bottom: kVideoScrubHitHeight,
                  child: showTime
                      ? IgnorePointer(
                          child: Text(
                            '${formatDuration(positionMs.round())} / '
                            '${formatDuration(durationMs)}',
                            key: kVideoScrubTimeKey,
                            style: TextStyle(
                              fontSize: AppFontSize.xs,
                              height: AppLineHeight.tight,
                              color: AppColors.onAccent.withValues(
                                alpha: playedAlpha,
                              ),
                              // 时间是数字：固定字宽，否则秒数变化时整行会左右跳。
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                // 命中带：只有这 12dp 接手势。把整条 26dp 都做成热区的话，
                // 画面底部的点击区会被无谓吃掉一截。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: kVideoScrubHitHeight,
                  child: GestureDetector(
                    key: kVideoScrubKey,
                    behavior: HitTestBehavior.opaque,
                    // 时长未知时什么都不接：一条永远不动的线比没有更让人困惑。
                    // 用 `onTapUp` 而不是 `onTapDown`：按下去就 seek 会让"按住
                    // 准备拖"的那一下先把进度跳走。
                    onTapUp: enabled
                        ? (details) {
                            _updateFrom(details.localPosition.dx, width);
                            _commit();
                          }
                        : null,
                    onHorizontalDragStart: enabled
                        ? (details) =>
                              _updateFrom(details.localPosition.dx, width)
                        : null,
                    onHorizontalDragUpdate: enabled
                        ? (details) =>
                              _updateFrom(details.localPosition.dx, width)
                        : null,
                    onHorizontalDragEnd: enabled ? (_) => _commit() : null,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        height: kVideoScrubHeight,
                        width: width,
                        child: DecoratedBox(
                          // 压在黑底视频上，走白色系半透明：主题色在任意画面上
                          // 都没法保证看得清。
                          decoration: BoxDecoration(
                            color: AppColors.onAccent.withValues(
                              alpha: trackAlpha,
                            ),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: fraction,
                            child: ColoredBox(
                              color: AppColors.onAccent.withValues(
                                alpha: playedAlpha,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 整条的高度：线条 + 上面那行时间。悬停 / 指针都按整条算。
const double kVideoScrubBarHeight = 26;

/// 视觉线条高度。
const double kVideoScrubHeight = 3;

/// 命中区高度：其余部分是透明的，只用来放宽点击 / 拖动范围。
const double kVideoScrubHitHeight = 12;

/// 播放中（未悬停、未拖动）的透明度：全屏是看片，进度只该是"余光里几乎
/// 不存在的一道痕"。这一档淡到"要盯着看才发现"，识别靠的是位置（贴底整条）
/// 而不是颜色。
const double _kTrackAlphaPlaying = 0.03;
const double _kPlayedAlphaPlaying = 0.12;

/// 暂停 / 悬停 / 拖动时回升到的档位（三者同一档）。
///
/// 比播放中亮一档，但也不是"一条明显的白线"：暂停的瞬间用户要的只是
/// "看得出播到哪了"。右端时间跟 [_kPlayedAlphaActive] 同色，不单设一档。
const double _kTrackAlphaActive = 0.06;
const double _kPlayedAlphaActive = 0.24;

/// 沉浸态进度条的稳定锚点：测试按 Key 找，不按高度猜。
const Key kVideoScrubKey = Key('video-scrub');

/// 右端那串时间的稳定锚点。
const Key kVideoScrubTimeKey = Key('video-scrub-time');
