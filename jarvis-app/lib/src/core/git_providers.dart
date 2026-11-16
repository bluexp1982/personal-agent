import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'api_error.dart';
import 'git_models.dart';
import 'session.dart';

/// 一次 diff 查询的键。
///
/// `commit` 有值看某次提交（`path` 可为空即整次提交），否则看工作区或暂存区。
typedef GitDiffKey = ({
  String projectId,
  String path,
  bool staged,
  String? commit,
});

/// 历史分页的键。
typedef GitLogKey = ({String projectId, int limit});

/// 仓库状态。面板一打开就 watch，动作成功后由 [GitActions] 失效重取。
final gitStatusProvider = FutureProvider.autoDispose
    .family<GitStatusReport, String>((ref, projectId) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final json = await client.getJson(_gitPath(projectId, 'status'));
      return GitStatusReport.fromJson(json);
    }, retry: _noRetry);

/// 单文件 / 单次提交的 diff。
///
/// 按文件懒加载：面板里选中哪个才请求哪个，绝不一次拉全仓 diff。
final gitDiffProvider = FutureProvider.autoDispose
    .family<GitDiffReport, GitDiffKey>((ref, key) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final json = await client.getJson(
        _gitPath(key.projectId, 'diff'),
        query: <String, String>{
          if (key.path.isNotEmpty) 'path': key.path,
          if (key.staged) 'staged': 'true',
          if (key.commit != null && key.commit!.isNotEmpty)
            'commit': key.commit!,
        },
      );
      return GitDiffReport.fromJson(json);
    }, retry: _noRetry);

/// 提交历史（新到旧）。
final gitLogProvider = FutureProvider.autoDispose
    .family<GitCommitsPage, GitLogKey>((ref, key) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw _noClient();
      }
      final json = await client.getJson(
        _gitPath(key.projectId, 'commits'),
        query: <String, String>{'limit': '${key.limit}'},
      );
      return GitCommitsPage.fromJson(json);
    }, retry: _noRetry);

/// 写操作（暂存 / 取消暂存 / 撤销 / 提交）。
///
/// 单独一个对象而不是塞进 provider：这几件事都是"点一下、等结果、完事"，
/// 没有需要跨页面共享的状态。它们做完必须让读 provider 失效，
/// 否则面板会继续显示提交前那份变更列表——而用户刚提交完，最不能接受的就是这个。
///
/// 服务端在写响应里已经带回了最新状态，这里仍然失效重取：提交还要顺手刷历史，
/// 撤销还要刷当前打开的 diff，与其为每种动作各写一套"该失效谁"的分支，
/// 不如统一失效——代价是本地多三次 git 只读命令，量级是几十毫秒。
class GitActions {
  GitActions(this._ref);

  final Ref _ref;

  Future<GitStatusReport> stage(String projectId, List<String> paths) =>
      _paths(projectId, 'stage', paths);

  Future<GitStatusReport> unstage(String projectId, List<String> paths) =>
      _paths(projectId, 'unstage', paths);

  /// 撤销已跟踪文件的改动。不可恢复，调用方必须先二次确认。
  Future<GitStatusReport> discard(String projectId, List<String> paths) =>
      _paths(projectId, 'discard', paths);

  Future<GitCommitResult> commit(String projectId, String message) async {
    final client = _client();
    final json = await client.postJson(
      _gitPath(projectId, 'commit'),
      <String, dynamic>{'message': message},
    );
    final result = GitCommitResult.fromJson(json);
    _invalidate(projectId, includeLog: true);
    return result;
  }

  Future<GitStatusReport> _paths(
    String projectId,
    String action,
    List<String> paths,
  ) async {
    final client = _client();
    final json = await client.postJson(
      _gitPath(projectId, action),
      <String, dynamic>{'paths': paths},
    );
    final report = GitStatusReport.fromJson(json);
    _invalidate(projectId, includeLog: false);
    return report;
  }

  void _invalidate(String projectId, {required bool includeLog}) {
    _ref.invalidate(gitStatusProvider(projectId));
    // 家族整体失效：工作区变了，任何一份缓存的 diff 都不能再信。
    _ref.invalidate(gitDiffProvider);
    if (includeLog) {
      _ref.invalidate(gitLogProvider);
    }
  }

  ApiClient _client() {
    final client = _ref.read(apiClientProvider);
    if (client == null) {
      throw _noClient();
    }
    return client;
  }
}

/// 挂在根作用域上：面板开关、切项目都不该把"动作入口"一起销毁，
/// 否则正在等结果的那一次请求会拿到一个已经失效的 Ref。
final gitActionsProvider = Provider<GitActions>((ref) => GitActions(ref));

String _gitPath(String projectId, String action) =>
    '/api/projects/${Uri.encodeComponent(projectId)}/git/$action';

/// Git 的失败是确定性的（路径越界、中间态、没有暂存内容），自动重试只会
/// 让面板停在转圈上；保留手动刷新按钮，由用户决定何时再试。
Duration? _noRetry(int retryCount, Object error) => null;

ApiException _noClient() {
  return const ApiException(
    code: 'unauthenticated',
    message: 'no client',
    retryable: false,
    hint: '尚未登录，请重新配对',
  );
}
