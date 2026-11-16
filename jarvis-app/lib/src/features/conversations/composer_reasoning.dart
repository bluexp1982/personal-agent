import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 输入栏「推理等级」的四档。
///
/// 只认上游白名单里的这四个值。`minimal` / `medium` / `xhigh` / `ultra` 网关
/// 也收，但实测它们只是映射到这几档（`medium` 与 `high` 的排序还不稳定），
/// 做出来只会让用户以为存在更细的档位。
abstract final class ReasoningLevels {
  /// 关闭思考：不产出思维链，首字最快。
  static const String none = 'none';
  static const String low = 'low';
  static const String high = 'high';
  static const String max = 'max';

  /// 默认档：与上游的默认值一致，用户没动过菜单时行为不变。
  static const String fallback = high;

  /// 二级菜单的展示顺序：从"不想"到"最想"。
  static const List<String> all = <String>[none, low, high, max];

  /// 菜单里显示的中文名。
  static String labelOf(String value) {
    switch (value) {
      case none:
        return '不思考';
      case low:
        return '低';
      case high:
        return '高';
      case max:
        return '最高';
      default:
        return '高';
    }
  }

  /// 二级条目的那句说明：讲清"换这一档会怎样"，而不是复述档名。
  static String describe(String value) {
    switch (value) {
      case none:
        return '不输出思考过程，首字最快';
      case low:
        return '少量思考，速度与质量折中';
      case high:
        return '默认档，日常问题够用';
      case max:
        return '尽量多想，复杂推理更准但更慢';
      default:
        return '';
    }
  }
}

/// 「聊天」空态页的推理等级占位 key。
///
/// 那时还没有会话 id，但用户可能先选好档位再敲第一句；建完会话会按真实
/// id 复制一份（见 `EmptyChatPage`），与 `kDraftChatApprovalKey` 同一套做法。
const String kDraftChatReasoningKey = 'chat-draft';

/// 按会话记住推理等级。
///
/// 与 `composerApprovalProvider` 同构：用 family 而不是一个 Map 控制器，
/// 会话页按 `conversationId` 各取各的；切走再切回来不会丢。
///
/// **只存在内存里**：这是"本次会话的临时选择"，不落库、不改表，应用重启或
/// 重开会话回到默认「高」。要跨会话记住就得写服务端，那是另一个量级。
final composerReasoningProvider =
    NotifierProvider.family<ComposerReasoningController, String, String>(
      ComposerReasoningController.new,
    );

/// 单个会话的推理等级。
class ComposerReasoningController extends Notifier<String> {
  ComposerReasoningController(this.conversationId);

  /// 本状态所属的会话 id。
  final String conversationId;

  @override
  String build() {
    // 会话页被重建（切标签、收起面板）时不该把用户的选择清回默认。
    ref.keepAlive();
    return ReasoningLevels.fallback;
  }

  /// 切换档位。白名单之外的值直接忽略：深链塞进来的脏数据不该下发给上游。
  void select(String value) {
    if (!ReasoningLevels.all.contains(value) || value == state) {
      return;
    }
    state = value;
  }
}
