import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_error.dart';
import 'models.dart';
import 'session.dart';

/// 全部项目，按服务端给出的更新时间倒序。
///
/// 界面不再区分 CODE / WORK，所以不带 `mode` 参数、也不再按模式分桶缓存：
/// 一次请求就是用户要看的整份列表。
final projectsProvider = FutureProvider<List<Project>>((ref) async {
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return const <Project>[];
  }
  final items = await client.getJsonArray('/api/projects');
  return items.map(Project.fromJson).toList(growable: false);
});

/// 单个项目。详情页在重命名后用它刷新头部。
final projectProvider = FutureProvider.family<Project?, String>((
  ref,
  id,
) async {
  final client = ref.watch(apiClientProvider);
  if (client == null || id.isEmpty) {
    return null;
  }
  final json = await client.getJson('/api/projects/$id');
  return Project.fromJson(json);
});

/// 目录浏览。键是「模式 + 路径」，`path` 为空表示从服务端允许的第一个根开始。
final dirListingProvider =
    FutureProvider.family<DirListing, ({String mode, String? path})>((
      ref,
      key,
    ) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        return const DirListing(path: '', roots: <String>[]);
      }
      final json = await client.getJson(
        '/api/fs/dirs',
        query: <String, String>{
          'mode': key.mode,
          if (key.path != null && key.path!.isNotEmpty) 'path': key.path!,
        },
      );
      return DirListing.fromJson(json);
    });

/// 建项目前的预检。键是「模式 + 路径」：换目录就重新问一次服务端。
///
/// 只在 Git 项目用得上（普通项目与 git 无关，服务端也会直接回 `not_applicable`）。
final projectPreflightProvider =
    FutureProvider.family<ProjectPreflight, ({String mode, String path})>((
      ref,
      key,
    ) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        throw const ApiException(
          code: 'unauthenticated',
          message: 'no client',
          retryable: false,
          hint: '尚未登录，请重新配对',
        );
      }
      final json = await client.getJson(
        '/api/projects/preflight',
        query: <String, String>{'mode': key.mode, 'path': key.path},
      );
      return ProjectPreflight.fromJson(json);
    });

/// 项目列表与详情一起刷新：改名 / 删除会影响两个视图。
void invalidateProjects(Ref ref) {
  ref.invalidate(projectsProvider);
  ref.invalidate(projectProvider);
}
