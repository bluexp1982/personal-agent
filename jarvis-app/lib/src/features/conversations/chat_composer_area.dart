import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'chat_composer.dart';
import 'composer_menus.dart';
import 'composer_reasoning.dart';

/// 对话内容栏的最大宽度：消息列表与输入面板共用。
///
/// 宽屏（右侧内嵌对话）时铺满整条会显得很空——助手气泡贴最左、用户气泡顶到最右，
/// 中间空出一大块；720 与聊天气泡的阅读宽度接近，两侧留白后视觉重心仍落在中间。
/// 两个区域只认这一个值：各自设宽的话，宽屏下会看出两条错位的竖线。
/// 窄屏窗口本身小于这个值，等于不生效。
const double kChatColumnMaxWidth = 720;

/// 输入面板的标准外框：`SafeArea` / 页边距 / 限宽。
///
/// 从会话页抽出来给「会话页」与「聊天空态页」共用：两处各写一套度量，
/// 面板左右边缘就会差一两个 dp，与消息列表对齐的那条竖线也会错位。
///
/// 面板本体（[ChatComposer]）只吃 controller 与几个回调，状态仍由调用方持有：
/// 空态页与已有会话的发送链路完全不同，唯一该共享的是这块外框。
class ChatComposerArea extends StatelessWidget {
  const ChatComposerArea({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onStop,
    this.stopping = false,
    this.flowing = false,
    this.permission = ComposerDefaults.permission,
    this.onPermissionChanged,
    this.reasoning = ReasoningLevels.fallback,
    this.onReasoningChanged,
    this.contextTokens = 0,
    this.contextWindow = 0,
    this.compactedMessages = 0,
    this.compacting = false,
    this.onOpenCompaction,
    this.safeBottom = true,
    this.padding,
    this.visibleLines = 2,
    this.compactWhenIdle = false,
  });

  /// 贴底布局时的标准外框边距。
  ///
  /// 左右与底部同为 16：面板贴底时这三边是"面板到窗口边"的同一段留白，
  /// 底部收窄一档会让它看起来像被窗口截断。上方仍是 8，给消息区留一点呼吸。
  static const EdgeInsets defaultPadding = EdgeInsets.fromLTRB(16, 8, 16, 16);

  /// 浮窗贴底时的外框边距。
  ///
  /// 小窗窄到铺满整窗时，左右 16 与下方 12 会在视觉上分叉：面板离两侧比离底边
  /// 更远。浮窗把左右收成 12，三边等距；上方仍是 8，给消息区留一点呼吸。
  static const EdgeInsets floatingPadding = EdgeInsets.fromLTRB(12, 8, 12, 12);

  final QuillController controller;
  final bool sending;
  final bool stopping;

  /// 这一轮还在生成：面板边缘亮起霓虹流光（含点停止后的等待收尾）。
  ///
  /// 空态页不传：那里的 `sending` 只是"正在建会话"，随后立刻换成会话页，
  /// 亮一下反而像闪屏。
  final bool flowing;

  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 权限胶囊当前值（`ApprovalModes` 里的字符串）。
  final String permission;
  final ValueChanged<String>? onPermissionChanged;

  /// 推理等级当前值（`ReasoningLevels` 里的字符串）。状态由页面持有。
  final String reasoning;
  final ValueChanged<String>? onReasoningChanged;

  /// 当前上下文长度（本轮最后一次模型调用的输入 token 数）。
  ///
  /// 页面从最近一条 assistant 消息的用量里取；0 表示还没有数据，
  /// 输入栏里的环形显示 0% 空环。
  final int contextTokens;

  /// 当前模型的最大上下文窗口（tokens），环形占比的分母；0 表示未知。
  final int contextWindow;

  /// 已经被整理成摘要的消息条数；0 表示没有可用摘要。
  ///
  /// 只影响环形提示的那一句说明，不参与占比计算——摘要本身已经不在
  /// 上下文里了，把它算进分子只会让占比看起来更小。
  final int compactedMessages;

  /// 点上下文环打开摘要弹窗；`null` 时不挂手势（空态页不传）。
  final VoidCallback? onOpenCompaction;

  /// 正在手动整理上下文：环改成一段持续旋转的弧。
  final bool compacting;

  /// 是否让开底部安全区。
  ///
  /// 整页与停靠态都要：输入栏贴着窗口底，手机要避开手势条、桌面要给窗口
  /// 留一口气。浮窗反过来——它悬在页面中间，底部不是"屏幕底"，让开安全区
  /// 只会在面板下多出一条莫名其妙的空白。
  final bool safeBottom;

  /// 外框边距；`null` 用 [defaultPadding]。
  ///
  /// 新会话的居中舞台会传一份不带垂直边距的：那块的上方是品牌行、下方是一片空白，
  /// 8 / 12 的上下边距不对称，会让面板比中线偏上 2dp，品牌行到面板的间距也会变成
  /// 「间距 + 8」。浮窗贴底则传 [floatingPadding]（左右与下同为 12）。中栏与整页的
  /// 贴底布局必须有这层边距，不能一起改掉。
  final EdgeInsets? padding;

  /// 空输入时显示几行（默认两行）。浮窗传 1，把高度让给消息区。
  final int visibleLines;

  /// 窄屏手机的空闲折叠：未聚焦且没有草稿时只留一行。
  ///
  /// 只由页面按「移动端 + 窄屏」传 true；外框本身不做平台判断，
  /// 免得空态页、浮窗与测试 harness 也跟着变。
  final bool compactWhenIdle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: safeBottom,
      child: Padding(
        padding: padding ?? defaultPadding,
        // `heightFactor: 1`：在 Column 里按内容高度收缩，
        // 否则 Align 会去吃满主轴方向的无界高度。
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kChatColumnMaxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ChatComposer(
                  controller: controller,
                  sending: sending,
                  stopping: stopping,
                  flowing: flowing,
                  onSend: onSend,
                  onStop: onStop,
                  permission: permission,
                  onPermissionChanged: onPermissionChanged,
                  reasoning: reasoning,
                  onReasoningChanged: onReasoningChanged,
                  contextTokens: contextTokens,
                  contextWindow: contextWindow,
                  compactedMessages: compactedMessages,
                  compacting: compacting,
                  onOpenCompaction: onOpenCompaction,
                  visibleLines: visibleLines,
                  compactWhenIdle: compactWhenIdle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
