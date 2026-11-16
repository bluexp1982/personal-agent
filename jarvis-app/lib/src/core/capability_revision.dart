import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 能力清单的版本号。
///
/// 设置页改完技能包（安装 / 启停 / 卸载）后调用 [CapabilityRevision.bump]，
/// 所有"技能清单"类 provider 都 watch 它。
///
/// 为什么需要它：技能清单是一次拉取、长期缓存的（[atSkillsProvider] 不是
/// autoDispose），而设置页只更新自己卡片里的数据。少了这条失效链路，
/// 用户装完技能后 `@` 候选里看不到它，只能重启客户端——与设置页上那句
/// "装完不用重启应用"直接矛盾。
final capabilityRevisionProvider = NotifierProvider<CapabilityRevision, int>(
  CapabilityRevision.new,
);

class CapabilityRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// 技能清单可能变了。只加不减：消费方不关心"变成几"，只关心"变了"。
  void bump() => state += 1;
}
