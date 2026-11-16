import 'package:flutter/material.dart';

/// 项目的语义身份：图标与动作文案。
///
/// 颜色**不在这里**：项目强调色（`accent.project_start/end`）与 SSH 强调色
/// 都是主题包可覆盖的格子，一律走 `AppPalette.of(context).accent`——
/// 留一份静态常量，就会出现"主题换成绿色、卡片还是暖橙"的半截生效。
/// 内置两套的取值（蓝）写在 `app_builtin_themes.dart`。
class ProjectStyle {
  const ProjectStyle._();

  /// 项目图标。列表、空态、悬浮按钮共用，避免同一个概念换一处换一个图形。
  static const IconData icon = Icons.folder_outlined;

  /// 新建项目的按钮文案。
  static const String actionLabel = '新建项目';
}
