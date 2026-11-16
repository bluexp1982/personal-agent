import 'package:flutter/material.dart';

/// 会话的统一图标：侧栏会话行、会话列表、会话页栏头都认这一枚。
///
/// 单独放一处而不是各写一个 `Icons.chat_bubble_outline`：这三处指向的是同一个
/// 对象（一段对话），图标一旦漂移，"看见这个符号就知道是会话"这层约定就断了。
const IconData conversationIcon = Icons.chat_bubble_outline;
