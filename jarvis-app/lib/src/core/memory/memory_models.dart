/// 记忆系统的 Dart 侧镜像。
///
/// 手写而不是 codegen：与 `core/models.dart` 同风格，字段少、改动可读。
/// 所有 `fromJson` 都**容错缺字段**——服务端加了字段不该让客户端崩，
/// 服务端删了字段也不该让整页空白。
library;

/// 记忆类型。
enum MemoryKind {
  profile('profile', '画像'),
  preference('preference', '偏好'),
  event('event', '事件'),
  project('project', '项目');

  const MemoryKind(this.wire, this.label);

  final String wire;
  final String label;

  static MemoryKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wire == raw) {
        return kind;
      }
    }
    return event;
  }
}

/// 记忆状态。候选不是独立表，就是 `status=candidate` 的记忆。
enum MemoryStatus {
  candidate('candidate', '候选'),
  active('active', '生效'),
  stale('stale', '已失效'),
  archived('archived', '已归档'),
  deleted('deleted', '已删除');

  const MemoryStatus(this.wire, this.label);

  final String wire;
  final String label;

  static MemoryStatus parse(Object? raw) {
    for (final status in values) {
      if (status.wire == raw) {
        return status;
      }
    }
    return archived;
  }
}

/// 敏感度。私密记忆不会进入常驻摘要。
enum MemorySensitivity {
  normal('normal', '普通'),
  private('private', '私密');

  const MemorySensitivity(this.wire, this.label);

  final String wire;
  final String label;

  static MemorySensitivity parse(Object? raw) {
    return raw == private.wire ? private : normal;
  }
}

/// 来源管道。
enum MemorySourceKind {
  explicit('explicit', '用户设定'),
  session('session', '来自对话'),
  task('task', '来自任务'),
  recording('recording', '来自录音'),
  codeTask('code_task', '来自编码任务'),
  heartbeat('heartbeat', '服务端巡检'),
  userCorrected('user_corrected', '用户设定');

  const MemorySourceKind(this.wire, this.label);

  final String wire;
  final String label;

  static MemorySourceKind parse(Object? raw) {
    for (final source in values) {
      if (source.wire == raw) {
        return source;
      }
    }
    return explicit;
  }
}

/// 证据指向的源对象类型。
enum EvidenceSourceKind {
  message('message'),
  task('task'),
  step('step'),
  recording('recording'),
  codeTask('code_task'),
  explicit('explicit');

  const EvidenceSourceKind(this.wire);

  final String wire;

  static EvidenceSourceKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wire == raw) {
        return kind;
      }
    }
    return explicit;
  }
}

/// 时间范围描述。
class MemoryTimeScope {
  const MemoryTimeScope({this.from, this.to, this.label});

  factory MemoryTimeScope.fromJson(Map<String, dynamic> json) {
    return MemoryTimeScope(
      from: (json['from'] as num?)?.toInt(),
      to: (json['to'] as num?)?.toInt(),
      label: json['label'] as String?,
    );
  }

  final int? from;
  final int? to;
  final String? label;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (label != null) 'label': label,
  };

  String get display {
    if (label != null && label!.trim().isNotEmpty) {
      return label!;
    }
    return <String>[
      if (from != null) formatDate(from!),
      if (to != null) formatDate(to!),
    ].join(' → ');
  }
}

/// 一条证据：源文本里的连续片段。
class MemoryEvidence {
  const MemoryEvidence({
    required this.id,
    required this.sourceKind,
    required this.sourceId,
    required this.quote,
    required this.createdAt,
    this.supportSpan,
  });

  factory MemoryEvidence.fromJson(Map<String, dynamic> json) {
    return MemoryEvidence(
      id: json['id'] as String? ?? '',
      sourceKind: EvidenceSourceKind.parse(json['source_kind']),
      sourceId: json['source_id'] as String? ?? '',
      quote: json['quote'] as String? ?? '',
      supportSpan: json['support_span'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final EvidenceSourceKind sourceKind;
  final String sourceId;
  final String quote;
  final String? supportSpan;
  final int createdAt;

  /// 支撑片段与整段原文相同就没有高亮的意义。
  bool get hasHighlight {
    final span = supportSpan?.trim() ?? '';
    return span.isNotEmpty && span != quote.trim();
  }
}

/// 一条记忆。
class Memory {
  const Memory({
    required this.id,
    required this.kind,
    required this.status,
    required this.content,
    required this.source,
    required this.sensitivity,
    required this.pinned,
    required this.conflicting,
    required this.confidence,
    required this.importance,
    required this.useCount,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.subject,
    this.entityId,
    this.predicate,
    this.timeScope,
    this.batchId,
    this.pipeline = 'subjective',
  });

  factory Memory.fromJson(Map<String, dynamic> json) {
    final scope = json['time_scope'];
    return Memory(
      id: json['id'] as String? ?? '',
      kind: MemoryKind.parse(json['kind']),
      status: MemoryStatus.parse(json['status']),
      content: json['content'] as String? ?? '',
      source: MemorySourceKind.parse(json['source']),
      sensitivity: MemorySensitivity.parse(json['sensitivity']),
      pinned: json['pinned'] as bool? ?? false,
      conflicting: json['conflicting'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      importance: (json['importance'] as num?)?.toDouble() ?? 0,
      useCount: (json['use_count'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      projectId: json['project_id'] as String?,
      subject: json['subject'] as String?,
      entityId: json['entity_id'] as String?,
      predicate: json['predicate'] as String?,
      timeScope: scope is Map<String, dynamic>
          ? MemoryTimeScope.fromJson(scope)
          : null,
      batchId: json['batch_id'] as String?,
      pipeline: json['pipeline'] as String? ?? 'subjective',
    );
  }

  final String id;
  final MemoryKind kind;
  final MemoryStatus status;
  final String content;
  final MemorySourceKind source;
  final MemorySensitivity sensitivity;
  final bool pinned;
  final bool conflicting;
  final double confidence;
  final double importance;
  final int useCount;
  final int createdAt;
  final int updatedAt;
  final String? projectId;
  final String? subject;
  final String? entityId;
  final String? predicate;
  final MemoryTimeScope? timeScope;
  final String? batchId;
  final String pipeline;

  bool get isPrivate => sensitivity == MemorySensitivity.private;

  /// 列表行第二行的元信息：`类型 · 来源 · 时间`。
  String get metaLine =>
      '${kind.label} · ${source.label} · ${formatDate(createdAt)}';
}

/// 记忆详情顶部的实体摘要。
class EntityBrief {
  const EntityBrief({
    required this.id,
    required this.name,
    required this.entityType,
  });

  factory EntityBrief.fromJson(Map<String, dynamic> json) {
    return EntityBrief(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      entityType: EntityType.parse(json['entity_type']),
    );
  }

  final String id;
  final String name;
  final EntityType entityType;
}

/// 记忆详情。
class MemoryDetail {
  const MemoryDetail({
    required this.memory,
    required this.evidence,
    required this.recallCount,
    this.entity,
  });

  factory MemoryDetail.fromJson(Map<String, dynamic> json) {
    final rawMemory = json['memory'];
    return MemoryDetail(
      memory: Memory.fromJson(
        rawMemory is Map<String, dynamic> ? rawMemory : const <String, dynamic>{},
      ),
      evidence: <MemoryEvidence>[
        for (final item in (json['evidence'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) MemoryEvidence.fromJson(item),
      ],
      recallCount: (json['recall_count'] as num?)?.toInt() ?? 0,
      entity: json['entity'] is Map<String, dynamic>
          ? EntityBrief.fromJson(json['entity'] as Map<String, dynamic>)
          : null,
    );
  }

  final Memory memory;
  final List<MemoryEvidence> evidence;
  final int recallCount;

  /// 主实体摘要（P3 之后才有；老服务端不带这个键）。
  final EntityBrief? entity;
}

/// 一页记忆。
class MemoryPage {
  const MemoryPage({required this.items, this.nextCursor});

  factory MemoryPage.fromJson(Map<String, dynamic> json) {
    return MemoryPage(
      items: <Memory>[
        for (final item in (json['items'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) Memory.fromJson(item),
      ],
      nextCursor: json['next_cursor'] as String?,
    );
  }

  final List<Memory> items;
  final String? nextCursor;
}

/// 按状态分组的条数。
class MemoryCounts {
  const MemoryCounts({
    this.candidate = 0,
    this.active = 0,
    this.stale = 0,
    this.archived = 0,
  });

  factory MemoryCounts.fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.toInt() ?? 0;
    return MemoryCounts(
      candidate: read('candidate'),
      active: read('active'),
      stale: read('stale'),
      archived: read('archived'),
    );
  }

  final int candidate;
  final int active;
  final int stale;
  final int archived;
}

/// 当前摘要概况。
class DigestSummary {
  const DigestSummary({
    this.chars = 0,
    this.memoryItems = 0,
    this.generatedAt = 0,
  });

  factory DigestSummary.fromJson(Map<String, dynamic> json) {
    return DigestSummary(
      chars: (json['chars'] as num?)?.toInt() ?? 0,
      memoryItems: (json['memory_items'] as num?)?.toInt() ?? 0,
      generatedAt: (json['generated_at'] as num?)?.toInt() ?? 0,
    );
  }

  final int chars;
  final int memoryItems;
  final int generatedAt;
}

/// 今日抽取额度。
class ExtractQuota {
  const ExtractQuota({this.enabled = false, this.dailyLimit = 0, this.usedToday = 0});

  factory ExtractQuota.fromJson(Map<String, dynamic> json) {
    return ExtractQuota(
      enabled: json['enabled'] as bool? ?? false,
      dailyLimit: (json['daily_limit'] as num?)?.toInt() ?? 0,
      usedToday: (json['used_today'] as num?)?.toInt() ?? 0,
    );
  }

  final bool enabled;
  final int dailyLimit;
  final int usedToday;
}

/// 心跳状态。
class HeartbeatView {
  const HeartbeatView({
    this.enabled = false,
    this.dailyLimit = 0,
    this.deliveredToday = 0,
    this.lastScanAt,
  });

  factory HeartbeatView.fromJson(Map<String, dynamic> json) {
    return HeartbeatView(
      enabled: json['enabled'] as bool? ?? false,
      dailyLimit: (json['daily_limit'] as num?)?.toInt() ?? 0,
      deliveredToday: (json['delivered_today'] as num?)?.toInt() ?? 0,
      lastScanAt: (json['last_scan_at'] as num?)?.toInt(),
    );
  }

  final bool enabled;
  final int dailyLimit;
  final int deliveredToday;
  final int? lastScanAt;
}

/// 一次整理的条数概览。只有条数，没有正文。
class MaintenanceReportView {
  const MaintenanceReportView({
    this.recomputed = 0,
    this.failed = 0,
    this.sedimented = 0,
    this.decayed = 0,
    this.consolidated = 0,
    this.modelAvailable = false,
  });

  factory MaintenanceReportView.fromJson(Map<String, dynamic> json) {
    int count(String key) => (json[key] as num?)?.toInt() ?? 0;
    return MaintenanceReportView(
      recomputed: count('recomputed'),
      failed: count('failed'),
      sedimented: count('sedimented'),
      decayed: count('decayed'),
      consolidated: count('consolidated'),
      modelAvailable: json['model_available'] as bool? ?? false,
    );
  }

  final int recomputed;
  final int failed;
  final int sedimented;
  final int decayed;
  final int consolidated;

  /// 没有可用模型时快照重算被跳过，其余步骤照常。
  final bool modelAvailable;
}

/// 整理状态：按钮的忙碌态与结果提示都看它。
class MaintenanceView {
  const MaintenanceView({
    this.organizing = false,
    this.lastOrganizedAt,
    this.lastReport,
  });

  factory MaintenanceView.fromJson(Map<String, dynamic> json) {
    final report = json['last_report'];
    return MaintenanceView(
      organizing: json['organizing'] as bool? ?? false,
      lastOrganizedAt: (json['last_organized_at'] as num?)?.toInt(),
      lastReport: report is Map<String, dynamic>
          ? MaintenanceReportView.fromJson(report)
          : null,
    );
  }

  final bool organizing;
  final int? lastOrganizedAt;
  final MaintenanceReportView? lastReport;
}

/// 记忆状态快照。
class MemoryStateView {
  const MemoryStateView({
    required this.enabled,
    required this.counts,
    required this.digest,
    required this.extract,
    required this.heartbeat,
    this.maintenance = const MaintenanceView(),
    this.digestWarning,
  });

  factory MemoryStateView.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> section(String key) {
      final value = json[key];
      return value is Map<String, dynamic> ? value : const <String, dynamic>{};
    }

    return MemoryStateView(
      enabled: json['enabled'] as bool? ?? false,
      counts: MemoryCounts.fromJson(section('counts')),
      digest: DigestSummary.fromJson(section('digest')),
      extract: ExtractQuota.fromJson(section('extract')),
      heartbeat: HeartbeatView.fromJson(section('heartbeat')),
      // 老服务端不返回这一节：按"没在整理"处理，按钮照常可用。
      maintenance: MaintenanceView.fromJson(section('maintenance')),
      digestWarning: json['digest_warning'] as String?,
    );
  }

  final bool enabled;
  final MemoryCounts counts;
  final DigestSummary digest;
  final ExtractQuota extract;
  final HeartbeatView heartbeat;
  final MaintenanceView maintenance;

  /// 摘要生成不出来时的一句话（目前只有"置顶超出预算"）。
  final String? digestWarning;
}

/// digest 快照列表项。
class DigestListItem {
  const DigestListItem({
    required this.id,
    required this.chars,
    required this.createdAt,
  });

  factory DigestListItem.fromJson(Map<String, dynamic> json) {
    return DigestListItem(
      id: json['id'] as String? ?? '',
      chars: (json['chars'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final int chars;
  final int createdAt;
}

/// 一份 digest 快照全文。
class DigestView {
  const DigestView({
    required this.id,
    required this.content,
    required this.chars,
    required this.createdAt,
    required this.memoryIds,
  });

  factory DigestView.fromJson(Map<String, dynamic> json) {
    return DigestView(
      id: json['id'] as String? ?? '',
      content: json['content'] as String? ?? '',
      chars: (json['chars'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      memoryIds: <String>[
        for (final id in (json['memory_ids'] as List<dynamic>? ?? const []))
          if (id is String) id,
      ],
    );
  }

  final String id;
  final String content;
  final int chars;
  final int createdAt;
  final List<String> memoryIds;
}

/// Unix 毫秒 → `YYYY-MM-DD`。摘要与来源卡片都只到天。
String formatDate(int milliseconds) {
  if (milliseconds <= 0) {
    return '时间未知';
  }
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// 实体类型。
enum EntityType {
  person('person', '人物'),
  org('org', '组织'),
  project('project', '项目'),
  device('device', '设备'),
  recurring('recurring', '周期事项');

  const EntityType(this.wire, this.label);

  final String wire;
  final String label;

  static EntityType parse(Object? raw) {
    for (final type in values) {
      if (type.wire == raw) {
        return type;
      }
    }
    return person;
  }
}

/// 实体状态。`merged` 的实体已经并到别人身上，不再出现在列表里。
enum EntityStatus {
  pending('pending', '待确认'),
  active('active', '生效'),
  archived('archived', '已归档'),
  merged('merged', '已合并');

  const EntityStatus(this.wire, this.label);

  final String wire;
  final String label;

  static EntityStatus parse(Object? raw) {
    for (final status in values) {
      if (status.wire == raw) {
        return status;
      }
    }
    return pending;
  }
}

/// 一个主体（人 / 组织 / 项目 / 设备 / 周期事项）。
class Entity {
  const Entity({
    required this.id,
    required this.entityType,
    required this.name,
    required this.status,
    required this.aliases,
    required this.confidence,
    required this.evidenceCount,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.projectPath,
    this.mergedInto,
    this.snapshot = '',
    this.snapshotAt,
    this.lastEvidenceAt,
  });

  factory Entity.fromJson(Map<String, dynamic> json) {
    return Entity(
      id: json['id'] as String? ?? '',
      entityType: EntityType.parse(json['entity_type']),
      name: json['name'] as String? ?? '',
      status: EntityStatus.parse(json['status']),
      aliases: <String>[
        for (final alias in (json['aliases'] as List<dynamic>? ?? const []))
          if (alias is String) alias,
      ],
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      evidenceCount: (json['evidence_count'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      projectId: json['project_id'] as String?,
      projectPath: json['project_path'] as String?,
      mergedInto: json['merged_into'] as String?,
      snapshot: json['snapshot'] as String? ?? '',
      snapshotAt: (json['snapshot_at'] as num?)?.toInt(),
      lastEvidenceAt: (json['last_evidence_at'] as num?)?.toInt(),
    );
  }

  final String id;
  final EntityType entityType;
  final String name;
  final EntityStatus status;
  final List<String> aliases;
  final double confidence;
  final int evidenceCount;
  final int createdAt;
  final int updatedAt;
  final String? projectId;
  final String? projectPath;
  final String? mergedInto;

  /// 一句话状态快照。空串表示夜间重算还没跑过。
  final String snapshot;
  final int? snapshotAt;
  final int? lastEvidenceAt;

  bool get hasSnapshot => snapshot.trim().isNotEmpty;

  String get metaLine =>
      '${entityType.label} · ${status.label} · $evidenceCount 条记忆';
}

class EntitySnapshotItem {
  const EntitySnapshotItem({
    required this.id,
    required this.snapshot,
    required this.evidenceCount,
    required this.createdAt,
  });

  factory EntitySnapshotItem.fromJson(Map<String, dynamic> json) {
    return EntitySnapshotItem(
      id: json['id'] as String? ?? '',
      snapshot: json['snapshot'] as String? ?? '',
      evidenceCount: (json['evidence_count'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String snapshot;
  final int evidenceCount;
  final int createdAt;
}

class EntityDetail {
  const EntityDetail({
    required this.entity,
    required this.timeline,
    required this.snapshots,
  });

  factory EntityDetail.fromJson(Map<String, dynamic> json) {
    final rawEntity = json['entity'];
    return EntityDetail(
      entity: Entity.fromJson(
        rawEntity is Map<String, dynamic> ? rawEntity : const <String, dynamic>{},
      ),
      timeline: <Memory>[
        for (final item in (json['timeline'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) Memory.fromJson(item),
      ],
      snapshots: <EntitySnapshotItem>[
        for (final item in (json['snapshots'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) EntitySnapshotItem.fromJson(item),
      ],
    );
  }

  final Entity entity;
  final List<Memory> timeline;
  final List<EntitySnapshotItem> snapshots;
}

class EntityPage {
  const EntityPage({required this.items, this.nextCursor});

  factory EntityPage.fromJson(Map<String, dynamic> json) {
    return EntityPage(
      items: <Entity>[
        for (final item in (json['items'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) Entity.fromJson(item),
      ],
      nextCursor: json['next_cursor'] as String?,
    );
  }

  final List<Entity> items;
  final String? nextCursor;
}

/// 候选决策结果。`skipped` 里是"已经不是候选"的 id，重放时正常。
class CandidateDecisionResult {
  const CandidateDecisionResult({
    required this.accepted,
    required this.rejected,
    required this.skipped,
  });

  factory CandidateDecisionResult.fromJson(Map<String, dynamic> json) {
    return CandidateDecisionResult(
      accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      rejected: (json['rejected'] as num?)?.toInt() ?? 0,
      skipped: <String>[
        for (final id in (json['skipped'] as List<dynamic>? ?? const []))
          if (id is String) id,
      ],
    );
  }

  final int accepted;
  final int rejected;
  final List<String> skipped;
}

class BatchRevokeResult {
  const BatchRevokeResult({required this.batchId, required this.revoked});

  factory BatchRevokeResult.fromJson(Map<String, dynamic> json) {
    return BatchRevokeResult(
      batchId: json['batch_id'] as String? ?? '',
      revoked: (json['revoked'] as num?)?.toInt() ?? 0,
    );
  }

  final String batchId;
  final int revoked;
}

/// 导出预览：`diff` 是 unified diff 文本，展示后才能写入。
class ExportPreview {
  const ExportPreview({
    required this.projectId,
    required this.path,
    required this.diff,
    required this.entries,
    required this.contentHash,
  });

  factory ExportPreview.fromJson(Map<String, dynamic> json) {
    return ExportPreview(
      projectId: json['project_id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      diff: json['diff'] as String? ?? '',
      entries: (json['entries'] as num?)?.toInt() ?? 0,
      contentHash: json['content_hash'] as String? ?? '',
    );
  }

  final String projectId;
  final String path;
  final String diff;
  final int entries;
  final String contentHash;

  bool get isNoop => diff.trim().isEmpty;
}

/// 一批候选：候选不是独立表，只是 `status=candidate` 的记忆，
/// 这里按 `batch_id` 分组只是为了界面上"一次抽取"是一个整体。
class CandidateBatch {
  const CandidateBatch({
    required this.batchId,
    required this.items,
    required this.createdAt,
  });

  final String? batchId;
  final List<Memory> items;
  final int createdAt;

  String get sourceLabel {
    final first = items.isEmpty ? null : items.first;
    return first == null ? '未知来源' : first.source.label;
  }
}

/// 静音类别。
enum NotificationCategory {
  due('due', '截止提醒'),
  todo('todo', '待办推进'),
  digestReport('digest_report', '整理报告');

  const NotificationCategory(this.wire, this.label);

  final String wire;
  final String label;

  static NotificationCategory? parse(Object? raw) {
    for (final category in values) {
      if (category.wire == raw) {
        return category;
      }
    }
    return null;
  }
}

/// 授权作用域。
enum GrantScope {
  task('task', '本任务'),
  session('session', '本会话（24 小时）'),
  project('project', '本项目（7 天）');

  const GrantScope(this.wire, this.label);

  final String wire;
  final String label;

  static GrantScope parse(Object? raw) {
    for (final scope in values) {
      if (scope.wire == raw) {
        return scope;
      }
    }
    return task;
  }
}

/// 风险档。客户端只做展示，判定始终在服务端。
enum GrantRisk {
  read('read', '只读'),
  reversibleWrite('reversible_write', '可回滚写'),
  irreversibleWrite('irreversible_write', '不可逆');

  const GrantRisk(this.wire, this.label);

  final String wire;
  final String label;

  static GrantRisk parse(Object? raw) {
    for (final risk in values) {
      if (risk.wire == raw) {
        return risk;
      }
    }
    return irreversibleWrite;
  }
}

/// 一条执行授权：审批的缓存层，只跳过"询问"。
class Grant {
  const Grant({
    required this.id,
    required this.tool,
    required this.risk,
    required this.scope,
    required this.scopeId,
    required this.approvedBy,
    required this.createdAt,
    required this.expiresAt,
    required this.hitCount,
    this.revokedAt,
    this.lastHitAt,
  });

  factory Grant.fromJson(Map<String, dynamic> json) {
    return Grant(
      id: json['id'] as String? ?? '',
      tool: json['tool'] as String? ?? '',
      risk: GrantRisk.parse(json['risk']),
      scope: GrantScope.parse(json['scope']),
      scopeId: json['scope_id'] as String? ?? '',
      approvedBy: json['approved_by'] as String? ?? '',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
      hitCount: (json['hit_count'] as num?)?.toInt() ?? 0,
      revokedAt: (json['revoked_at'] as num?)?.toInt(),
      lastHitAt: (json['last_hit_at'] as num?)?.toInt(),
    );
  }

  final String id;
  final String tool;
  final GrantRisk risk;
  final GrantScope scope;
  final String scopeId;
  final String approvedBy;
  final int createdAt;
  final int expiresAt;
  final int hitCount;
  final int? revokedAt;
  final int? lastHitAt;

  bool isAlive(int now) => revokedAt == null && expiresAt > now;

  /// 剩余时间：`mm:ss` / `N 小时` / `N 天`。
  String remaining(int now) {
    final left = expiresAt - now;
    if (left <= 0) {
      return '已过期';
    }
    final minutes = left ~/ 60_000;
    if (minutes < 60) {
      final seconds = (left % 60_000) ~/ 1000;
      return '$minutes 分 ${seconds.toString().padLeft(2, '0')} 秒';
    }
    final hours = minutes ~/ 60;
    if (hours < 48) {
      return '$hours 小时';
    }
    return '${hours ~/ 24} 天';
  }
}

class GrantPage {
  const GrantPage({required this.items, this.nextCursor});

  factory GrantPage.fromJson(Map<String, dynamic> json) {
    return GrantPage(
      items: <Grant>[
        for (final item in (json['items'] as List<dynamic>? ?? const []))
          if (item is Map<String, dynamic>) Grant.fromJson(item),
      ],
      nextCursor: json['next_cursor'] as String?,
    );
  }

  final List<Grant> items;
  final String? nextCursor;
}
