/// 右栏 Git 面板的载荷模型。
///
/// 与 `models.dart` 分开：那边已经 1700+ 行且服务于会话/任务/项目，
/// git 这组类型只有 Git 面板用，混进去只会让"改一处先翻两千行"更难受。
///
/// 字段与 `api-spec/openapi.yaml` 的 `Git*` schema 一一对应；路径一律是
/// **仓库内相对路径**，不是服务端绝对路径。
library;

/// 一个文件在某一侧（暂存区 / 工作区）的状态。
enum GitFileState {
  modified('modified', 'M'),
  added('added', 'A'),
  deleted('deleted', 'D'),
  renamed('renamed', 'R'),
  copied('copied', 'C'),
  typeChanged('type_changed', 'T'),
  unmerged('unmerged', 'U'),
  untracked('untracked', '?');

  const GitFileState(this.wire, this.badge);

  /// 协议里的取值。
  final String wire;

  /// 行内徽标上的单字母，与 `git status` 的记法一致。
  final String badge;

  /// 未知取值退化成"已修改"：新增状态总比整页解析失败好。
  static GitFileState parse(Object? raw) {
    final value = raw is String ? raw : '';
    for (final state in values) {
      if (state.wire == value) {
        return state;
      }
    }
    return GitFileState.modified;
  }
}

/// 仓库正处于的多步操作中间态。
enum GitOperation {
  merge('merge', 'merge'),
  rebase('rebase', 'rebase'),
  cherryPick('cherry_pick', 'cherry-pick'),
  revert('revert', 'revert');

  const GitOperation(this.wire, this.label);

  final String wire;

  /// 拼进提示语里的名字。
  final String label;

  static GitOperation? parse(Object? raw) {
    final value = raw is String ? raw : '';
    for (final operation in values) {
      if (operation.wire == value) {
        return operation;
      }
    }
    return null;
  }
}

/// 变更列表里的一项。
class GitFileChange {
  const GitFileChange({required this.path, required this.state, this.origPath});

  factory GitFileChange.fromJson(Map<String, dynamic> json) {
    return GitFileChange(
      path: json['path'] as String? ?? '',
      state: GitFileState.parse(json['state']),
      origPath: json['orig_path'] as String?,
    );
  }

  /// 仓库内相对路径；重命名时是新路径。
  final String path;

  final GitFileState state;

  /// 重命名 / 复制的源路径。
  final String? origPath;

  /// 文件名（路径最后一段）：列表主行显示它，目录做副标题。
  String get name {
    final slash = path.lastIndexOf('/');
    return slash >= 0 && slash + 1 < path.length
        ? path.substring(slash + 1)
        : path;
  }

  /// 所在目录；根目录下的文件为空串。
  String get directory {
    final slash = path.lastIndexOf('/');
    return slash > 0 ? path.substring(0, slash) : '';
  }
}

/// 一条提交的概要。
class GitCommitSummary {
  const GitCommitSummary({
    required this.hash,
    required this.shortHash,
    required this.subject,
    required this.author,
    required this.timeMs,
  });

  factory GitCommitSummary.fromJson(Map<String, dynamic> json) {
    return GitCommitSummary(
      hash: json['hash'] as String? ?? '',
      shortHash: json['short_hash'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      author: json['author'] as String? ?? '',
      timeMs: (json['time_ms'] as num?)?.toInt() ?? 0,
    );
  }

  final String hash;
  final String shortHash;
  final String subject;
  final String author;

  /// 作者时间，Unix 毫秒。
  final int timeMs;
}

/// 仓库当前状态。
///
/// `repo = false` 是正常返回：普通项目目录、属于别的仓库的子目录都走这里，
/// 面板据此画「不是 Git 仓库」的空态，而不是把状态请求当失败处理。
class GitStatusReport {
  const GitStatusReport({
    required this.repo,
    required this.detached,
    this.branch,
    this.head,
    this.operation,
    this.reason,
    this.staged = const <GitFileChange>[],
    this.unstaged = const <GitFileChange>[],
    this.untracked = const <GitFileChange>[],
  });

  factory GitStatusReport.fromJson(Map<String, dynamic> json) {
    List<GitFileChange> group(String key) {
      final raw = json[key];
      if (raw is! List) {
        return const <GitFileChange>[];
      }
      return raw
          .whereType<Map<String, dynamic>>()
          .map(GitFileChange.fromJson)
          .toList(growable: false);
    }

    final head = json['head'];
    return GitStatusReport(
      repo: json['repo'] as bool? ?? false,
      detached: json['detached'] as bool? ?? false,
      branch: json['branch'] as String?,
      head: head is Map<String, dynamic>
          ? GitCommitSummary.fromJson(head)
          : null,
      operation: GitOperation.parse(json['operation']),
      reason: json['reason'] as String?,
      staged: group('staged'),
      unstaged: group('unstaged'),
      untracked: group('untracked'),
    );
  }

  /// 「不是仓库」的占位报告。
  ///
  /// 与 Rust 侧 `GitStatusReport::not_a_repo` 对齐：这是**状态**不是错误，
  /// 面板据此画空态，而不是弹红色报错。
  factory GitStatusReport.notARepo(String reason) =>
      GitStatusReport(repo: false, detached: false, reason: reason);

  final bool repo;
  final bool detached;

  /// 当前分支名；游离 HEAD 或还没有提交时为空。
  final String? branch;

  final GitCommitSummary? head;

  /// 进行中的 merge / rebase 等；正常状态为 null。
  final GitOperation? operation;

  /// `repo = false` 时的原因。
  final String? reason;

  final List<GitFileChange> staged;
  final List<GitFileChange> unstaged;
  final List<GitFileChange> untracked;

  /// 三组变更合计条数。
  int get changeCount => staged.length + unstaged.length + untracked.length;

  /// 工作区干净：有仓库、没有变更、也没有中间态。
  bool get isClean => repo && changeCount == 0 && operation == null;

  /// 分支栏上显示的名字。
  String get branchLabel {
    if (detached) {
      return '游离 HEAD';
    }
    final name = branch;
    return name == null || name.isEmpty ? '未知分支' : name;
  }

  /// 现在能不能提交；不能时给出原因（提交区据此禁用并说明）。
  String? get commitBlockedReason {
    if (!repo) {
      return '当前目录不是 Git 仓库';
    }
    if (operation != null) {
      return '仓库正在 ${operation!.label}，请在终端完成后再提交';
    }
    if (staged.isEmpty) {
      return '没有已暂存的内容';
    }
    return null;
  }
}

/// 单个文件或某次提交的 diff。
class GitDiffReport {
  const GitDiffReport({
    required this.text,
    this.path,
    this.staged = false,
    this.commit,
    this.truncated = false,
    this.binary = false,
    this.additions = 0,
    this.deletions = 0,
  });

  factory GitDiffReport.fromJson(Map<String, dynamic> json) {
    return GitDiffReport(
      text: json['text'] as String? ?? '',
      path: json['path'] as String?,
      staged: json['staged'] as bool? ?? false,
      commit: json['commit'] as String?,
      truncated: json['truncated'] as bool? ?? false,
      binary: json['binary'] as bool? ?? false,
      additions: (json['additions'] as num?)?.toInt() ?? 0,
      deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    );
  }

  final String text;
  final String? path;
  final bool staged;
  final String? commit;

  /// 文本因超过 512 KiB 被截断。
  final bool truncated;

  /// 二进制文件：`text` 为空。
  final bool binary;

  final int additions;
  final int deletions;
}

/// 提交结果：新提交 + 提交后的状态。
class GitCommitResult {
  const GitCommitResult({required this.commit, required this.status});

  factory GitCommitResult.fromJson(Map<String, dynamic> json) {
    final commit = json['commit'];
    final status = json['status'];
    return GitCommitResult(
      commit: GitCommitSummary.fromJson(
        commit is Map<String, dynamic> ? commit : const <String, dynamic>{},
      ),
      status: GitStatusReport.fromJson(
        status is Map<String, dynamic> ? status : const <String, dynamic>{},
      ),
    );
  }

  final GitCommitSummary commit;
  final GitStatusReport status;
}

/// 提交历史的一页。
class GitCommitsPage {
  const GitCommitsPage({
    this.commits = const <GitCommitSummary>[],
    this.hasMore = false,
  });

  factory GitCommitsPage.fromJson(Map<String, dynamic> json) {
    final raw = json['commits'];
    return GitCommitsPage(
      commits: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(GitCommitSummary.fromJson)
                .toList(growable: false)
          : const <GitCommitSummary>[],
      hasMore: json['has_more'] as bool? ?? false,
    );
  }

  final List<GitCommitSummary> commits;

  /// 还有更早的提交。
  final bool hasMore;
}
