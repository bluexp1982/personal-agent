import 'package:flutter/material.dart';

import 'entity_page.dart';
import 'grants_page.dart';
import 'memory_candidates_page.dart';
import 'memory_detail_page.dart';
import 'memory_export_page.dart';
import 'memory_page.dart';

/// 记忆列表（整页）。
///
/// 项目约定：详情类页面一律 `Navigator.push`，命名路由留给通知跳转，
/// 一期不引入深链（见 `router.dart` 的注释）。
Future<void> openMemoryPage(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const MemoryListPage()));
}

/// 一条记忆的详情。来源卡片点击、时间线跳转都走这里。
Future<void> openMemoryDetail(BuildContext context, String memoryId) {
  if (memoryId.isEmpty) {
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => MemoryDetailPage(memoryId: memoryId)),
  );
}



/// 候选确认页。
Future<void> openMemoryCandidates(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const MemoryCandidatesPage()));
}

/// 实体页。记忆详情里的主体名、时间线都用它。
Future<void> openEntityPage(BuildContext context, String entityId) {
  if (entityId.isEmpty) {
    return Future<void>.value();
  }
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => EntityDetailPage(entityId: entityId)));
}

/// 项目记忆导出页。
Future<void> openMemoryExport(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const MemoryExportPage()));
}

/// 执行授权列表。
Future<void> openGrantsPage(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const GrantsPage()));
}
