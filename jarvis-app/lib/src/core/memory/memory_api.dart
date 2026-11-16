import '../api_client.dart';
import 'memory_models.dart';

/// `/api/memories*` 的薄封装。
///
/// 只做「路径 + 解析」，不做重试与状态机：那些属于 provider 与页面。
/// 与 `core/recording/recording_api.dart` 同形。
class MemoryApi {
  MemoryApi(this._client);

  final ApiClient _client;

  /// 列表。有关键词时服务端按相关度排序且不分页（`next_cursor` 为空）。
  Future<MemoryPage> list({
    MemoryKind? kind,
    MemoryStatus? status,
    String? query,
    String? cursor,
    int limit = 20,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (kind != null) {
      params['kind'] = kind.wire;
    }
    if (status != null) {
      params['status'] = status.wire;
    }
    if (query != null && query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    }
    final json = await _client.getJson('/api/memories', query: params);
    return MemoryPage.fromJson(json);
  }

  Future<MemoryDetail> create({
    required MemoryKind kind,
    required String content,
    required String evidenceQuote,
    String? subject,
    MemorySensitivity? sensitivity,
    bool? pinned,
  }) async {
    final json = await _client.postJson('/api/memories', <String, dynamic>{
      'kind': kind.wire,
      'content': content,
      'evidence_quote': evidenceQuote,
      if (subject != null && subject.trim().isNotEmpty) 'subject': subject.trim(),
      if (sensitivity != null) 'sensitivity': sensitivity.wire,
      'pinned': ?pinned,
    });
    return MemoryDetail.fromJson(json);
  }

  Future<MemoryDetail> detail(String id) async {
    final json = await _client.getJson('/api/memories/$id');
    return MemoryDetail.fromJson(json);
  }

  Future<MemoryDetail> update(
    String id, {
    String? content,
    bool? pinned,
    MemoryStatus? status,
    MemoryKind? kind,
    MemorySensitivity? sensitivity,
  }) async {
    final json = await _client.patchJson('/api/memories/$id', <String, dynamic>{
      'content': ?content,
      'pinned': ?pinned,
      if (status != null) 'status': status.wire,
      if (kind != null) 'kind': kind.wire,
      if (sensitivity != null) 'sensitivity': sensitivity.wire,
    });
    return MemoryDetail.fromJson(json);
  }

  Future<void> delete(String id) => _client.delete('/api/memories/$id');

  /// 清空归档：把 `status=archived` 的记忆批量软删，`kind` 为 null 时清全部类别。
  /// 返回清除条数（重复调用返回 0）。
  Future<int> purgeArchived({MemoryKind? kind}) async {
    final json = await _client.postJson(
      '/api/memories/archived/purge',
      <String, dynamic>{'kind': ?kind?.wire},
    );
    return (json['purged'] as num?)?.toInt() ?? 0;
  }

  Future<MemoryStateView> state() async {
    final json = await _client.getJson('/api/memories/state');
    return MemoryStateView.fromJson(json);
  }

  /// 手动整理一次。服务端只做"开始"，跑完靠轮询 `state().maintenance` 得知。
  ///
  /// 返回本次的 `started_at`：完成判据是 `last_organized_at >= started_at`，
  /// 否则可能把上一轮的结果当成这一轮的。
  Future<int> organize() async {
    final json = await _client.postJson(
      '/api/memories/organize',
      const <String, dynamic>{},
    );
    return (json['started_at'] as num?)?.toInt() ?? 0;
  }

  Future<List<DigestListItem>> digests({int limit = 7}) async {
    final rows = await _client.getJsonArray(
      '/api/memories/digest',
      query: <String, String>{'limit': '$limit'},
    );
    return <DigestListItem>[
      for (final row in rows) DigestListItem.fromJson(row),
    ];
  }

  Future<DigestView> digest(String id) async {
    final json = await _client.getJson('/api/memories/digest/$id');
    return DigestView.fromJson(json);
  }

  /// 候选列表：走同一个 `list`，只是固定 `status=candidate`。
  Future<MemoryPage> candidates({int limit = 100}) =>
      list(status: MemoryStatus.candidate, limit: limit);

  /// 批量接受 / 拒绝候选。已经被处理过的 id 会进 `skipped`，不算错误。
  Future<CandidateDecisionResult> decide({
    required List<String> ids,
    required bool accept,
  }) async {
    final json = await _client.postJson(
      '/api/memories/candidates/decide',
      <String, dynamic>{
        'ids': ids,
        'decision': accept ? 'accept' : 'reject',
      },
    );
    return CandidateDecisionResult.fromJson(json);
  }

  Future<BatchRevokeResult> revokeBatch(String batchId, {String? reason}) async {
    final json = await _client.postJson(
      '/api/memories/batches/$batchId/revoke',
      <String, dynamic>{'reason': ?reason},
    );
    return BatchRevokeResult.fromJson(json);
  }

  Future<Memory> feedback(String id, {required bool useful}) async {
    final json = await _client.postJson('/api/memories/$id/feedback', <String, dynamic>{
      'useful': useful,
    });
    return Memory.fromJson(json);
  }

  /// 批量遗忘。`dryRun` 只回条数，不写库。
  Future<Map<String, dynamic>> forget({
    required Map<String, dynamic> filter,
    bool dryRun = true,
  }) {
    return _client.postJson('/api/memories/forget', <String, dynamic>{
      'filter': filter,
      'dry_run': dryRun,
    });
  }

  Future<ExportPreview> exportPreview(String projectId) async {
    final json = await _client.postJson(
      '/api/memories/export/preview',
      <String, dynamic>{'project_id': projectId},
    );
    return ExportPreview.fromJson(json);
  }

  /// 写入。哈希不一致时服务端回 `conflict`，调用方要提示重新预览。
  Future<void> exportApply({
    required String projectId,
    required String expectedHash,
  }) {
    return _client.postJson('/api/memories/export/apply', <String, dynamic>{
      'project_id': projectId,
      'expected_hash': expectedHash,
    });
  }

  Future<MemoryStateView> updateSettings({
    List<NotificationCategory>? mute,
    int? dailyLimit,
    bool? digestEnabled,
  }) async {
    final json = await _client.patchJson('/api/memories/settings', <String, dynamic>{
      if (mute != null)
        'heartbeat_mute': <String>[for (final item in mute) item.wire],
      'daily_limit': ?dailyLimit,
      'digest_enabled': ?digestEnabled,
    });
    return MemoryStateView.fromJson(json);
  }

  Future<EntityPage> entities({
    EntityType? type,
    EntityStatus? status,
    String? query,
    String? cursor,
    int limit = 20,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (type != null) {
      params['type'] = type.wire;
    }
    if (status != null) {
      params['status'] = status.wire;
    }
    if (query != null && query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    }
    final json = await _client.getJson('/api/entities', query: params);
    return EntityPage.fromJson(json);
  }

  Future<EntityDetail> entity(String id) async {
    final json = await _client.getJson('/api/entities/$id');
    return EntityDetail.fromJson(json);
  }

  Future<Entity> updateEntity(
    String id, {
    String? name,
    List<String>? aliases,
    EntityStatus? status,
  }) async {
    final json = await _client.patchJson('/api/entities/$id', <String, dynamic>{
      'name': ?name,
      'aliases': ?aliases,
      if (status != null) 'status': status.wire,
    });
    return Entity.fromJson(json);
  }

  Future<EntityDetail> mergeEntities({
    required String sourceId,
    required String targetId,
  }) async {
    final json = await _client.postJson('/api/entities/merge', <String, dynamic>{
      'source_id': sourceId,
      'target_id': targetId,
    });
    return EntityDetail.fromJson(json);
  }

  Future<EntityDetail> splitEntity(
    String id, {
    required List<String> memoryIds,
    String? name,
  }) async {
    final json = await _client.postJson('/api/entities/$id/split', <String, dynamic>{
      'memory_ids': memoryIds,
      'name': ?name,
    });
    return EntityDetail.fromJson(json);
  }

  Future<GrantPage> grants({GrantScope? scope, String? scopeId, int limit = 50}) async {
    final params = <String, String>{'limit': '$limit'};
    if (scope != null) {
      params['scope'] = scope.wire;
    }
    if (scopeId != null && scopeId.isNotEmpty) {
      params['scope_id'] = scopeId;
    }
    final json = await _client.getJson('/api/grants', query: params);
    return GrantPage.fromJson(json);
  }

  /// 撤销后下一次同类调用立即重新建卡。
  Future<void> revokeGrant(String id) => _client.delete('/api/grants/$id');
}
