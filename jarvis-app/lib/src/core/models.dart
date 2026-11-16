// 服务端返回数据的轻量视图模型。
//
// 只做字段映射，不放业务判断；状态含义与 `api-spec` 保持一致。

import 'dart:typed_data';

import 'design/app_theme_spec.dart';

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.projectId = '',
    this.mode = 'text',
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    return ConversationSummary(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名会话',
      updatedAt: json['updated_at'] as int? ?? 0,
      projectId: json['project_id'] as String? ?? '',
      mode: json['mode'] as String? ?? 'text',
    );
  }

  final String id;
  final String title;
  final int updatedAt;
  final String projectId;
  final String mode;
}

/// 项目模式取值。服务端只认这两个字符串，客户端不自行发明第三种。
class ProjectModes {
  const ProjectModes._();

  /// 专注编程：绑定 git 仓库，唯一允许 Git 与编码任务的模式。
  static const String code = 'code';

  /// 专注除编程之外的生活、办公事务：绑定任意目录，没有任何 Git 入口。
  static const String work = 'work';
}

// 模式只作为能力开关留在数据里：界面不再展示、也不按它过滤。
// 新建项目时勾了「Git 仓库」就是 `code`，否则 `work`。
// 任何把 `ssh` 当成 `mode=` 传给 `/api/projects`、`/api/fs/dirs`、`/api/skills`
// 的调用都是缺陷，服务端不认识这个值。

/// 项目：会话与任务的归属，对应服务端这台电脑上的一个真实目录。
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.mode,
    required this.path,
    this.conversationCount = 0,
    this.taskCount = 0,
    this.updatedAt = 0,
  });

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名项目',
      mode: json['mode'] as String? ?? ProjectModes.work,
      path: json['path'] as String? ?? '',
      conversationCount: json['conversation_count'] as int? ?? 0,
      taskCount: json['task_count'] as int? ?? 0,
      updatedAt: json['updated_at'] as int? ?? 0,
    );
  }

  final String id;
  final String name;
  final String mode;

  /// 服务端电脑上的绝对路径。客户端不解释它，只负责展示与复制。
  final String path;
  final int conversationCount;
  final int taskCount;
  final int updatedAt;

  bool get isCode => mode == ProjectModes.code;

  /// 目录名的末段：路径太长时用它做次要信息的兜底。
  String get directoryName {
    final segments = path.split('/').where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }
}

/// 目录浏览里的一个条目。只可能是目录，`repo` 表示它本身是 git 仓库根。
class DirEntry {
  const DirEntry({required this.name, required this.path, required this.kind});

  factory DirEntry.fromJson(Map<String, dynamic> json) {
    return DirEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: json['kind'] as String? ?? 'dir',
    );
  }

  final String name;
  final String path;
  final String kind;

  bool get isRepo => kind == 'repo';
}

/// 一层目录的浏览结果。
class DirListing {
  const DirListing({
    required this.path,
    required this.roots,
    this.parent,
    this.entries = const <DirEntry>[],
  });

  factory DirListing.fromJson(Map<String, dynamic> json) {
    return DirListing(
      path: json['path'] as String? ?? '',
      parent: json['parent'] as String?,
      roots: (json['roots'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false),
      entries: (json['entries'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(DirEntry.fromJson)
          .toList(growable: false),
    );
  }

  final String path;

  /// 上一级；已在某个根目录时为空，客户端据此禁用「上一级」。
  final String? parent;
  final List<String> roots;
  final List<DirEntry> entries;

  /// 面包屑：把当前路径按允许的根切段，保证「回跳」不会跳出白名单。
  List<({String label, String path})> crumbs() {
    final root = roots
        .where(
          (candidate) => path == candidate || path.startsWith('$candidate/'),
        )
        .fold<String?>(null, (best, candidate) {
          if (best == null || candidate.length > best.length) {
            return candidate;
          }
          return best;
        });

    final base = root ?? path;
    final result = <({String label, String path})>[];
    if (root != null) {
      final segments = root.split('/').where((s) => s.isNotEmpty).toList();
      result.add((label: segments.isEmpty ? '/' : segments.last, path: root));
    }

    final rest = path.length > base.length ? path.substring(base.length) : '';
    var current = base;
    for (final segment in rest.split('/').where((s) => s.isNotEmpty)) {
      current = '$current/$segment';
      result.add((label: segment, path: current));
    }
    return result;
  }
}

/// 项目文件树里的一个条目：目录或文件。
///
/// 与 [DirEntry] 分属两个场景：`DirEntry` 是「选项目目录」的选择器，
/// 这里服务于已建项目的右侧栏文件树，文件会带 `size`。
class ProjectEntry {
  const ProjectEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
  });

  factory ProjectEntry.fromJson(Map<String, dynamic> json) {
    return ProjectEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: json['kind'] as String? ?? 'file',
      size: json['size'] as int?,
    );
  }

  final String name;

  /// 服务端规范化后的绝对路径。展开子目录、预览文件都直接回传它。
  final String path;
  final String kind;

  /// 文件字节数；目录为空。
  final int? size;

  bool get isDir => kind == 'dir';
}

/// 项目某一层目录的浏览结果。
class ProjectListing {
  const ProjectListing({
    required this.path,
    this.entries = const <ProjectEntry>[],
    this.truncated = false,
  });

  factory ProjectListing.fromJson(Map<String, dynamic> json) {
    return ProjectListing(
      path: json['path'] as String? ?? '',
      entries: (json['entries'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(ProjectEntry.fromJson)
          .toList(growable: false),
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  final String path;
  final List<ProjectEntry> entries;

  /// 该层条目超过服务端上限（200 条）时为 true。
  final bool truncated;
}

/// 项目内一个文本文件的内容。
///
/// [size] 是磁盘上的完整大小，[text] 可能被截断（[truncated]）；
/// 两者分开才能显示「共 3.2 MB，仅显示前 512 KB」。
class FileContent {
  const FileContent({
    required this.path,
    required this.size,
    required this.text,
    this.truncated = false,
  });

  factory FileContent.fromJson(Map<String, dynamic> json) {
    return FileContent(
      path: json['path'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      text: json['text'] as String? ?? '',
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  final String path;
  final int size;
  final String text;
  final bool truncated;
}

/// 项目内一个文件的原始字节（图片 / PDF）。
///
/// [contentType] 以服务端响应头为准：扩展名与真实内容不一致时，头更可信
/// （客户端路由只看扩展名决定"用哪个查看器"，解码仍以字节本身为准）。
class ProjectFileBytes {
  const ProjectFileBytes({
    required this.bytes,
    required this.size,
    this.contentType,
  });

  /// 完整字节，不做截断。服务端已在 64 MB 处拦过，这里不再二次判断。
  final Uint8List bytes;

  /// 字节数。便于界面直接显示，不必各处 `bytes.length`。
  final int size;

  /// 服务端声明的 MIME；缺失时为 null。
  final String? contentType;
}

/// 人类可读的文件大小。右栏很窄，只保留一位小数。
String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }

  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }

  final fixed = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  final text = fixed.endsWith('.0')
      ? fixed.substring(0, fixed.length - 2)
      : fixed;
  return '$text ${units[unit]}';
}

/// 从绝对路径取文件名，兼容 `/` 与 `\`。
String fileNameOf(String path) {
  final segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? path : segments.last;
}

/// Git 项目目录的 git 状态取值，与 `protocol::GitState` 一一对应。
class GitStates {
  const GitStates._();

  static const String ready = 'ready';
  static const String missing = 'missing';
  static const String nested = 'nested';
  static const String noCommits = 'no_commits';
  static const String detached = 'detached';
  static const String notApplicable = 'not_applicable';
}

/// 建项目前的预检结果。
///
/// 服务端算好"能不能直接建、缺什么、能不能现场补"，客户端只负责展示与确认：
/// 错误码 `code_project_denied` 同时覆盖越界、无权限、不是仓库、游离 HEAD，
/// 靠它区分不了哪一种可修。
class ProjectPreflight {
  const ProjectPreflight({
    required this.path,
    required this.mode,
    required this.ready,
    required this.git,
    required this.canInit,
    this.gitDetail,
    this.reason,
  });

  factory ProjectPreflight.fromJson(Map<String, dynamic> json) {
    return ProjectPreflight(
      path: json['path'] as String? ?? '',
      mode: json['mode'] as String? ?? ProjectModes.work,
      ready: json['ready'] as bool? ?? false,
      git: json['git'] as String? ?? GitStates.notApplicable,
      gitDetail: json['git_detail'] as String?,
      canInit: json['can_init'] as bool? ?? false,
      reason: json['reason'] as String?,
    );
  }

  final String path;
  final String mode;
  final bool ready;
  final String git;

  /// `nested` 时是所属仓库路径；`ready` 时是当前分支名。
  final String? gitDetail;

  /// 可以在用户确认后带 `init_git: true` 重试。
  final bool canInit;
  final String? reason;

  bool get isRepo => git == GitStates.ready;

  /// 需要用户点头才能继续（弹确认框）。
  bool get needsInit => canInit;
}

/// 来源类型。
///
/// 老数据里没有 `kind` 键，`fromJson` 必须回退成 [web]——与 Rust 侧的
/// `#[serde(default)]` 是同一条发版约束：漏了它，升级后历史来源卡片会整批
/// 变成"未知类型"或者干脆渲染不出来。
enum MessageSourceKind {
  /// 网页查证。历史来源全部属于这一类。
  web('web'),

  /// 记忆注入或召回命中。
  memory('memory'),

  /// 本地文档。本期不产生，只占位。
  doc('doc');

  const MessageSourceKind(this.wire);

  /// 线缆上的字符串。
  final String wire;

  /// 未知值一律回退 [web]，不抛异常。
  static MessageSourceKind parse(Object? raw) {
    for (final kind in values) {
      if (kind.wire == raw) {
        return kind;
      }
    }
    return web;
  }
}

/// 回答引用的一条来源。
///
/// 服务端已经把它从正文里剥出来单独下发，客户端只负责展示，
/// 不再从 `[来源: …]` 这种文本里做正则提取。
class MessageSource {
  const MessageSource({
    required this.url,
    required this.fetchedAt,
    this.kind = MessageSourceKind.web,
    this.memoryId,
  });

  factory MessageSource.fromJson(Map<String, dynamic> json) {
    return MessageSource(
      url: json['url'] as String? ?? '',
      // 用 num 再取整：服务端可能给 int，也可能给 double（JSON 数字没有类型）。
      fetchedAt: (json['fetched_at'] as num?)?.toInt() ?? 0,
      kind: MessageSourceKind.parse(json['kind']),
      memoryId: json['memory_id'] as String?,
    );
  }

  final String url;
  final int fetchedAt;
  final MessageSourceKind kind;

  /// 记忆来源才有：`memories.id`，据此跳详情。
  final String? memoryId;

  bool get isMemory => kind == MessageSourceKind.memory;

  /// 记忆来源能否点开：没有 id 时降级为纯文本，避免点了没反应。
  bool get canOpen => isMemory && (memoryId ?? '').isNotEmpty;

  /// 卡片上显示的那一小段文本。
  ///
  /// 网页取主机名（完整地址在悬停提示里给），本地文档取项目相对路径——
  /// `file://src/main.rs` 里的 `src` 会被 `Uri` 当成主机名，所以不能走解析。
  String get host {
    if (isMemory) {
      return '来自记忆';
    }
    if (kind == MessageSourceKind.doc) {
      const prefix = 'file://';
      return url.startsWith(prefix) ? url.substring(prefix.length) : url;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return url;
    }
    return uri.host;
  }
}

/// 回答附带的"要不要我办"建议。
///
/// 只是提议：点卡片才会 `POST /api/tasks`。服务端已经校验过技能存在，
/// 客户端只负责展示与传递参数，不再做二次判断。
class TaskSuggestion {
  const TaskSuggestion({
    required this.skill,
    required this.reason,
    this.input = const <String, dynamic>{},
  });

  factory TaskSuggestion.fromJson(Map<String, dynamic> json) {
    final input = json['input'];
    return TaskSuggestion(
      skill: json['skill'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      input: input is Map<String, dynamic> ? input : const <String, dynamic>{},
    );
  }

  final String skill;
  final String reason;
  final Map<String, dynamic> input;
}

/// 会话里生成的一个文件（含待确认覆盖）。
///
/// 状态是服务端给的原值：`written` / `pending` / `rejected` / `expired` /
/// `failed` / `superseded`。客户端只按它决定文案与按钮，不自己推断——
/// 推断出来的状态与服务端不一致时，用户点下去只会拿到 `conflict`。
class FileWriteView {
  const FileWriteView({
    required this.requestId,
    required this.path,
    this.scope = 'draft',
    this.status = 'written',
    this.bytes = 0,
    this.existingBytes = 0,
    this.backupPath,
    this.expiresAt,
    this.createdAt = 0,
  });

  factory FileWriteView.fromJson(Map<String, dynamic> json) {
    return FileWriteView(
      requestId: json['request_id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      scope: json['scope'] as String? ?? 'draft',
      status: json['status'] as String? ?? 'written',
      // 用 num 再取整：服务端可能给 int，也可能给 double。
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      existingBytes: (json['existing_bytes'] as num?)?.toInt() ?? 0,
      backupPath: json['backup_path'] as String?,
      expiresAt: (json['expires_at'] as num?)?.toInt(),
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String requestId;

  /// 根内相对路径（项目相对或草稿相对），绝不带绝对路径。
  final String path;

  /// `project`（会话绑定了项目）或 `draft`（草稿目录）。
  final String scope;

  final String status;

  /// 本次写入的字节数。
  final int bytes;

  /// 被覆盖文件的字节数；新建时为 0。
  final int existingBytes;

  /// 覆盖前备份的绝对路径；没有覆盖时为空。
  final String? backupPath;

  /// 待确认请求的过期时刻（毫秒）；已决策时为空。
  final int? expiresAt;

  final int createdAt;

  bool get isPending => status == 'pending';

  bool get isWritten => status == 'written';

  bool get inProject => scope == 'project';

  String get scopeLabel => inProject ? '项目内' : '会话草稿';

  /// 预览站只托管网页与静态资源，其它类型不给"打开"按钮。
  bool get previewable {
    final lower = path.toLowerCase();
    return lower.endsWith('.html') || lower.endsWith('.htm');
  }

  FileWriteView copyWith({String? status, String? backupPath, int? expiresAt}) {
    return FileWriteView(
      requestId: requestId,
      path: path,
      scope: scope,
      status: status ?? this.status,
      bytes: bytes,
      existingBytes: existingBytes,
      backupPath: backupPath ?? this.backupPath,
      expiresAt: expiresAt ?? this.expiresAt,
      createdAt: createdAt,
    );
  }
}

/// 执行过程中的一步（一次工具调用）。
///
/// [label] 由服务端拼好（`已读取 calculator2.html`），客户端不认识工具名——
/// 每加一个工具都要改前端文案是没必要的工作量。
class ChatStep {
  const ChatStep({
    this.id = '',
    required this.tool,
    required this.label,
    this.target = '',
    this.ok = true,
    this.elapsedMs = 0,
    this.running = false,
    this.error,
  });

  factory ChatStep.fromJson(Map<String, dynamic> json) {
    return ChatStep(
      tool: json['tool'] as String? ?? '',
      label: json['label'] as String? ?? '',
      target: json['target'] as String? ?? '',
      ok: json['ok'] as bool? ?? true,
      elapsedMs: (json['elapsed_ms'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
    );
  }

  /// 流式事件的 `call_id`。同一次调用会有 running 与 ok 两帧，
  /// 靠它更新同一行；落库的步骤不带 id（一个 id 已经没用了）。
  final String id;
  final String tool;
  final String label;

  /// 审计用的对象标识（`file:a.html:1-20`、URL），只用于 tooltip。
  final String target;
  final bool ok;
  final int elapsedMs;

  /// 失败原因（服务端已截断）。成功或老数据为空。
  ///
  /// 只做 tooltip：它可能含上游 `request_id`，摊在界面上会把一行撑满，
  /// 但用户点开排查时又必须有。
  final String? error;

  /// 正在执行。只在流式期间为真：落库之后一律是完成态。
  final bool running;

  ChatStep copyWith({
    String? label,
    bool? ok,
    int? elapsedMs,
    bool? running,
  }) {
    return ChatStep(
      id: id,
      tool: tool,
      label: label ?? this.label,
      target: target,
      ok: ok ?? this.ok,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      running: running ?? this.running,
    );
  }
}

/// 一条回答的 token 用量。
///
/// [estimated] 为真表示网关没回 usage、数字是按字符估算的：界面要给数字加
/// "约"，免得把估算值当成账单展示。
class TokenUsage {
  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.estimated = false,
    this.contextTokens = 0,
  });

  factory TokenUsage.fromJson(Map<String, dynamic> json) {
    return TokenUsage(
      promptTokens: json['prompt_tokens'] as int? ?? 0,
      completionTokens: json['completion_tokens'] as int? ?? 0,
      estimated: json['tokens_estimated'] as bool? ?? false,
      contextTokens: json['context_tokens'] as int? ?? 0,
    );
  }

  final int promptTokens;
  final int completionTokens;
  final bool estimated;

  /// 本轮**最后一次**模型调用的输入 token 数，即"当前上下文长度"。
  ///
  /// [promptTokens] 是整轮累加值（多步工具调用会把前几次输入重复算进去），
  /// 不能直接拿来算占比；这一项才是输入栏环形要的分子。
  /// 历史旧消息没有这个字段，读回为 0。
  final int contextTokens;

  int get total => promptTokens + completionTokens;
}

/// 一张生成的图片或一段生成的视频。
///
/// 只带元信息：正文按 [id] 走 `/api/media/{id}/content` 另取。
/// 把几 MB 的字节塞进消息体，会让每次拉历史都把整段产物读一遍。
class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.kind,
    required this.mime,
    required this.bytes,
    this.model = '',
    this.prompt = '',
    this.width,
    this.height,
    this.durationMs,
    this.resolution,
    this.createdAt = 0,
  });

  factory MediaAsset.fromJson(Map<String, dynamic> json) {
    return MediaAsset(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? 'image',
      mime: json['mime'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      model: json['model'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      resolution: json['resolution'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;

  /// `image` / `video`。
  final String kind;
  final String mime;
  final int bytes;

  /// 生成模型，例如 `qwen-image-3.0`。
  final String model;

  /// 原始提示词，作为卡片说明展示。
  final String prompt;

  /// 图片像素宽高；视频不解析 mp4，为 null。
  final int? width;
  final int? height;

  /// 视频时长（毫秒）。
  final int? durationMs;

  /// 视频分辨率档位，例如 `480P`。
  final String? resolution;

  final int createdAt;

  bool get isImage => kind == 'image';

  /// 卡片上的一行规格说明：`1328×1328 · 2.7 MB` / `480P · 5s · 5.3 MB`。
  String get specLabel {
    final parts = <String>[];
    if (isImage) {
      if (width != null && height != null) {
        parts.add('$width×$height');
      }
    } else {
      if (resolution != null && resolution!.isNotEmpty) {
        parts.add(resolution!);
      }
      if (durationMs != null && durationMs! > 0) {
        final seconds = durationMs! / 1000;
        parts.add(seconds == seconds.roundToDouble()
            ? '${seconds.round()}s'
            : '${seconds.toStringAsFixed(1)}s');
      }
    }
    parts.add(formatByteSize(bytes));
    return parts.join(' · ');
  }
}

/// 用户随消息上传的一枚附件。
///
/// 与 [MediaAsset] 方向相反：那个是模型产出给用户看的，这个是用户交给模型的。
/// 同样只放元信息：正文按 [id] 走 `/api/attachments/{id}/content` 另取。
class MessageAttachment {
  const MessageAttachment({
    required this.id,
    required this.name,
    required this.kind,
    required this.mime,
    required this.bytes,
    this.width,
    this.height,
  });

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? 'file',
      mime: json['mime'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }

  final String id;
  final String name;

  /// `image` / `file`。
  final String kind;
  final String mime;
  final int bytes;

  /// 图片像素宽高；非图片或客户端没给时为 null。
  final int? width;
  final int? height;

  bool get isImage => kind == 'image';
}

/// 会话上下文压缩状态。
///
/// 只描述"模型看到的那份上下文"：原文一条不删，界面据此在
/// [anchorMessageId] 处插一条横条，不要拿它去裁剪消息列表。
class CompactionView {
  const CompactionView({
    required this.status,
    this.summary,
    this.anchorMessageId,
    this.sourceMessages = 0,
    this.model,
    this.updatedAt,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.tokensEstimated = false,
    this.elapsedMs,
    this.lastFailure,
  });

  /// 容错解析：整段不是对象、或没有 `status` 时返回 `null`。
  ///
  /// 缺失字段一律按"没有压缩"处理——旧服务端不返回这一节，
  /// 界面不该因为一个新字段就整页报错。
  static CompactionView? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final status = value['status'] as String? ?? '';
    if (status.isEmpty) {
      return null;
    }
    final tokens = value['tokens'];
    final tokenMap = tokens is Map<String, dynamic> ? tokens : const <String, dynamic>{};
    final failure = value['last_failure'];
    return CompactionView(
      status: status,
      summary: value['summary'] as String?,
      anchorMessageId: value['anchor_message_id'] as String?,
      sourceMessages: (value['source_messages'] as num?)?.toInt() ?? 0,
      model: value['model'] as String?,
      updatedAt: (value['updated_at'] as num?)?.toInt(),
      promptTokens: (tokenMap['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (tokenMap['completion_tokens'] as num?)?.toInt() ?? 0,
      tokensEstimated: tokenMap['tokens_estimated'] as bool? ?? false,
      elapsedMs: (value['elapsed_ms'] as num?)?.toInt(),
      lastFailure: failure is Map<String, dynamic>
          ? CompactionFailureView.fromJson(failure)
          : null,
    );
  }

  /// `ready` / `pending` / `failed`（只有失败记录时）。
  final String status;
  final String? summary;

  /// 压缩边界那条消息的 id：横条插在它前面。位置锚点，不是区间端点。
  final String? anchorMessageId;

  /// 被折叠的消息条数。
  final int sourceMessages;
  final String? model;
  final int? updatedAt;
  final int promptTokens;
  final int completionTokens;
  final bool tokensEstimated;
  final int? elapsedMs;
  final CompactionFailureView? lastFailure;

  /// 有可用摘要（可以展示正文）。
  bool get hasSummary => status == 'ready' && (summary?.isNotEmpty ?? false);

  /// 正在整理。
  bool get isPending => status == 'pending';

  /// 这次整理花掉的总 token；没统计到为 0。
  int get totalTokens => promptTokens + completionTokens;

  /// 失败过的角标：成功摘要也可能带着一条"上次失败"的记录。
  bool get hasFailure => lastFailure != null;
}

/// 一次失败的整理尝试。
class CompactionFailureView {
  const CompactionFailureView({required this.error, required this.at, this.model});

  factory CompactionFailureView.fromJson(Map<String, dynamic> json) {
    return CompactionFailureView(
      error: json['error'] as String? ?? '',
      at: (json['at'] as num?)?.toInt() ?? 0,
      model: json['model'] as String?,
    );
  }

  final String error;

  /// 失败时间（毫秒时间戳）。
  final int at;
  final String? model;
}

/// 人类可读的体积。媒体卡片只用这一处，不引入额外依赖。
String formatByteSize(int bytes) {
  const kb = 1024.0;
  final value = bytes.toDouble();
  if (value < kb) {
    return '$bytes B';
  }
  if (value < kb * kb) {
    return '${(value / kb).toStringAsFixed(1)} KB';
  }
  return '${(value / (kb * kb)).toStringAsFixed(1)} MB';
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.sources = const <MessageSource>[],
    this.suggestions = const <TaskSuggestion>[],
    this.fileWrites = const <FileWriteView>[],
    this.media = const <MediaAsset>[],
    this.attachments = const <MessageAttachment>[],
    this.steps = const <ChatStep>[],
    this.createdAt = 0,
    this.streaming = false,
    this.elapsedMs = 0,
    this.usage,
    this.failed = false,
    this.finishReason,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      role: json['role'] as String? ?? 'assistant',
      content: json['content'] as String? ?? '',
      sources: (json['sources'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(MessageSource.fromJson)
          .toList(growable: false),
      suggestions: _suggestionsFromJson(json['task_suggestions']),
      fileWrites: _fileWritesFromJson(json['file_writes']),
      media: _mediaFromJson(json['media']),
      attachments: _attachmentsFromJson(json['attachments']),
      steps: _stepsFromJson(json['steps']),
      createdAt: json['created_at'] as int? ?? 0,
      elapsedMs: json['elapsed_ms'] as int? ?? 0,
      usage: _usageFromJson(json['usage']),
      finishReason: json['finish_reason'] as String?,
    );
  }

  final String id;

  /// `user` / `assistant` / `system` / `tool`。
  ///
  /// `system` 是系统提示（例如「已记住：…」）：不参与对话上下文，
  /// 界面上居中显示、不套气泡。
  final String role;
  final String content;
  final List<MessageSource> sources;
  final List<TaskSuggestion> suggestions;

  /// 本轮生成 / 待确认的文件。历史旧数据没有这个键，解析为默认空列表。
  final List<FileWriteView> fileWrites;

  /// 本轮生成的图片 / 视频。历史旧数据没有这个键，解析为默认空列表。
  final List<MediaAsset> media;

  /// 用户在输入框里附上的文件 / 图片。历史旧消息没有这个键，解析为空列表。
  final List<MessageAttachment> attachments;

  /// 本轮的执行过程，按发生顺序。历史旧数据没有这个键，解析为空列表。
  ///
  /// 流式期间由 `tool_activity` 事件累积，收尾时用 `message_completed`
  /// 带下来的那份覆盖（服务端的是权威，含最终耗时）。
  final List<ChatStep> steps;
  final int createdAt;
  final bool streaming;

  /// 从提问到回答落库的耗时（毫秒）。0 表示不知道（历史旧数据、本地占位）。
  final int elapsedMs;

  /// 这一轮的 token 用量；没有模型或没统计到时为 null。
  final TokenUsage? usage;

  /// 生成过程中出错：状态行要说"失败"而不是"已完成"。
  final bool failed;

  /// 回答终态，服务端给的原值：`stop` / `error` / `stopped`。
  ///
  /// null 是历史旧数据的常态（这一列是后加的），按"已完成"处理。
  final String? finishReason;

  /// 用户点了停止：半截回答是有效的，只是没写完。
  ///
  /// 与 [failed] 分开：失败要报错色、要提示重试，停止是用户自己的选择。
  bool get stopped => finishReason == 'stopped';

  bool get isUser => role == 'user';

  ChatMessage copyWith({
    String? content,
    List<MessageSource>? sources,
    List<TaskSuggestion>? suggestions,
    List<FileWriteView>? fileWrites,
    List<MediaAsset>? media,
    List<MessageAttachment>? attachments,
    List<ChatStep>? steps,
    bool? streaming,
    int? createdAt,
    int? elapsedMs,
    TokenUsage? usage,
    bool? failed,
    String? finishReason,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      sources: sources ?? this.sources,
      suggestions: suggestions ?? this.suggestions,
      fileWrites: fileWrites ?? this.fileWrites,
      media: media ?? this.media,
      attachments: attachments ?? this.attachments,
      steps: steps ?? this.steps,
      createdAt: createdAt ?? this.createdAt,
      streaming: streaming ?? this.streaming,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      usage: usage ?? this.usage,
      failed: failed ?? this.failed,
      finishReason: finishReason ?? this.finishReason,
    );
  }
}

/// 解析 `usage` 对象。形状不对就当"没有统计"，不让界面对此报错。
TokenUsage? _usageFromJson(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    return null;
  }
  final usage = TokenUsage.fromJson(raw);
  return usage.total > 0 ? usage : null;
}

class PlanStepView {
  const PlanStepView({
    required this.seq,
    required this.name,
    required this.state,
    this.output,
    this.updatedAt,
  });

  factory PlanStepView.fromJson(Map<String, dynamic> json) {
    final output = json['output'];
    return PlanStepView(
      seq: json['seq'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      state: json['state'] as String? ?? 'pending',
      // 老服务端没有这两个字段：按"还没有过程信息"处理，不显示空块。
      output: output is String && output.trim().isNotEmpty ? output : null,
      updatedAt: json['updated_at'] as int?,
    );
  }

  final int seq;
  final String name;
  final String state;

  /// 最近一次过程摘要（编码任务一般是最近几个动作，多行）。
  ///
  /// 与 `TaskView.updatedAt` 无关：进度刷新只写这一步的时间，不写任务级
  /// `updated_at`——那个字段是服务端回收悬空任务的判据。
  final String? output;
  final int? updatedAt;

  bool get hasOutput => output != null;
}

class ApprovalView {
  const ApprovalView({
    required this.id,
    required this.action,
    required this.expiresAt,
    this.target,
    this.impact,
    this.previews = const <String>[],
    this.scope = 'task',
    this.tool,
  });

  factory ApprovalView.fromJson(Map<String, dynamic> json) {
    final tool = json['tool'];
    return ApprovalView(
      id: json['id'] as String? ?? '',
      action: json['action'] as String? ?? '',
      target: json['target'] as String?,
      impact: json['impact'] as String?,
      expiresAt: json['expires_at'] as int? ?? 0,
      previews: (json['previews'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
      scope: json['scope'] as String? ?? 'task',
      tool: tool is Map<String, dynamic>
          ? ApprovalToolView.fromJson(tool)
          : null,
    );
  }

  final String id;
  final String action;
  final String? target;
  final String? impact;
  final int expiresAt;
  final List<String> previews;

  /// `task` = 任务级（合并确认）；`tool` = 单次工具调用。
  /// 客户端按它分支渲染，不靠 `action` 前缀匹配。
  final String scope;
  final ApprovalToolView? tool;

  bool get isToolScope => scope == 'tool';
}

/// 工具级审批附带的可读信息（服务端已脱敏截断）。
class ApprovalToolView {
  const ApprovalToolView({
    required this.name,
    required this.risk,
    required this.digest,
    this.rememberable = false,
  });

  factory ApprovalToolView.fromJson(Map<String, dynamic> json) {
    return ApprovalToolView(
      name: json['name'] as String? ?? '',
      risk: json['risk'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
      // 老服务端没有这个字段：默认不提供「本任务内不再询问」。
      rememberable: json['rememberable'] as bool? ?? false,
    );
  }

  final String name;
  final String risk;
  final String digest;

  /// 是否提供「本任务内不再询问这类操作」。由服务端按规则计算
  /// （凭证、提权、越界写永远为 false）。
  final bool rememberable;

  /// 风险等级的中文说明。服务端给的是稳定枚举，这里只做展示映射。
  String get riskLabel {
    switch (risk) {
      case 'read':
        return '只读';
      case 'reversible_write':
        return '可回滚写';
      case 'irreversible_write':
        return '不可逆操作';
      default:
        return '未知风险';
    }
  }

  /// 不可逆操作要用更醒目的颜色。
  bool get isIrreversible => risk == 'irreversible_write';
}

class ArtifactView {
  const ArtifactView({
    required this.id,
    required this.kind,
    required this.size,
    required this.createdAt,
    this.mime,
  });

  factory ArtifactView.fromJson(Map<String, dynamic> json) {
    return ArtifactView(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      mime: json['mime'] as String?,
      createdAt: json['created_at'] as int? ?? 0,
    );
  }

  final String id;
  final String kind;
  final int size;
  final String? mime;
  final int createdAt;
}

/// 编码任务的现场：隔离工作树与任务分支。
///
/// 只在任务详情里下发（列表不带），客户端只负责展示、复制与「清理现场」，
/// 不做任何路径解释——路径在服务端那台电脑上。
class WorktreeView {
  const WorktreeView({
    required this.path,
    required this.branch,
    this.exists = false,
  });

  factory WorktreeView.fromJson(Map<String, dynamic> json) {
    return WorktreeView(
      path: json['path'] as String? ?? '',
      branch: json['branch'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
    );
  }

  final String path;
  final String branch;

  /// 工作树目录是否还在：清理过或从未准备成功时为 false。
  final bool exists;
}

/// 解析 `task_suggestions`。形状不对就当没有建议——老数据里根本没有这个键，
/// 客户端不能因为一个可选字段把整段历史读崩。
List<TaskSuggestion> _suggestionsFromJson(Object? raw) {
  if (raw is! List) {
    return const <TaskSuggestion>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(TaskSuggestion.fromJson)
      .where((suggestion) => suggestion.skill.isNotEmpty)
      .toList(growable: false);
}

/// 解析 `file_writes`。与建议卡同样的容错：形状不对就当没有，
/// 一张卡片读失败不该让整段历史消失。
List<FileWriteView> _fileWritesFromJson(Object? raw) {
  if (raw is! List) {
    return const <FileWriteView>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(FileWriteView.fromJson)
      .where((write) => write.requestId.isNotEmpty && write.path.isNotEmpty)
      .toList(growable: false);
}

/// 解析 `media`。与 `file_writes` 同样的容错：形状不对就当没有，
/// 一张卡片读失败不该让整段历史消失。
List<MediaAsset> _mediaFromJson(Object? raw) {
  if (raw is! List) {
    return const <MediaAsset>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(MediaAsset.fromJson)
      .where((media) => media.id.isNotEmpty && media.mime.isNotEmpty)
      .toList(growable: false);
}

/// 解析 `attachments`。同样容错：老消息没有这个键，形状不对就当没附件。
List<MessageAttachment> _attachmentsFromJson(Object? raw) {
  if (raw is! List) {
    return const <MessageAttachment>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(MessageAttachment.fromJson)
      .where((attachment) => attachment.id.isNotEmpty)
      .toList(growable: false);
}

/// 解析执行过程。老消息没有这个键 → 空列表 → 界面不渲染折叠面板。
List<ChatStep> _stepsFromJson(Object? raw) {
  if (raw is! List) {
    return const <ChatStep>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(ChatStep.fromJson)
      .where((step) => step.label.isNotEmpty)
      .toList(growable: false);
}

class TaskView {
  const TaskView({
    required this.id,
    required this.state,
    required this.type,
    this.conversationId = '',
    this.idempotencyKey,
    this.skill,
    this.plan = const <PlanStepView>[],
    this.pendingApproval,
    this.artifacts = const <ArtifactView>[],
    this.errorCode,
    this.errorHint,
    this.retryCount = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.finishedAt,
    this.worktree,
  });

  factory TaskView.fromJson(Map<String, dynamic> json) {
    final approval = json['pending_approval'];
    final error = json['error'];

    return TaskView(
      id: json['id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      idempotencyKey: json['idempotency_key'] as String?,
      type: json['type'] as String? ?? '',
      skill: json['skill'] as String?,
      state: json['state'] as String? ?? 'queued',
      plan: (json['plan'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(PlanStepView.fromJson)
          .toList(growable: false),
      pendingApproval: approval is Map<String, dynamic>
          ? ApprovalView.fromJson(approval)
          : null,
      artifacts: (json['artifacts'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(ArtifactView.fromJson)
          .toList(growable: false),
      errorCode: error is Map<String, dynamic>
          ? error['code'] as String?
          : null,
      errorHint: error is Map<String, dynamic>
          ? error['hint'] as String?
          : null,
      retryCount: json['retry_count'] as int? ?? 0,
      createdAt: json['created_at'] as int? ?? 0,
      updatedAt: json['updated_at'] as int? ?? 0,
      finishedAt: json['finished_at'] as int?,
      worktree: json['worktree'] is Map<String, dynamic>
          ? WorktreeView.fromJson(json['worktree'] as Map<String, dynamic>)
          : null,
    );
  }

  final String id;
  final String conversationId;

  /// 创建时的幂等键。建议卡用它和任务对上号；任务删除后可能为 null。
  final String? idempotencyKey;
  final String type;
  final String? skill;
  final String state;
  final List<PlanStepView> plan;
  final ApprovalView? pendingApproval;
  final List<ArtifactView> artifacts;
  final String? errorCode;
  final String? errorHint;
  final int retryCount;
  final int createdAt;
  final int updatedAt;
  final int? finishedAt;

  /// 编码任务的现场；普通任务为 null（列表接口不下发）。
  final WorktreeView? worktree;

  bool get isTerminal =>
      state == 'succeeded' || state == 'failed' || state == 'canceled';

  bool get canCancel =>
      state == 'queued' ||
      state == 'running' ||
      state == 'needs_input' ||
      state == 'needs_approval';

  bool get canRetry => state == 'failed' || state == 'canceled';
}

/// 状态的中文标签与语义色（由界面决定颜色，不在模型里存颜色值）。
String taskStateLabel(String state) {
  return switch (state) {
    'queued' => '排队中',
    'running' => '执行中',
    'needs_input' => '等待补充信息',
    'needs_approval' => '等待确认',
    'succeeded' => '已完成',
    'failed' => '失败',
    'canceled' => '已取消',
    _ => state,
  };
}

/// 产物种类的中文名。
///
/// 编码任务的三件产物是调试信息，`kind` 本身是英文标识；直接显示 `run_log`
/// 会让人以为那是文件名。
String artifactKindLabel(String kind) {
  return switch (kind) {
    'run_log' => '运行日志',
    'change_summary' => '改动摘要',
    'diff' => '改动补丁',
    'plan_table' => '方案表格',
    'report' => '报告',
    'screenshot' => '截图',
    _ => kind,
  };
}

String planStepLabel(String state) {
  return switch (state) {
    'pending' => '未开始',
    'running' => '进行中',
    'done' => '已完成',
    'skipped' => '已跳过',
    'failed' => '失败',
    _ => state,
  };
}

/// 编码 CLI 的静态能力（`GET /api/code/providers`）。
///
/// 客户端不按 provider 名字写死按钮：能不能逐次放行、能不能追加需求，
/// 全部以服务端给的这份为准。
class CodeCapabilitiesView {
  const CodeCapabilitiesView({
    this.toolApproval = 'unsupported',
    this.appendMessage = false,
    this.switchModel = false,
    this.streamEvents = false,
  });

  factory CodeCapabilitiesView.fromJson(Map<String, dynamic> json) {
    return CodeCapabilitiesView(
      toolApproval: json['tool_approval'] as String? ?? 'unsupported',
      appendMessage: json['append_message'] as bool? ?? false,
      switchModel: json['switch_model'] as bool? ?? false,
      streamEvents: json['stream_events'] as bool? ?? false,
    );
  }

  /// `native` / `degraded` / `unsupported`
  final String toolApproval;
  final bool appendMessage;
  final bool switchModel;
  final bool streamEvents;

  /// 能否对单次工具调用做放行/驳回。
  bool get nativeToolApproval => toolApproval == 'native';

  /// 驳回按钮的文案：做不到单条驳回的 CLI 只能终止整个会话。
  String get rejectLabel => nativeToolApproval ? '驳回并跳过' : '驳回并终止';
}

class CodeProviderView {
  const CodeProviderView({
    required this.id,
    required this.enabled,
    required this.available,
    this.bin,
    this.capabilities = const CodeCapabilitiesView(),
  });

  factory CodeProviderView.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'];
    return CodeProviderView(
      id: json['id'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      available: json['available'] as bool? ?? false,
      bin: json['bin'] as String?,
      capabilities: capabilities is Map<String, dynamic>
          ? CodeCapabilitiesView.fromJson(capabilities)
          : const CodeCapabilitiesView(),
    );
  }

  final String id;
  final bool enabled;
  final bool available;
  final String? bin;
  final CodeCapabilitiesView capabilities;

  /// 展示名。服务端只给稳定的 id，中文名放客户端（改文案不用发服务端）。
  String get label {
    return switch (id) {
      'opencode' => 'OpenCode',
      'codebuddy' => 'CodeBuddy',
      'codex' => 'Codex',
      'claude' => 'Claude Code',
      _ => id,
    };
  }
}

class CodeProvidersView {
  const CodeProvidersView({
    required this.defaultProvider,
    this.available = const <String>[],
    this.providers = const <CodeProviderView>[],
    this.fastModel = '',
    this.strongModel = '',
  });

  factory CodeProvidersView.fromJson(Map<String, dynamic> json) {
    final routing = json['routing'];
    final tiers = routing is Map<String, dynamic> ? routing['tiers'] : null;
    return CodeProvidersView(
      defaultProvider: json['default_provider'] as String? ?? '',
      available: (json['available'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
      providers: (json['providers'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(CodeProviderView.fromJson)
          .toList(growable: false),
      fastModel: tiers is Map<String, dynamic>
          ? tiers['fast'] as String? ?? ''
          : '',
      strongModel: tiers is Map<String, dynamic>
          ? tiers['strong'] as String? ?? ''
          : '',
    );
  }

  final String defaultProvider;

  /// 按路由优先级排好的可用 provider id。
  final List<String> available;
  final List<CodeProviderView> providers;
  final String fastModel;
  final String strongModel;

  /// 能真正派单的 provider（已启用且装了可执行文件）。
  List<CodeProviderView> get runnable =>
      providers.where((provider) => provider.available).toList(growable: false);
}

/// 技能当前可用状态。与服务端 `Skill.status` 三态一一对应。
///
/// 三态而不是布尔：`degraded` 能跑但可能不完整（例如未声明工具却在正文里
/// 提到脚本），`unsupported` 则根本跑不了——两者该给用户的提示完全不同。
enum SkillSupport {
  supported,
  degraded,
  unsupported;

  static SkillSupport parse(String? raw) => switch (raw) {
    'degraded' => SkillSupport.degraded,
    'unsupported' => SkillSupport.unsupported,
    _ => SkillSupport.supported,
  };

  String get label => switch (this) {
    SkillSupport.supported => '可用',
    SkillSupport.degraded => '降级',
    SkillSupport.unsupported => '不支持',
  };
}

/// 一条技能（内置或插件提供）。字段与服务端 `Skill` 契约一致。
class SkillInfo {
  const SkillInfo({
    required this.name,
    required this.version,
    required this.source,
    required this.riskLevel,
    required this.support,
    this.pluginName = '',
    this.description = '',
    this.requiredTools = const <String>[],
    this.reasons = const <String>[],
  });

  factory SkillInfo.fromJson(Map<String, dynamic> json) {
    return SkillInfo(
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      source: json['source'] as String? ?? 'builtin',
      riskLevel: json['risk_level'] as String? ?? 'read',
      support: SkillSupport.parse(json['status'] as String?),
      pluginName: json['plugin_name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      requiredTools: (json['required_tools'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
      reasons: (json['reasons'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
    );
  }

  final String name;
  final String version;

  /// `builtin` / `third_party`
  final String source;
  final String riskLevel;
  final SkillSupport support;
  final String pluginName;
  final String description;

  /// 技能声明的能力名。`code.exec` 表示编码任务，走独立执行路径。
  final List<String> requiredTools;

  /// 降级或不支持的可读原因，服务端已写成给用户看的话。
  final List<String> reasons;

  bool get isBuiltin => source == 'builtin';
}

/// 一个已安装的技能包。
class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.skills,
    this.author = '',
    this.description = '',
  });

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    return PluginInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      skills: (json['skills'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(SkillInfo.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String version;
  final bool enabled;
  final String author;
  final String description;
  final List<SkillInfo> skills;
}

/// 插件列表与「改动是否已生效」。
///
/// `pendingReload` 为 true 表示刚装/停用/卸载过，但执行进程还有任务在跑：
/// 界面要说「当前任务结束后生效」，不能让用户以为马上就能用。
class PluginPage {
  const PluginPage({
    required this.items,
    required this.pendingReload,
  });

  factory PluginPage.fromJson(Map<String, dynamic> json) {
    return PluginPage(
      items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(PluginInfo.fromJson)
          .toList(growable: false),
      pendingReload: json['pending_reload'] as bool? ?? false,
    );
  }

  final List<PluginInfo> items;
  final bool pendingReload;

  static const PluginPage empty = PluginPage(
    items: <PluginInfo>[],
    pendingReload: false,
  );
}

/// 已安装的主题包列表。
///
/// 与技能包不同，主题包没有启停、也没有 `pending_reload`：换肤完全在客户端
/// 完成，执行进程不参与。列表是"几十个"量级，服务端一次全量返回。
class ThemePage {
  const ThemePage({required this.items});

  factory ThemePage.fromJson(Map<String, dynamic> json) {
    return ThemePage(
      items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(AppThemeSpec.fromJson)
          .where((spec) => spec.isUsable)
          .toList(growable: false),
    );
  }

  final List<AppThemeSpec> items;

  /// 按 id 找主题包；找不到返回 null（调用方据此判"已失效"）。
  AppThemeSpec? byId(String? id) {
    if (id == null || id.isEmpty) {
      return null;
    }
    for (final spec in items) {
      if (spec.id == id) {
        return spec;
      }
    }
    return null;
  }

  static const ThemePage empty = ThemePage(items: <AppThemeSpec>[]);
}

/// 派任务前的参数解析结果（`POST /api/tasks/prepare`）。
///
/// `fromModel=false` 表示服务端没解析出来、只带了原话：此时 `missing` 会列出
/// 技能声明需要但没拿到的字段，界面据此提示，而不是假装参数齐了。
class PreparedTaskInput {
  const PreparedTaskInput({
    required this.input,
    required this.fromModel,
    this.missing = const <String>[],
  });

  factory PreparedTaskInput.fromJson(Map<String, dynamic> json) {
    return PreparedTaskInput(
      input: json['input'] is Map<String, dynamic>
          ? json['input'] as Map<String, dynamic>
          : const <String, dynamic>{},
      fromModel: json['source'] == 'model',
      missing: (json['missing'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
    );
  }

  final Map<String, dynamic> input;

  /// 参数是模型解析出来的；false 表示只有原文。
  final bool fromModel;

  /// 技能需要、这次没拿到的字段（`url` / `city` / `pattern` …）。
  final List<String> missing;
}

/// 一份模型配置的对外视图（`GET /api/models` 的 `models[]`）。
///
/// **没有密钥字段**：服务端只给来源与末四位，客户端也就不该有地方接完整 Key。
class ModelProfileView {
  const ModelProfileView({
    required this.id,
    required this.name,
    required this.builtin,
    required this.active,
    required this.enabled,
    required this.baseUrl,
    required this.apiPath,
    required this.model,
    this.modelName = '',
    required this.vision,
    this.reasoning = false,
    this.contextWindow = 0,
    required this.available,
    this.reason,
    this.apiKeySource = 'none',
    this.apiKeyHint,
  });

  factory ModelProfileView.fromJson(Map<String, dynamic> json) {
    return ModelProfileView(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      builtin: json['builtin'] as bool? ?? false,
      active: json['active'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      baseUrl: json['base_url'] as String? ?? '',
      apiPath: json['api_path'] as String? ?? '',
      model: json['model'] as String? ?? '',
      modelName: json['model_name'] as String? ?? '',
      vision: json['vision'] as bool? ?? false,
      reasoning: json['reasoning'] as bool? ?? false,
      contextWindow: (json['context_window'] as num?)?.toInt() ?? 0,
      available: json['available'] as bool? ?? false,
      reason: json['reason'] as String?,
      apiKeySource: json['api_key_source'] as String? ?? 'none',
      apiKeyHint: json['api_key_hint'] as String?,
    );
  }

  final String id;

  /// 配置名（列表标题）。
  final String name;

  /// 默认档（来自服务端配置文件主节）：可编辑、可设为当前，但删不掉。
  final bool builtin;

  /// 是否为当前生效的配置。
  final bool active;
  final bool enabled;
  final String baseUrl;
  final String apiPath;

  /// 模型ID：发给上游 `model` 字段的值，`deepseek-chat` 这种。
  final String model;

  /// 人可读的模型名（例如 `DeepSeek V3.2 Flash`）；可空，空时界面回退 [model]。
  final String modelName;
  final bool vision;

  /// 上游认不认 `reasoning_effort`（输入栏的「推理等级」）。
  ///
  /// 为假时输入栏不显示那一行，服务端也不会把该字段发出去——多数第三方
  /// OpenAI 兼容网关不认这个参数，硬发会让整轮对话 400。
  final bool reasoning;

  /// 模型最大上下文窗口（tokens）：输入栏环形占比的分母。
  ///
  /// 服务端总会下发（默认档 1M、新建配置 128K）；旧服务端没有该字段时为 0，
  /// 环形按"窗口未配置"处理。
  final int contextWindow;

  /// 现在能不能发请求。
  final bool available;

  /// 不能用的原因（已停用 / 未填网关地址 / 未填模型ID / 缺少密钥）。
  final String? reason;

  /// `secrets` / `env` / `none`。
  final String apiKeySource;

  /// 末四位提示，形如 `…9f2a`。
  final String? apiKeyHint;

  /// 界面展示用的模型名：填了模型名就用它，否则回退模型ID。
  String get displayModel {
    final named = modelName.trim();
    return named.isEmpty ? model : named;
  }

  /// 卡片副行用的紧凑描述：`<模型名或模型ID> · <host> · <path>`。
  String get summaryLine {
    final host = baseUrl
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/.*$'), '');
    final shown = displayModel;
    return <String>[
      shown.isEmpty ? '未填模型ID' : shown,
      if (host.isNotEmpty) host,
      if (apiPath.isNotEmpty) apiPath,
    ].join(' · ');
  }

  /// 密钥状态的一句话：编辑页与列表都用它，措辞保持一致。
  String get keyLabel {
    if (apiKeyHint != null && apiKeyHint!.isNotEmpty) {
      return apiKeySource == 'env' ? '环境变量 $apiKeyHint' : '已配置 $apiKeyHint';
    }
    return '未配置密钥';
  }
}

/// 模型配置列表（`GET /api/models`）。
class ModelListView {
  const ModelListView({
    required this.activeId,
    required this.persisted,
    required this.models,
  });

  factory ModelListView.fromJson(Map<String, dynamic> json) {
    return ModelListView(
      activeId: json['active_id'] as String? ?? '',
      persisted: json['persisted'] as bool? ?? false,
      models: (json['models'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(ModelProfileView.fromJson)
          .toList(growable: false),
    );
  }

  final String activeId;

  /// false 表示服务端没有来源配置文件：改动重启后会丢，界面要提示。
  final bool persisted;
  final List<ModelProfileView> models;

  static const ModelListView empty = ModelListView(
    activeId: '',
    persisted: true,
    models: <ModelProfileView>[],
  );

  /// 当前生效项；列表为空时返回 null。
  ModelProfileView? get active {
    for (final model in models) {
      if (model.active) {
        return model;
      }
    }
    return models.isEmpty ? null : models.first;
  }
}

/// 「测试连接」的结果（`POST /api/models/test`）。
///
/// 失败也走 200：连通性失败是结论而不是请求错误，所以这里用 `ok` 区分，
/// 不必让调用方去 catch 异常。
class ModelTestResult {
  const ModelTestResult({
    required this.ok,
    this.latencyMs,
    this.endpoint,
    this.errorCode,
    this.status,
    this.message,
    this.hint,
  });

  factory ModelTestResult.fromJson(Map<String, dynamic> json) {
    return ModelTestResult(
      ok: json['ok'] as bool? ?? false,
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      endpoint: json['endpoint'] as String?,
      errorCode: json['error_code'] as String?,
      status: (json['status'] as num?)?.toInt(),
      message: json['message'] as String?,
      hint: json['hint'] as String?,
    );
  }

  final bool ok;
  final int? latencyMs;
  final String? endpoint;
  final String? errorCode;
  final int? status;
  final String? message;
  final String? hint;

  /// 给用户看的一句话。优先 `hint`：`message` 是上游原话，面向开发。
  String get userText {
    if (ok) {
      final latency = latencyMs;
      return latency == null ? '连接正常' : '连接正常，往返 $latency ms';
    }
    final hint = this.hint;
    if (hint != null && hint.isNotEmpty) {
      return hint;
    }
    final message = this.message;
    if (message != null && message.isNotEmpty) {
      return message;
    }
    return '连接失败';
  }
}
