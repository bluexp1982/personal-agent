import 'package:flutter/material.dart';

/// 消息流配色：用户气泡与 AI 回答里的代码块共用一套。
///
/// 两种底色刻意不同：用户气泡偏蓝（发言的"便签"感），代码块是中性浅灰
/// （引用的"纸面"感），挨在一起时能一眼分出"我说的"和"代码/引用"。
///
/// 这里只是值类型：明暗两份实例由 [AppPalette] 装配，界面一律走
/// `AppPalette.of(context).message`，不要再直接引用 `MessagePalette.light` /
/// `MessagePalette.dark`——那两个常量是为了让 [AppPalette] 保持 const 才留的。
@immutable
class MessagePalette {
  const MessagePalette({
    required this.userBubble,
    required this.codeBackground,
    required this.userText,
    required this.meta,
    required this.divider,
  });

  /// 深色：气泡比页面底亮一档，边界才看得出来。
  static const MessagePalette dark = MessagePalette(
    userBubble: Color(0xFF1E2432),
    codeBackground: Color(0xFF24272D),
    userText: Color(0xFFE6E7EC),
    meta: Color(0xFF8D92A0),
    divider: Color(0xFF2C2F38),
  );

  /// 浅色：气泡蓝调，代码块中性灰。
  static const MessagePalette light = MessagePalette(
    userBubble: Color(0xFFEDF3FE),
    // 比设计稿采样的 #F9FAFB 压深一档：那一档放在白底页面上几乎看不出块，
    // 而这里代码块要靠"浅底 + 圆角"自证边界，必须能看见。
    codeBackground: Color(0xFFF3F4F6),
    userText: Color(0xFF1B1B22),
    meta: Color(0xFF8A8F98),
    divider: Color(0xFFE4E5EA),
  );

  /// 用户气泡底色。浅色取自设计稿采样值，暗色取带蓝调的深灰。
  final Color userBubble;

  /// 代码块底色：中性灰，与用户气泡的蓝调拉开距离。
  final Color codeBackground;

  /// 用户气泡正文色。
  final Color userText;

  /// 时间、用量、语言标签这类元信息文字。
  final Color meta;

  /// 助手回答首行下面那条分割线。
  final Color divider;
}
