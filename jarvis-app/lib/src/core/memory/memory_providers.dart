import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_error.dart';
import '../session.dart';
import 'memory_api.dart';
import 'memory_models.dart';

/// 记忆接口。未登录/未就绪时为 `null`（页面据此显示"未连接"而不是报错）。
final Provider<MemoryApi?> memoryApiProvider = Provider<MemoryApi?>((ref) {
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return null;
  }
  return MemoryApi(client);
});

/// 记忆状态快照。首页徽标与设置页共用，`invalidate` 一次两处都刷新。
final FutureProvider<MemoryStateView?> memoryStateProvider =
    FutureProvider<MemoryStateView?>((ref) async {
      final api = ref.watch(memoryApiProvider);
      if (api == null) {
        return null;
      }
      try {
        return await api.state();
      } on ApiException {
        // 服务不可达时按"没有状态"处理：记忆是服务端权威，离线只能提示。
        return null;
      }
    });

/// 候选积压数：侧栏入口的小红点只认这个数。
final Provider<int> memoryCandidatesCountProvider = Provider<int>((ref) {
  final state = ref.watch(memoryStateProvider).value;
  return state?.counts.candidate ?? 0;
});

/// 列表查询键。用 record 做 family 键：`(kind, status, query)` 任意一个变化都是新查询。
typedef MemoryQuery = ({MemoryKind? kind, MemoryStatus? status, String query});

/// 记忆列表。分页在页面里叠加 `cursor` 结果，这里只取第一页。
final memoryListProvider =
    FutureProvider.family<MemoryPage, MemoryQuery>((ref, key) async {
      final api = ref.watch(memoryApiProvider);
      if (api == null) {
        return const MemoryPage(items: <Memory>[]);
      }
      return api.list(kind: key.kind, status: key.status, query: key.query);
    });

/// 记忆详情。`null` 表示不存在或已删除。
final memoryDetailProvider = FutureProvider.family<MemoryDetail?, String>((
  ref,
  id,
) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null || id.isEmpty) {
    return null;
  }
  try {
    return await api.detail(id);
  } on ApiException catch (error) {
    if (error.code == 'not_found') {
      return null;
    }
    rethrow;
  }
});

/// 最近几份摘要快照。一期只读，不回滚。
final memoryDigestsProvider = FutureProvider<List<DigestListItem>>((ref) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null) {
    return const <DigestListItem>[];
  }
  try {
    return await api.digests();
  } on ApiException {
    return const <DigestListItem>[];
  }
});

/// 候选批次：把 `status=candidate` 的记忆按 `batch_id` 分组。
final memoryCandidatesProvider = FutureProvider<List<CandidateBatch>>((ref) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null) {
    return const <CandidateBatch>[];
  }
  final page = await api.candidates();
  final grouped = <String?, List<Memory>>{};
  for (final memory in page.items) {
    grouped.putIfAbsent(memory.batchId, () => <Memory>[]).add(memory);
  }

  final batches = <CandidateBatch>[
    for (final entry in grouped.entries)
      CandidateBatch(
        batchId: entry.key,
        items: entry.value,
        createdAt: entry.value.first.createdAt,
      ),
  ];
  // 新批次在前：用户刚聊完就该看到刚才抽出来的东西。
  batches.sort((left, right) => right.createdAt.compareTo(left.createdAt));
  return batches;
});

/// 实体列表。键是 `(type, status, query)`。
typedef EntityQuery = ({EntityType? type, EntityStatus? status, String query});

final memoryEntitiesProvider =
    FutureProvider.family<EntityPage, EntityQuery>((ref, key) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null) {
    return const EntityPage(items: <Entity>[]);
  }
  return api.entities(type: key.type, status: key.status, query: key.query);
});

final memoryEntityProvider = FutureProvider.family<EntityDetail?, String>((
  ref,
  id,
) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null || id.isEmpty) {
    return null;
  }
  try {
    return await api.entity(id);
  } on ApiException catch (error) {
    if (error.code == 'not_found') {
      return null;
    }
    rethrow;
  }
});

/// 生效中的执行授权。撤销后 `invalidate` 一次即可。
final memoryGrantsProvider = FutureProvider<List<Grant>>((ref) async {
  final api = ref.watch(memoryApiProvider);
  if (api == null) {
    return const <Grant>[];
  }
  try {
    final page = await api.grants();
    return page.items;
  } on ApiException {
    return const <Grant>[];
  }
});
