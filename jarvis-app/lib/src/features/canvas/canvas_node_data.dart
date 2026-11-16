/// 画布节点的业务数据：卡片上写什么、属于哪一类。
///
/// 用 sealed 家族而不是"一个类 + 一个 kind 字段"：`CanvasNodeCard` 里的 switch
/// 可以穷尽，将来新增一种节点会编译报错，不会出现"忘了一个分支就渲染成空白卡片"。
/// 类型色不放在数据里——它要跟随明暗主题，只能在有 `BuildContext` 的地方从
/// [AppPalette] 取。
sealed class CanvasNodeData {
  const CanvasNodeData({required this.title, required this.subtitle});

  /// 卡片主标题（`AppFontSize.base` / 中等字重）。
  final String title;

  /// 卡片第二行：一句"这个节点干什么"，弱化灰。
  final String subtitle;

  /// 类型标识。同时是节点 `type` 与导出 JSON 里的 `kind` 的唯一来源：
  /// 三处各写一份字符串，改名时必漏。
  String get kind;
}

/// 输入触发：一段外部事件（消息、定时、按钮）进入画布。
final class TriggerNodeData extends CanvasNodeData {
  const TriggerNodeData({required super.title, required super.subtitle});

  @override
  String get kind => 'trigger';
}

/// 处理节点：真正的干活方（调模型、跑工具）。
final class AgentNodeData extends CanvasNodeData {
  const AgentNodeData({required super.title, required super.subtitle});

  @override
  String get kind => 'agent';
}

/// 条件分支：按判断结果走两条出边。
final class BranchNodeData extends CanvasNodeData {
  const BranchNodeData({required super.title, required super.subtitle});

  @override
  String get kind => 'branch';
}

/// 输出节点：把结果落到某处（写文件、发通知、回消息）。
final class OutputNodeData extends CanvasNodeData {
  const OutputNodeData({required super.title, required super.subtitle});

  @override
  String get kind => 'output';
}
