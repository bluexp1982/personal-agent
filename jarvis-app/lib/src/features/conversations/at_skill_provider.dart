import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capability_revision.dart';
import '../../core/models.dart';
import '../../core/session.dart';

/// 会话里 `@` 能选到的技能。
///
/// 与「新建任务」下拉同源（`/api/skills`，服务端已滤掉 `unsupported`），
/// 这里再排掉编码任务：它要选仓库、执行方式与审批档，一句话给不出，
/// 派出去只会缺参数直接失败。编码任务仍从任务页的专用对话框派。
///
/// 不传 `mode`：`unsupported` 已经被服务端过滤，而编码任务在这里被显式排除，
/// 所以 普通项目里同样不会看到 `code-task`。
final atSkillsProvider = FutureProvider<List<SkillInfo>>((ref) async {
  // 设置页改完技能包会 bump 这个版本号：这里 watch 它，清单就会重新拉一次，
  // 不用等用户重启客户端。
  ref.watch(capabilityRevisionProvider);
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return const <SkillInfo>[];
  }

  final items = await client.getJsonArray('/api/skills');
  return items
      .map(SkillInfo.fromJson)
      .where((skill) => skill.name.isNotEmpty)
      .where((skill) => skill.support != SkillSupport.unsupported)
      .where((skill) => !skill.requiredTools.contains('code.exec'))
      .toList(growable: false);
});
