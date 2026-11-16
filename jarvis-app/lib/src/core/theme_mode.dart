import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme_spec.dart';
import 'session.dart';

/// 主题偏好的存储键。
///
/// 与 `ui_project_mode` 同一命名空间：都是"上次看到哪儿/选了什么"的界面偏好，
/// 丢了只影响观感，不影响配对与鉴权。
///
/// 三个键分工：
/// - `ui_theme_mode`：`system` / `light` / `dark` / `custom`。沿用旧键，
///   老版本写的 `light|dark|system` 原样可用，不需要迁移。
/// - `ui_theme_id`：选中主题包的 id（仅 `custom` 时有意义）。
/// - `ui_theme_spec`：该主题包的完整 JSON 缓存。首帧不闪白与"服务端不可达
///   也能着色"都靠它；列表到达后以服务端为准。
const String kThemeModeKey = 'ui_theme_mode';
const String kThemeIdKey = 'ui_theme_id';
const String kThemeSpecKey = 'ui_theme_spec';

/// 把存储里的字符串还原成 `ThemeMode`。
///
/// 只认三个明确取值，其余（null、空串、带空格的脏值、老版本写坏的内容）一律返回
/// null 交给调用方回落"跟随系统"：静默猜一个相近值会让用户觉得"主题自己变了"。
ThemeMode? themeModeFromName(String? raw) => switch (raw) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  'system' => ThemeMode.system,
  _ => null,
};

/// 落盘用的字符串。与 [themeModeFromName] 一一对应，改动必须同步。
String themeModeName(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

/// 设置页的四档选择。
///
/// 前三档是内置主题（跟随系统 / 浅色 / 深色），第四档是"个性主题"：
/// 用户装的包，自带一种明暗，选中后不再跟随系统。
enum ThemeChoice { system, light, dark, custom }

/// 解析存储值。未知值返回 null，调用方回落 [ThemeChoice.system]。
ThemeChoice? themeChoiceFromName(String? raw) => switch (raw) {
  'system' => ThemeChoice.system,
  'light' => ThemeChoice.light,
  'dark' => ThemeChoice.dark,
  'custom' => ThemeChoice.custom,
  _ => null,
};

String themeChoiceName(ThemeChoice choice) => switch (choice) {
  ThemeChoice.system => 'system',
  ThemeChoice.light => 'light',
  ThemeChoice.dark => 'dark',
  ThemeChoice.custom => 'custom',
};

/// 当前主题选择。
///
/// `spec` 是"上次着色用的那份主题包"（本地缓存）。它让首帧就能用对颜色，
/// 不必等服务端列表回来；列表到达后由 `activeThemeSpecProvider` 用服务端
/// 版本覆盖（重装同名主题后色值可能已变）。
@immutable
class ThemeSelection {
  const ThemeSelection({this.choice = ThemeChoice.system, this.themeId, this.spec});

  /// 默认值：升级前客户端的行为，老用户不动设置就不会有观感变化。
  static const ThemeSelection system = ThemeSelection();

  final ThemeChoice choice;

  /// 仅 [ThemeChoice.custom] 时有意义。
  final String? themeId;

  /// 仅 [ThemeChoice.custom] 时有意义：上次用于着色的主题包快照。
  final AppThemeSpec? spec;

  bool get isCustom => choice == ThemeChoice.custom;

  /// 交给 `MaterialApp.themeMode` 的值。
  ///
  /// 个性主题固定返回 `light`：此时 `theme` 与 `darkTheme` 都被传成
  /// 主题包自己那一套，明暗已经由包决定，不应再让系统外观参与。
  ThemeMode get materialMode => switch (choice) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.dark => ThemeMode.dark,
    ThemeChoice.custom => ThemeMode.light,
  };

  ThemeSelection copyWith({
    ThemeChoice? choice,
    String? themeId,
    AppThemeSpec? spec,
    bool clearTheme = false,
  }) {
    if (clearTheme) {
      return ThemeSelection(choice: choice ?? this.choice);
    }
    return ThemeSelection(
      choice: choice ?? this.choice,
      themeId: themeId ?? this.themeId,
      spec: spec ?? this.spec,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeSelection &&
      other.choice == choice &&
      other.themeId == themeId &&
      other.spec == spec;

  @override
  int get hashCode => Object.hash(choice, themeId, spec);
}

/// 界面主题偏好：内置三档 + 个性主题。
final NotifierProvider<ThemeSelectionController, ThemeSelection>
themeSelectionProvider =
    NotifierProvider<ThemeSelectionController, ThemeSelection>(
      ThemeSelectionController.new,
    );

class ThemeSelectionController extends Notifier<ThemeSelection> {
  @override
  ThemeSelection build() {
    unawaited(restore());
    return ThemeSelection.system;
  }

  /// 从本地存储恢复上次的选择。
  ///
  /// 公开而不是藏在 build 里：测试要能确定性地"等恢复完成再断言"，
  /// 生产路径仍然是 build 里 `unawaited` 一次，不阻塞首帧。
  Future<void> restore() async {
    try {
      final store = ref.read(secretStoreProvider);
      final choice =
          themeChoiceFromName(await store.read(kThemeModeKey)) ??
          ThemeChoice.system;

      if (choice != ThemeChoice.custom) {
        if (state != ThemeSelection(choice: choice)) {
          state = ThemeSelection(choice: choice);
        }
        return;
      }

      final id = await store.read(kThemeIdKey);
      final spec = await _readCachedSpec(await store.read(kThemeSpecKey));
      if (id == null || id.isEmpty || spec == null || spec.id != id) {
        // 缓存丢了或对不上：回落到跟随系统，而不是留一个"个性主题"标签
        // 却没有任何颜色可用。
        state = ThemeSelection.system;
        return;
      }
      state = ThemeSelection(
        choice: ThemeChoice.custom,
        themeId: id,
        spec: spec,
      );
    } on Exception {
      // 读不出来就用默认值：钥匙串/回退目录在测试与 headless 环境里都不可用，
      // 这里不能让它冒成未捕获异常，更不该因此卡住启动。
    }
  }

  /// 切换主题档位。切换立即生效，落盘失败不回滚——
  /// 失败只意味着"下次启动记不住"，当前这次选择用户已经看到了。
  ///
  /// 允许切到 [ThemeChoice.custom] 但手上还没有包：设置页要能在空态里引导
  /// 用户去安装，而不是点了没反应。此时保留上一次的包，颜色由
  /// `activeThemeSpecProvider` 决定（没有包就回落到内置主题）。
  Future<void> selectMode(ThemeChoice choice) async {
    if (choice == ThemeChoice.custom) {
      state = ThemeSelection(
        choice: choice,
        themeId: state.themeId,
        spec: state.spec,
      );
      await _persist(choice: choice, spec: state.spec);
      return;
    }

    state = ThemeSelection(choice: choice);
    await _persist(choice: choice);
  }

  /// 选中一个主题包（进入个性主题）。
  Future<void> selectTheme(AppThemeSpec spec) async {
    state = ThemeSelection(
      choice: ThemeChoice.custom,
      themeId: spec.id,
      spec: spec,
    );
    await _persist(choice: ThemeChoice.custom, spec: spec);
  }

  /// 主题包被删除、或服务端说它不存在：平滑回落到跟随系统。
  Future<void> clearCustom() async {
    state = ThemeSelection.system;
    await _persist(choice: ThemeChoice.system, forgetTheme: true);
  }

  Future<void> _persist({
    required ThemeChoice choice,
    AppThemeSpec? spec,
    bool forgetTheme = false,
  }) async {
    try {
      final store = ref.read(secretStoreProvider);
      await store.write(kThemeModeKey, themeChoiceName(choice));
      if (spec != null) {
        await store.write(kThemeIdKey, spec.id);
        await store.write(kThemeSpecKey, jsonEncode(spec.toJson()));
      } else if (forgetTheme) {
        await store.delete(kThemeIdKey);
        await store.delete(kThemeSpecKey);
      }
    } on Exception {
      // 同上：偏好落盘失败不该冒泡到 UI。
    }
  }

  Future<AppThemeSpec?> _readCachedSpec(String? raw) async {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        return null;
      }
      final spec = AppThemeSpec.fromJson(json);
      return spec.isUsable ? spec : null;
    } on FormatException {
      return null;
    }
  }
}
