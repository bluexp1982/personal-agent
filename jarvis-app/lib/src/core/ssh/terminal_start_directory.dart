import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「下一次新 shell 应该落在哪个目录」。
///
/// 单独一个 provider 而不是往 `SshState` 里加字段：这是一次**点击意图**，
/// 与连接状态机无关——终端已经连着时点「终端」不发起连接，也就不该读它。
/// 分开还有一个好处：`SshController` 在大量 widget 测试里被替身覆盖，
/// 而这条意图仍能被独立断言。
///
/// `null` 表示不指定，交给远端用户的家目录。
final NotifierProvider<TerminalStartDirectoryController, String?>
terminalStartDirectoryProvider =
    NotifierProvider<TerminalStartDirectoryController, String?>(
      TerminalStartDirectoryController.new,
    );

class TerminalStartDirectoryController extends Notifier<String?> {
  @override
  String? build() => null;

  /// 记下这次点「终端」要进入哪个目录（空串 / null 都归一到"不指定"）。
  ///
  /// 每次点击都写一遍，包括写回 null：否则"先带着项目开过终端、再在没有项目
  /// 的状态下开终端"会沿用上一个项目的目录，而那台机器上未必还有那条路径。
  void request(String? path) {
    final next = (path == null || path.isEmpty) ? null : path;
    if (next != state) {
      state = next;
    }
  }
}
