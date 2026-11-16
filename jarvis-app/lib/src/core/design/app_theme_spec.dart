import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 一个已安装主题包的客户端视图。
///
/// 与 `protocol::ThemeSpec` 一一对应，但**颜色是稀疏覆盖**：`colors` 里只出现
/// 包声明改过的格子，其余由 [AppPalette] 从内置值派生。这样设计层仍是色表的
/// 唯一真源——主题包加一个格子，服务端与协议都不用跟着改。
///
/// 值相等（含 `colors`）是刻意实现的：列表刷新但内容没变时 `MaterialApp`
/// 不会因为拿到"新对象"而重建整棵树。
@immutable
class AppThemeSpec {
  const AppThemeSpec({
    required this.id,
    required this.name,
    required this.version,
    required this.brightness,
    this.author = '',
    this.description = '',
    this.colors = AppThemeColors.empty,
    this.installedAt = 0,
    this.updatedAt = 0,
  });

  /// 从服务端或本地缓存的 JSON 解析。
  ///
  /// 脏值一律降级而不是抛异常：缓存可能是老版本写的，一个坏的色值不该让
  /// 应用起不来——宁可少覆盖一格。
  factory AppThemeSpec.fromJson(Map<String, dynamic> json) {
    return AppThemeSpec(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      brightness: json['brightness'] == 'dark'
          ? Brightness.dark
          : Brightness.light,
      colors: AppThemeColors.fromJson(
        (json['colors'] as Map<dynamic, dynamic>?)
                ?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      installedAt: (json['installed_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;

  /// 明暗基线。包只声明一种，选中后不再跟随系统。
  final Brightness brightness;

  /// 稀疏颜色覆盖。
  final AppThemeColors colors;

  final int installedAt;
  final int updatedAt;

  bool get isUsable => id.isNotEmpty;

  /// 序列化给本地缓存用。键与线缆一致（`snake_case`），缓存与服务端能共用解析。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'version': version,
    if (author.isNotEmpty) 'author': author,
    if (description.isNotEmpty) 'description': description,
    'brightness': brightness == Brightness.dark ? 'dark' : 'light',
    'colors': colors.toJson(),
    'installed_at': installedAt,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is AppThemeSpec &&
      other.id == id &&
      other.name == name &&
      other.version == version &&
      other.author == author &&
      other.description == description &&
      other.brightness == brightness &&
      other.colors == colors &&
      other.installedAt == installedAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    version,
    author,
    description,
    brightness,
    colors,
    installedAt,
    updatedAt,
  );

  @override
  String toString() => 'AppThemeSpec($id, $name, v$version)';
}

/// 主题包的颜色覆盖表。
///
/// 用「`分组.字段` → 颜色」的扁平表，而不是 50 多个具名列：
/// - 打包格式与协议一一对应，加一格只需要两端各加一个键；
/// - `AppPalette.overrideWith` 只读自己认识的键，未知键自然被忽略，
///   老客户端遇到新字段不会崩。
///
/// 键的口径与线上 JSON 完全一致（`snake_case`）：`seed`、`text.tertiary`、
/// `status.success`、`syntax.keyword`、`message.user_bubble`、`terminal.bright_green`。
@immutable
class AppThemeColors {
  const AppThemeColors([this.values = const <String, Color>{}]);

  static const AppThemeColors empty = AppThemeColors();

  final Map<String, Color> values;

  bool get isEmpty => values.isEmpty;

  bool get isNotEmpty => values.isNotEmpty;

  Color? operator [](String key) => values[key];

  /// 有哪些分组出现在包里（`scheme` / `text` / `status` / `terminal` …）。
  Iterable<String> get groups =>
      values.keys.map((key) => key.split('.').first).toSet();

  /// 包里的种子色：参与 `ColorScheme.fromSeed`，其余色阶由它派生。
  Color? get seed => values['seed'];

  factory AppThemeColors.fromJson(Map<String, dynamic> json) {
    final values = <String, Color>{};

    final seed = tryParseHex(json['seed']);
    if (seed != null) {
      values['seed'] = seed;
    }

    for (final group in _groupNames) {
      final raw = json[group];
      if (raw is! Map) {
        continue;
      }
      raw.forEach((key, value) {
        if (key is! String) {
          return;
        }
        final color = tryParseHex(value);
        if (color != null) {
          values['$group.$key'] = color;
        }
      });
    }

    return AppThemeColors(Map<String, Color>.unmodifiable(values));
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    values.forEach((key, color) {
      final parts = key.split('.');
      if (parts.length == 1) {
        out[parts[0]] = _toHex(color);
        return;
      }
      final group = (out[parts[0]] as Map<String, dynamic>?) ??
          <String, dynamic>{};
      group[parts[1]] = _toHex(color);
      out[parts[0]] = group;
    });
    return out;
  }

  static const List<String> _groupNames = <String>[
    // 界面骨架色：直接落到 M3 `ColorScheme`（见 `buildAppTheme`）。
    // 其余分组说的是"画什么"，这一组说的是"底和线"。
    'scheme',
    'text',
    'status',
    'syntax',
    'message',
    'terminal',
    // 项目 / SSH 强调色、页面顶部渐变色调。
    // 内置浅色 / 深色也用同样这九组键，写在 `app_builtin_themes.dart`。
    // 这两组过去是写死的品牌色，现在也能被主题包覆盖。
    'accent',
    'surface',
  ];

  /// 解析 `#RRGGBB` / `#AARRGGBB`（`#` 可省）。脏值返回 null 由调用方跳过。
  static Color? tryParseHex(Object? raw) {
    if (raw is! String) {
      return null;
    }
    var text = raw.trim();
    if (text.startsWith('#')) {
      text = text.substring(1);
    }
    if (text.length != 6 && text.length != 8) {
      return null;
    }
    final value = int.tryParse(text, radix: 16);
    if (value == null) {
      return null;
    }
    return Color(text.length == 6 ? 0xFF000000 | value : value);
  }

  static String _toHex(Color color) {
    final value = color.toARGB32();
    final alpha = (value >> 24) & 0xFF;
    if (alpha == 0xFF) {
      return '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  @override
  bool operator ==(Object other) =>
      other is AppThemeColors && mapEquals(other.values, values);

  @override
  int get hashCode => Object.hashAllUnordered(
    values.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );

  @override
  String toString() => 'AppThemeColors(${values.length} overrides)';
}
