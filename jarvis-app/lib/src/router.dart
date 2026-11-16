import 'package:go_router/go_router.dart';

import 'features/shell/root_gate.dart';

/// 路由只有一个入口：由 [RootGate] 按会话状态决定显示配对页还是主界面。
///
/// 详情页（会话、任务）用 `Navigator.push` 打开——它们是主界面的下一层，
/// 不需要独立深链；等 v1.1 接入通知跳转时再补命名路由。
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      name: 'root',
      builder: (context, state) => const RootGate(),
    ),
  ],
);
