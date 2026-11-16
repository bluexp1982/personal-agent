import 'package:flutter/foundation.dart';

/// 项目详情页里「Tab + 工具动作」合并行右侧要显示的那组动作。
///
/// 动作原本长在会话页 / 任务页内部（管理态、勾选数量都在它们的 State 里），
/// 但合并行在父页。用数据而不是 Widget 上报：Widget 每帧都是新实例，父页
/// 无法判断要不要重建；数据可以只比「形状」，闭包差异直接忽略。
@immutable
class SectionActions {
  const SectionActions({
    required this.managing,
    required this.selectedCount,
    required this.selectableCount,
    required this.canManage,
    required this.onManage,
    required this.onRefresh,
    required this.onToggleAll,
    required this.onDone,
  });

  /// 是否处于勾选管理模式。为真时右侧显示「全选 / 完成」。
  final bool managing;

  final int selectedCount;

  /// 可勾选的条目数（任务页会排除执行中的任务）。
  final int selectableCount;

  /// 列表非空时才给「管理」入口。
  final bool canManage;

  final VoidCallback onManage;
  final VoidCallback onRefresh;
  final VoidCallback onToggleAll;
  final VoidCallback onDone;

  /// 只比较会影响按钮排布与文案的字段；闭包每帧新建但行为等价。
  bool sameShape(SectionActions other) {
    return managing == other.managing &&
        selectedCount == other.selectedCount &&
        selectableCount == other.selectableCount &&
        canManage == other.canManage;
  }
}

/// 子页把动作写进来，父页监听它重建合并行。
class SectionActionsController extends ChangeNotifier {
  SectionActions? value;

  /// 形状变化时才通知。调用点应放在 build 之后（post-frame）：父页重建
  /// 会牵动子页，在 build 期间通知会触发 setState-during-build 断言。
  void update(SectionActions next) {
    final current = value;
    value = next;
    if (current == null || !current.sameShape(next)) {
      notifyListeners();
    }
  }

  /// 形状没变，只把闭包换成新的：列表内容可能变了，但按钮排布没变，
  /// 父页不需要重建。
  void replace(SectionActions next) => value = next;

  /// 子页被回收时清空：闭包指向的 State 已经不在了，留着会让父页
  /// 渲染出一排点了就报错的按钮。这里不发通知，父页自己的重建会读到 null。
  void reset() => value = null;
}
