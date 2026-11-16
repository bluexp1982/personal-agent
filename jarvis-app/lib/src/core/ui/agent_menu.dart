/// 菜单组件的统一入口。
///
/// 实现在 `menu/` 下：模型与令牌（`menu_model.dart`）、行与触发器
/// （`menu_parts.dart`）、触发器型浮层（`agent_menu.dart`）、
/// 无触发器面板（`menu_panel.dart`）。
/// 这里只做转发，让各处 `import '../../core/ui/agent_menu.dart'` 的写法保持不变，
/// 同时避免把几个关注点挤进一个近千行的文件里。
library;

export 'menu/agent_menu.dart';
export 'menu/menu_model.dart';
export 'menu/menu_panel.dart';
export 'menu/menu_parts.dart';
