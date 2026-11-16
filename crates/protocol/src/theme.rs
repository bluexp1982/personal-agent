//! 主题包（个性化主题）的对外类型。
//!
//! 与 `api-spec/openapi.yaml` 的 `ThemeSpec` / `ThemePage` 对应。只放数据结构，
//! 不含安装逻辑——那是 `jarvis-service` 的事。
//!
//! 设计口径：**主题包只声明覆盖项**。每个颜色字段都可以缺省，缺省即表示
//! "沿用内置浅色/深色的派生值"。这样 Flutter 侧的色表仍是唯一真源，
//! 服务端不需要复制一份 40 个色值，也不会出现两套色表各自漂移。

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// 主题明暗基线。一个包只声明一种：选中个性主题后不再跟随系统。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThemeBrightness {
    Light,
    Dark,
}

impl ThemeBrightness {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

/// 线缆上的颜色：`#RRGGBB` 或不透明时省略的 `#AARRGGBB`（`#` 可省）。
///
/// 用 newtype 而不是 `String`：格式校验只在反序列化时做一次，下游拿到的
/// 一定是合法值。内部统一存 `0xAARRGGBB`，与 Flutter 的 `Color.value` 对齐。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ThemeColor(pub u32);

impl ThemeColor {
    pub const fn from_argb(value: u32) -> Self {
        Self(value)
    }

    pub const fn argb(self) -> u32 {
        self.0
    }

    /// 解析 `#RRGGBB` / `#AARRGGBB`（`#` 可省，大小写不敏感）。
    ///
    /// 返回的错误是给包作者看的一句话，会被包进 `theme_invalid` 的 message。
    pub fn parse(raw: &str) -> Result<Self, String> {
        let text = raw.trim();
        let digits = text.strip_prefix('#').unwrap_or(text);
        if digits.len() != 6 && digits.len() != 8 {
            return Err(format!("颜色 {text} 不是 #RRGGBB 或 #AARRGGBB"));
        }
        if !digits.chars().all(|ch| ch.is_ascii_hexdigit()) {
            return Err(format!("颜色 {text} 含非十六进制字符"));
        }
        let value = u32::from_str_radix(digits, 16).map_err(|_| format!("颜色 {text} 无法解析"))?;
        Ok(Self(if digits.len() == 6 {
            0xFF00_0000 | value
        } else {
            value
        }))
    }

    /// 输出 `#RRGGBB`（不透明）或 `#AARRGGBB`（带透明度）。
    pub fn to_hex(self) -> String {
        if self.0 >> 24 == 0xFF {
            format!("#{:06X}", self.0 & 0x00FF_FFFF)
        } else {
            format!("#{:08X}", self.0)
        }
    }
}

impl Serialize for ThemeColor {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for ThemeColor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw).map_err(serde::de::Error::custom)
    }
}

/// 文字灰阶覆盖。字段含义与 Flutter 侧 `AppTextColors` 一一对应。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeTextColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secondary: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tertiary: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_accent: Option<ThemeColor>,
}

impl ThemeTextColors {
    fn is_empty(&self) -> bool {
        self.primary.is_none()
            && self.secondary.is_none()
            && self.tertiary.is_none()
            && self.control.is_none()
            && self.disabled.is_none()
            && self.on_accent.is_none()
    }
}

/// 状态五色覆盖。胶囊的 12% 底与 35% 描边由客户端从同一个颜色派生。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeStatusColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub success: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warning: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub danger: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub info: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub neutral: Option<ThemeColor>,
}

impl ThemeStatusColors {
    fn is_empty(&self) -> bool {
        self.success.is_none()
            && self.warning.is_none()
            && self.danger.is_none()
            && self.info.is_none()
            && self.neutral.is_none()
    }
}

/// 语法高亮覆盖。十一类，与 Flutter 侧 `AppSyntaxColors` 一一对应。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeSyntaxColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyword: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub string: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub function: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub r#type: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub property: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "operator")]
    pub operator_: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invalid: Option<ThemeColor>,
}

impl ThemeSyntaxColors {
    fn is_empty(&self) -> bool {
        self.keyword.is_none()
            && self.string.is_none()
            && self.number.is_none()
            && self.comment.is_none()
            && self.function.is_none()
            && self.r#type.is_none()
            && self.variable.is_none()
            && self.property.is_none()
            && self.operator_.is_none()
            && self.meta.is_none()
            && self.invalid.is_none()
    }
}

/// 消息流配色覆盖：用户气泡、代码块底、元信息文字与分割线。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeMessageColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_bubble: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code_background: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_text: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub divider: Option<ThemeColor>,
}

impl ThemeMessageColors {
    fn is_empty(&self) -> bool {
        self.user_bubble.is_none()
            && self.code_background.is_none()
            && self.user_text.is_none()
            && self.meta.is_none()
            && self.divider.is_none()
    }
}

/// 终端配色覆盖：ANSI 十六色 + 光标、选区、附件条。
///
/// 只开放"画布"相关的格子；`keyboardAppearance` 这类平台语义不进包，
/// 它由客户端按 brightness 决定。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeTerminalColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub black: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub red: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub green: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub yellow: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blue: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub magenta: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cyan: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_black: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_red: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_green: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_yellow: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_blue: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_magenta: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_cyan: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_white: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chrome: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chrome_border: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chrome_foreground: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub overlay: Option<ThemeColor>,
}

impl ThemeTerminalColors {
    fn is_empty(&self) -> bool {
        self.foreground.is_none()
            && self.background.is_none()
            && self.cursor.is_none()
            && self.selection.is_none()
            && self.black.is_none()
            && self.red.is_none()
            && self.green.is_none()
            && self.yellow.is_none()
            && self.blue.is_none()
            && self.magenta.is_none()
            && self.cyan.is_none()
            && self.white.is_none()
            && self.bright_black.is_none()
            && self.bright_red.is_none()
            && self.bright_green.is_none()
            && self.bright_yellow.is_none()
            && self.bright_blue.is_none()
            && self.bright_magenta.is_none()
            && self.bright_cyan.is_none()
            && self.bright_white.is_none()
            && self.chrome.is_none()
            && self.chrome_border.is_none()
            && self.chrome_foreground.is_none()
            && self.overlay.is_none()
    }
}

/// 界面骨架色：直接落到 M3 `ColorScheme`。
///
/// 其余五组说的是"画什么"（文字/状态/语法/消息/终端），这一组说的是"底和线"。
/// 终端仿真类主题要纯黑底与单色描边，只能从这里给；没出现的角色仍由种子色派生。
///
/// 只开放客户端真正引用的 14 个角色：`secondary` / `tertiary` / `error` /
/// `inverse*` 这些没有任何调用点，开放它们只会扩大校验面与文档面积。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeSchemeColors {
    /// 主色：选中态胶囊、链接、聚焦圈。终端主题常取 ANSI 绿或青。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary: Option<ThemeColor>,
    /// 主色上的文字。深色终端主题给纯黑，就是"绿块黑字"的选中胶囊。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_primary: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_container: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_primary_container: Option<ThemeColor>,
    /// 页面底。纯黑底就靠这一格。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface_container_lowest: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface_container_low: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface_container: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface_container_high: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface_container_highest: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_surface: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_surface_variant: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outline: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outline_variant: Option<ThemeColor>,
}

impl ThemeSchemeColors {
    fn is_empty(&self) -> bool {
        self.primary.is_none()
            && self.on_primary.is_none()
            && self.primary_container.is_none()
            && self.on_primary_container.is_none()
            && self.surface.is_none()
            && self.surface_container_lowest.is_none()
            && self.surface_container_low.is_none()
            && self.surface_container.is_none()
            && self.surface_container_high.is_none()
            && self.surface_container_highest.is_none()
            && self.on_surface.is_none()
            && self.on_surface_variant.is_none()
            && self.outline.is_none()
            && self.outline_variant.is_none()
    }
}

/// 强调色覆盖：项目琥珀与 SSH 青绿两套渐变。
///
/// 这两组原来是客户端的固定品牌色，主题包碰不到——深色或绿色主题里，
/// 项目卡片左竖条、会话/任务计数胶囊、通话页麦克风仍是暖橙，一眼就看出
/// "这套配色只换了半张脸"。进包之后每套主题可以给一组同色系的强调色。
///
/// 只给四个端点色：渐变与 `tint`（`lerp(start, end, 0.35)`）由客户端派生，
/// 包不重复声明派生值。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeAccentColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_start: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_end: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_start: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_end: Option<ThemeColor>,
}

impl ThemeAccentColors {
    fn is_empty(&self) -> bool {
        self.project_start.is_none()
            && self.project_end.is_none()
            && self.ssh_start.is_none()
            && self.ssh_end.is_none()
    }
}

/// 页面氛围覆盖：整窗底色顶部那层淡色（`appSurfaceGradient` 的首段）。
///
/// 只有一格是有意的：强度（16%）与收敛位置（34%）属于版式常量，
/// 主题包只决定"偏哪个色"。给一个等于 `scheme.surface` 的值等于关掉渐变。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeSurfaceColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_tint: Option<ThemeColor>,
}

impl ThemeSurfaceColors {
    fn is_empty(&self) -> bool {
        self.top_tint.is_none()
    }
}

/// 全部颜色覆盖。每个分组都可缺省，组内每个字段也可缺省。
///
/// 曾经的 `icon` 组（`icon.folder_selected`）已移除：项目列表的文件夹图标
/// 改走 `accent.project_start`，不再单独配色。旧包仍带这一段时按未知字段
/// 忽略（本类型没有 `deny_unknown_fields`），安装不会因此失败。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeColors {
    /// M3 种子色：改了它，整个界面的色阶都跟着走。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<ThemeColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheme: Option<ThemeSchemeColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<ThemeTextColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<ThemeStatusColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub syntax: Option<ThemeSyntaxColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<ThemeMessageColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<ThemeTerminalColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent: Option<ThemeAccentColors>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<ThemeSurfaceColors>,
}

impl ThemeColors {
    /// 除种子色外一个覆盖都没有。服务端用它判断"这个包是不是什么都没改"。
    pub fn is_sparse(&self) -> bool {
        self.seed.is_none()
            && self.scheme.as_ref().is_none_or(ThemeSchemeColors::is_empty)
            && self.text.as_ref().is_none_or(ThemeTextColors::is_empty)
            && self.status.as_ref().is_none_or(ThemeStatusColors::is_empty)
            && self.syntax.as_ref().is_none_or(ThemeSyntaxColors::is_empty)
            && self
                .message
                .as_ref()
                .is_none_or(ThemeMessageColors::is_empty)
            && self
                .terminal
                .as_ref()
                .is_none_or(ThemeTerminalColors::is_empty)
            && self.accent.as_ref().is_none_or(ThemeAccentColors::is_empty)
            && self.surface.as_ref().is_none_or(ThemeSurfaceColors::is_empty)
    }
}

/// 一个已安装的主题包。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThemeSpec {
    /// 主题标识。取自 `theme.json` 的 `id`，也是安装目录名。
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub brightness: ThemeBrightness,
    /// 稀疏覆盖：`Some` 即"这个包改了这一格"，`None` 由客户端回落到内置派生值。
    #[serde(default)]
    pub colors: ThemeColors,
    /// Unix 毫秒时间戳。
    pub installed_at: i64,
    pub updated_at: i64,
}

/// 主题包列表。主题是"全量返回"的小集合（几十个），不做分页。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThemePage {
    pub items: Vec<ThemeSpec>,
}

impl ThemePage {
    pub fn empty() -> Self {
        Self { items: Vec::new() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_parses_both_lengths() {
        assert_eq!(
            ThemeColor::parse("#3B6EA5").expect("6 位").argb(),
            0xFF3B_6EA5
        );
        assert_eq!(
            ThemeColor::parse("3b6ea5").expect("无 #").argb(),
            0xFF3B_6EA5
        );
        assert_eq!(
            ThemeColor::parse("#803B6EA5").expect("8 位").argb(),
            0x803B_6EA5
        );
    }

    #[test]
    fn color_rejects_malformed() {
        for bad in ["", "#", "#12345", "#1234567", "#GGGGGG", "rgb(1,2,3)"] {
            assert!(ThemeColor::parse(bad).is_err(), "应拒绝: {bad}");
        }
    }

    #[test]
    fn color_serializes_canonically() {
        assert_eq!(ThemeColor::from_argb(0xFF3B_6EA5).to_hex(), "#3B6EA5");
        assert_eq!(ThemeColor::from_argb(0x803B_6EA5).to_hex(), "#803B6EA5");
    }

    #[test]
    fn spec_roundtrips_with_sparse_colors() {
        let spec = ThemeSpec {
            id: "nightfall".to_string(),
            name: "夜幕".to_string(),
            version: "1.0.0".to_string(),
            author: Some("me".to_string()),
            description: None,
            brightness: ThemeBrightness::Dark,
            colors: ThemeColors {
                seed: Some(ThemeColor::from_argb(0xFF63_5BFF)),
                text: Some(ThemeTextColors {
                    tertiary: Some(ThemeColor::from_argb(0xFF9A_9AA6)),
                    ..ThemeTextColors::default()
                }),
                ..ThemeColors::default()
            },
            installed_at: 1,
            updated_at: 2,
        };

        let raw = serde_json::to_string(&spec).expect("序列化失败");
        assert!(raw.contains(r#""brightness":"dark""#));
        assert!(raw.contains(r##""seed":"#635BFF""##));
        // 缺省字段不该上线缆：客户端靠"没有"来判断回落到内置值。
        assert!(!raw.contains("warning"), "未覆盖的状态色不应出现: {raw}");
        assert!(!raw.contains("description"));

        let back: ThemeSpec = serde_json::from_str(&raw).expect("解析失败");
        assert_eq!(back, spec);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let raw = r##"{
            "id": "x",
            "name": "X",
            "version": "1.0.0",
            "brightness": "light",
            "colors": { "seed": "#123456", "brand": "#FFFFFF" },
            "extra": true,
            "installed_at": 0,
            "updated_at": 0
        }"##;

        let spec: ThemeSpec = serde_json::from_str(raw).expect("应忽略未知字段");
        assert_eq!(spec.colors.seed.map(ThemeColor::argb), Some(0xFF12_3456));
    }

    #[test]
    fn accent_surface_roundtrip() {
        let spec = ThemeSpec {
            id: "homebrew".to_string(),
            name: "Homebrew 琥珀".to_string(),
            version: "1.1.0".to_string(),
            author: None,
            description: None,
            brightness: ThemeBrightness::Dark,
            colors: ThemeColors {
                accent: Some(ThemeAccentColors {
                    project_start: Some(ThemeColor::from_argb(0xFFFB_B040)),
                    ssh_start: Some(ThemeColor::from_argb(0xFF79_C7BE)),
                    ..ThemeAccentColors::default()
                }),
                surface: Some(ThemeSurfaceColors {
                    top_tint: Some(ThemeColor::from_argb(0xFFFB_B040)),
                }),
                ..ThemeColors::default()
            },
            installed_at: 0,
            updated_at: 0,
        };

        let raw = serde_json::to_string(&spec).expect("序列化失败");
        assert!(raw.contains(r##""project_start":"#FBB040""##), "{raw}");
        assert!(raw.contains(r##""top_tint":"#FBB040""##), "{raw}");
        // 没写的兄弟格不出现：客户端靠"没有"回落内置值。
        assert!(!raw.contains("project_end"), "{raw}");
        assert!(!raw.contains("ssh_end"), "{raw}");

        let back: ThemeSpec = serde_json::from_str(&raw).expect("解析失败");
        assert_eq!(back, spec);
    }

    #[test]
    fn only_new_groups_still_counts_as_override() {
        let colors = ThemeColors {
            surface: Some(ThemeSurfaceColors {
                top_tint: Some(ThemeColor::from_argb(0xFF63_5BFF)),
            }),
            ..ThemeColors::default()
        };
        assert!(!colors.is_sparse(), "只改 surface.top_tint 也是有效覆盖");
    }

    #[test]
    fn legacy_icon_group_is_ignored() {
        // 旧包还带已移除的 `icon.folder_selected`：解析必须宽松，
        // 否则升级后用户装过的主题包会突然装不上。
        let raw = r##"{
            "id": "nightfall",
            "name": "Nightfall",
            "version": "1.0.0",
            "brightness": "dark",
            "installed_at": 0,
            "updated_at": 0,
            "colors": {
                "accent": { "project_start": "#635BFF" },
                "icon": { "folder_selected": "#8B84FF" }
            }
        }"##;

        let spec: ThemeSpec = serde_json::from_str(raw).expect("旧包应能解析");
        assert_eq!(
            spec.colors.accent.as_ref().unwrap().project_start,
            Some(ThemeColor::from_argb(0xFF63_5BFF))
        );

        // 再序列化时 `icon` 段不再出现：这一格已经不属于契约。
        let back = serde_json::to_string(&spec).expect("序列化失败");
        assert!(!back.contains("folder_selected"), "{back}");
        assert!(!back.contains(r#""icon""#), "{back}");
    }

    #[test]
    fn bad_color_fails_deserialization() {
        let raw = r#"{"id":"x","name":"X","version":"1","brightness":"light","colors":{"seed":"nope"},"installed_at":0,"updated_at":0}"#;
        assert!(serde_json::from_str::<ThemeSpec>(raw).is_err());
    }

    #[test]
    fn sparse_detection_ignores_empty_groups() {
        let empty = ThemeColors {
            text: Some(ThemeTextColors::default()),
            ..ThemeColors::default()
        };
        assert!(empty.is_sparse());

        let seeded = ThemeColors {
            seed: Some(ThemeColor::from_argb(0xFF00_0000)),
            ..ThemeColors::default()
        };
        assert!(!seeded.is_sparse());
    }

    /// `scheme` 组是"底和线"：写了它就不再是空包，否则终端仿真包会被当成没改任何东西。
    #[test]
    fn scheme_group_counts_as_non_sparse_and_roundtrips() {
        let raw = r##"{
            "id": "homebrew-terminal",
            "name": "Homebrew Terminal",
            "version": "1.0.0",
            "brightness": "dark",
            "colors": {
                "scheme": {
                    "primary": "#00A600",
                    "on_primary": "#000000",
                    "surface": "#000000",
                    "surface_container_highest": "#181818",
                    "on_surface": "#E5E5E5",
                    "on_surface_variant": "#BFBFBF",
                    "outline": "#4D4D4D",
                    "outline_variant": "#2B2B2B"
                }
            },
            "installed_at": 0,
            "updated_at": 0
        }"##;

        let spec: ThemeSpec = serde_json::from_str(raw).expect("应解析");
        assert!(!spec.colors.is_sparse(), "只写 scheme 也是有效覆盖");
        assert_eq!(
            spec.colors
                .scheme
                .as_ref()
                .and_then(|scheme| scheme.surface)
                .map(ThemeColor::argb),
            Some(0xFF00_0000)
        );

        let json = serde_json::to_string(&spec).expect("序列化失败");
        assert!(
            json.contains(r##""surface":"#000000""##),
            "scheme 必须上线缆: {json}"
        );
        let back: ThemeSpec = serde_json::from_str(&json).expect("往返失败");
        assert_eq!(back, spec);
    }

    /// 空 `scheme` 组不算覆盖：与其它分组保持一致的判定口径。
    #[test]
    fn empty_scheme_group_stays_sparse() {
        let colors = ThemeColors {
            scheme: Some(ThemeSchemeColors::default()),
            ..ThemeColors::default()
        };
        assert!(colors.is_sparse());
    }
}
