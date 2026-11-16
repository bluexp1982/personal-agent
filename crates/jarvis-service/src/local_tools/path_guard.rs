//! 文件工具的路径准入。
//!
//! 这里是**唯一**的入口：任何工具都不允许自己 `Path::join` 之后就打开文件。
//! 三条规则，缺一条就等于开了全盘读权限：
//!
//! 1. 根在构造时就 canonicalize 一次，之后所有比较都用真实路径；
//! 2. 目标（相对或绝对）先拼到根上再 canonicalize，然后复核仍在根内——
//!    这样 `..`、软链接、macOS 的 `/var` → `/private/var` 都被同一次规范化收掉；
//! 3. 命中密钥类文件直接拒绝。项目是用户自己的项目，但 `.env` 里的东西
//!    一旦进了 `tool` 消息就会发给第三方模型，这不是"读本地文件"的合理延伸。
//!
//! 与 `project_files` 的关系：准入规则相同，但那边服务的是用户主动点击的
//! 文件树。模型是**无人监督**地读，所以这里多一道敏感名拦截，其余复用同一套
//! canonical 逻辑（`project_files` 的私有函数已提升为 `pub(crate)`）。

use std::path::{Path, PathBuf};

use crate::project::ProjectError;

/// 一个会话可读的根：会话所属项目的目录。
#[derive(Debug, Clone)]
pub(crate) struct ProjectRoot {
    /// 已 canonicalize 的绝对路径。
    root: PathBuf,
}

/// 一次可写路径的解析结果。
///
/// `relative` 是根内相对路径：回执、审计、待确认记录一律用它，
/// 绝对路径只在本进程内用来写盘，不给模型也不给历史消息。
#[derive(Debug, Clone)]
pub(crate) struct WritableTarget {
    /// 绝对路径。目标是新建时，中间目录可能还不存在。
    pub(crate) abs: PathBuf,
    /// 根内相对路径（`/` 分隔）。
    pub(crate) relative: String,
    /// 目标文件当前是否已存在。已存在意味着要走覆盖确认。
    pub(crate) exists: bool,
}

/// 写入路径的长度与层级上限。
///
/// 不是为了防攻击，而是为了拦住"模型把整段 HTML 当文件名"这类失控参数：
/// 那种路径在 macOS 上会直接报 ENAMETOOLONG，话说清楚比抛 IO 错误好。
const MAX_WRITE_PATH_CHARS: usize = 512;
const MAX_WRITE_DEPTH: usize = 16;

/// 准入失败。
///
/// `Denied` 与 `Invalid` 分开是为了审计与文案：越界是"不允许"，不存在是"没找到"，
/// 两者的下一步建议完全不同。
#[derive(Debug, thiserror::Error)]
pub(crate) enum GuardError {
    #[error("{0}")]
    Denied(String),
    #[error("{0}")]
    Invalid(String),
}

impl ProjectRoot {
    /// 根不可访问或不是目录时返回错误。调用方据此决定**不注册**文件工具。
    pub(crate) fn new(root: &str) -> Result<Self, GuardError> {
        let path = Path::new(root)
            .canonicalize()
            .map_err(|err| GuardError::Invalid(format!("项目目录不可访问（{root}）：{err}")))?;

        if !path.is_dir() {
            return Err(GuardError::Invalid(format!(
                "项目目录已不是目录（{}）",
                path.display()
            )));
        }

        Ok(Self { root: path })
    }

    /// 规范化后的根，用于交给 `project_files`。
    pub(crate) fn root(&self) -> &Path {
        &self.root
    }

    /// 把模型给的路径解析成根内的真实路径。
    ///
    /// 空串表示根本身；相对路径基于根解析；绝对路径也接受，但必须落在根内。
    pub(crate) fn resolve(&self, raw: &str) -> Result<PathBuf, GuardError> {
        let raw = raw.trim();
        if raw.contains('\0') {
            return Err(GuardError::Invalid("路径里不能包含空字符".to_string()));
        }
        if raw.is_empty() {
            return Ok(self.root.clone());
        }

        let candidate = Path::new(raw);
        let joined = if candidate.is_absolute() {
            candidate.to_path_buf()
        } else {
            self.root.join(candidate)
        };

        let first_error = match self.canonical(&joined) {
            Ok(path) => return Ok(path),
            Err(error) => error,
        };

        // 唯一一次重试：模型经常把项目名当成第一层目录（`hello-demo/clock.html`），
        // 而项目根就是 `hello-demo` 本身。线上的实际表现是模型在 `list_dir` 之后
        // 仍然拼错，然后连着几轮越界，最后空答。
        //
        // 去掉首段再走同一套 canonical 复核：边界一点没放松——仍然必须落在根内，
        // 敏感文件名仍然由 [`ProjectRoot::file`] 拦。原路径能解析时永远优先用原路径，
        // 所以"项目里真的有个同名子目录"的布局不受影响。
        if let Some(stripped) = self.without_root_prefix(raw) {
            if let Ok(path) = self.canonical(&self.root.join(&stripped)) {
                tracing::debug!(%raw, %stripped, "路径带了项目名首段，按去掉后解析");
                return Ok(path);
            }
        }

        Err(first_error)
    }

    /// 复用 `project_files` 的规范化与包含复核：边界只能有一份实现。
    fn canonical(&self, target: &Path) -> Result<PathBuf, GuardError> {
        crate::project_files::canonical_within(&self.root, &target.to_string_lossy()).map_err(
            |err| match err {
                ProjectError::Denied(reason) => GuardError::Denied(reason),
                ProjectError::Invalid(reason) => GuardError::Invalid(reason),
                other => GuardError::Invalid(other.to_string()),
            },
        )
    }

    /// 首段恰好是项目根目录名时，返回去掉它的剩余路径。
    ///
    /// 只处理"第一段 == 根名"这一种：模型拼错的方式很固定，宽泛的猜测
    /// 会让"读不到"变成"读到了别的东西"，那比报错更难查。
    fn without_root_prefix(&self, raw: &str) -> Option<String> {
        let (first, rest) = raw.split_once('/')?;
        let rest = rest.trim_matches('/');
        if rest.is_empty() {
            return None;
        }
        (first.trim() == self.root_label()).then(|| rest.to_string())
    }

    /// 解析一个**要写入**的路径。
    ///
    /// 与 [`ProjectRoot::resolve`] 的差别不只是"允许目标不存在"：
    ///
    /// - 只接受根内相对路径。绝对路径一律拒绝——模型拼错一次就会写到别处，
    ///   而写入没有"读错了就算了"这种退路；
    /// - 隐藏段与 `.git` 直接拒绝：写入会改文件，`.env` / `.git/config` 这类
    ///   连"存在性"都不该被模型探到；
    /// - 祖先逐级核对：目标可以不存在，但已存在的那一段必须规范化后仍在根内。
    ///   断链软链接虽然 `exists()` 为假，也按"已存在"处理，否则写入会顺着它落到根外。
    pub(crate) fn resolve_new(&self, raw: &str) -> Result<WritableTarget, GuardError> {
        let raw = raw.trim();
        if raw.is_empty() {
            return Err(GuardError::Invalid("缺少文件路径".to_string()));
        }
        if raw.contains('\0') {
            return Err(GuardError::Invalid("路径里不能包含空字符".to_string()));
        }
        if raw.chars().count() > MAX_WRITE_PATH_CHARS {
            return Err(GuardError::Invalid(format!(
                "路径太长（上限 {MAX_WRITE_PATH_CHARS} 字符）"
            )));
        }

        let candidate = Path::new(raw);
        if candidate.is_absolute() {
            return Err(GuardError::Denied(format!(
                "写入只接受项目内的相对路径（当前是 {raw}）"
            )));
        }

        let mut segments: Vec<String> = Vec::new();
        for component in candidate.components() {
            match component {
                std::path::Component::Normal(segment) => {
                    let segment = segment.to_string_lossy().to_string();
                    if segment == ".git" {
                        return Err(GuardError::Denied("不能写入 .git 目录".to_string()));
                    }
                    if segment.starts_with('.') {
                        return Err(GuardError::Denied(format!(
                            "不能写入隐藏文件或目录（{segment}）"
                        )));
                    }
                    segments.push(segment);
                }
                // `./a.html` 是模型最常见的写法之一，忽略即可，不因此拒绝。
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    return Err(GuardError::Denied(
                        "路径不能包含 ..（写入不接受越界路径）".to_string(),
                    ));
                }
                other => {
                    return Err(GuardError::Denied(format!("不支持的路径形式：{other:?}")));
                }
            }
        }

        // 模型的固定写法：把项目名当第一层目录（`code-001/hourglass.html`）。
        // 起因是 `list_dir` 的根目录标签就长这样，抄下来就成了路径前缀。
        //
        // 只在"根下还没有这个同名目录"时剥：真有同名子目录说明项目结构就是
        // 套了一层，替用户改结构比多一个目录更糟。
        if segments.len() > 1 && segments[0] == self.root_label() {
            if !self.root.join(&segments[0]).exists() {
                segments.remove(0);
            }
        }

        if segments.is_empty() {
            return Err(GuardError::Invalid("缺少文件名".to_string()));
        }
        if segments.len() > MAX_WRITE_DEPTH {
            return Err(GuardError::Invalid(format!(
                "目录层级太深（上限 {MAX_WRITE_DEPTH} 层）"
            )));
        }

        let relative = segments.join("/");
        check_sensitive(&relative)?;

        // 找到"第一个不存在的段"：它之前的部分必须真实存在且仍在根内。
        let mut probe = self.root.clone();
        let mut tail_start = segments.len();
        for (index, segment) in segments.iter().enumerate() {
            let next = probe.join(segment);
            if std::fs::symlink_metadata(&next).is_err() {
                tail_start = index;
                break;
            }
            probe = next;
        }

        let resolved = probe.canonicalize().map_err(|err| {
            GuardError::Invalid(format!("上级目录不可访问（{}）：{err}", probe.display()))
        })?;
        if !resolved.starts_with(&self.root) {
            return Err(GuardError::Denied(format!(
                "{relative} 会写到项目之外，已拒绝"
            )));
        }

        // 整条路径都已存在：要么是待覆盖的文件，要么撞上了一个目录。
        if tail_start == segments.len() {
            if resolved.is_dir() {
                return Err(GuardError::Invalid(format!(
                    "{relative} 是目录，不能当文件写入"
                )));
            }
            return Ok(WritableTarget {
                abs: resolved,
                relative,
                exists: true,
            });
        }

        if !resolved.is_dir() {
            return Err(GuardError::Invalid(format!(
                "{} 不是目录，不能在里面建文件",
                resolved.display()
            )));
        }

        let mut target = resolved;
        for segment in &segments[tail_start..] {
            target.push(segment);
        }

        Ok(WritableTarget {
            abs: target,
            relative,
            exists: false,
        })
    }

    /// 解析一个目录。
    pub(crate) fn dir(&self, raw: &str) -> Result<PathBuf, GuardError> {
        let path = self.resolve(raw)?;
        if !path.is_dir() {
            return Err(GuardError::Invalid(format!("{raw} 不是目录")));
        }
        Ok(path)
    }

    /// 解析一个可读文件，并拦下密钥类文件。
    pub(crate) fn file(&self, raw: &str) -> Result<PathBuf, GuardError> {
        let path = self.resolve(raw)?;
        if !path.is_file() {
            return Err(GuardError::Invalid(format!("{raw} 不是文件")));
        }
        check_sensitive(&self.relative(&path))?;
        Ok(path)
    }

    /// 项目相对路径。回填文本、来源卡片与审计都用它，不对外暴露绝对路径。
    pub(crate) fn relative(&self, abs: &Path) -> String {
        abs.strip_prefix(&self.root)
            .map(|path| path.to_string_lossy().replace('\\', "/"))
            .unwrap_or_else(|_| {
                // 理论上不会发生（resolve 已经复核过）；真发生了也只露文件名。
                abs.file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default()
            })
    }

    /// 回填文本里展示的根名：绝对路径对模型没意义，只会占上下文。
    pub(crate) fn root_label(&self) -> String {
        self.root
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| self.root.to_string_lossy().to_string())
    }
}

/// 密钥类文件的名单。
///
/// 判断只看**文件名与相对路径**，不读内容：读内容再判断等于已经把敏感数据读进内存，
/// 而且"看着像密钥"的启发式必然误伤。宁可漏一个，不可放过 `.env`。
fn check_sensitive(relative: &str) -> Result<(), GuardError> {
    let lower = relative.to_ascii_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);

    if name.starts_with(".env")
        || name == ".netrc"
        || name == ".npmrc"
        || name == ".pgpass"
        || name == "credentials"
        || name.starts_with("credentials.")
        || name.starts_with("id_rsa")
        || name.starts_with("id_dsa")
        || name.starts_with("id_ecdsa")
        || name.starts_with("id_ed25519")
        || lower.ends_with(".pem")
        || lower.ends_with(".key")
        || lower.ends_with(".p12")
        || lower.ends_with(".pfx")
        || lower.ends_with(".keystore")
        || lower.ends_with(".jks")
    {
        return Err(GuardError::Denied(format!(
            "{relative} 可能是密钥或凭据文件，已拒绝读取"
        )));
    }

    // `.git/config` 里可能有带 token 的 remote 地址。
    if lower == ".git/config" || lower.ends_with("/.git/config") {
        return Err(GuardError::Denied(format!(
            "{relative} 可能包含仓库凭据，已拒绝读取"
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pa-guard-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        dir.canonicalize().expect("规范化失败")
    }

    fn root_of(dir: &Path) -> ProjectRoot {
        ProjectRoot::new(&dir.to_string_lossy()).expect("根应可用")
    }

    #[test]
    fn resolves_relative_path_inside_root() {
        let dir = temp_root("rel");
        std::fs::create_dir_all(dir.join("src")).expect("建目录失败");
        std::fs::write(dir.join("src").join("main.rs"), "fn main() {}").expect("写文件失败");

        let guard = root_of(&dir);
        let file = guard.file("src/main.rs").expect("应可解析");
        assert_eq!(guard.relative(&file), "src/main.rs");
        assert_eq!(guard.dir("").expect("空串应是根"), dir);
    }

    #[test]
    fn rejects_escape_and_outside_absolute() {
        let dir = temp_root("escape");
        let guard = root_of(&dir);

        let escaped = guard.file("../outside.txt").expect_err("越界必须拒绝");
        assert!(matches!(escaped, GuardError::Invalid(_)), "{escaped}");

        let absolute = guard.file("/etc/hosts").expect_err("根外绝对路径必须拒绝");
        assert!(matches!(absolute, GuardError::Denied(_)), "{absolute}");
    }

    #[test]
    fn rejects_symlink_pointing_outside() {
        let dir = temp_root("symlink");
        let outside = temp_root("symlink-outside");
        std::fs::write(outside.join("secret.txt"), "x").expect("写文件失败");

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(outside.join("secret.txt"), dir.join("link.txt"))
                .expect("建软链接失败");
            let guard = root_of(&dir);
            let error = guard.file("link.txt").expect_err("软链接越界必须拒绝");
            assert!(matches!(error, GuardError::Denied(_)), "{error}");
        }
    }

    #[test]
    fn accepts_path_prefixed_with_the_project_name() {
        let dir = temp_root("root-prefix");
        std::fs::write(dir.join("clock.html"), "<h1/>").expect("写文件失败");

        let guard = root_of(&dir);
        let name = dir
            .file_name()
            .expect("临时目录应有名字")
            .to_string_lossy()
            .to_string();

        let file = guard
            .file(&format!("{name}/clock.html"))
            .expect("去掉项目名前缀后应能解析");
        assert_eq!(guard.relative(&file), "clock.html");
    }

    #[test]
    fn prefers_a_real_subdirectory_named_like_the_project() {
        // 项目里确实有个同名子目录时，原路径必须优先，不能被"容错"抢走。
        let dir = temp_root("root-sub");
        let name = dir
            .file_name()
            .expect("临时目录应有名字")
            .to_string_lossy()
            .to_string();
        std::fs::create_dir_all(dir.join(&name)).expect("建目录失败");
        std::fs::write(dir.join(&name).join("inner.html"), "x").expect("写文件失败");

        let guard = root_of(&dir);
        let file = guard
            .file(&format!("{name}/inner.html"))
            .expect("应直接命中真实子目录");
        assert_eq!(guard.relative(&file), format!("{name}/inner.html"));
    }

    #[test]
    fn rejects_secret_names() {
        let dir = temp_root("secret");
        std::fs::create_dir_all(dir.join(".git")).expect("建目录失败");
        for name in [
            ".env",
            ".env.local",
            "id_rsa",
            "server.pem",
            "tls.key",
            "credentials.json",
        ] {
            std::fs::write(dir.join(name), "secret").expect("写文件失败");
            let guard = root_of(&dir);
            let error = guard.file(name).expect_err("敏感文件必须拒绝");
            assert!(matches!(error, GuardError::Denied(_)), "{name}: {error}");
        }

        std::fs::write(dir.join(".git").join("config"), "[remote]").expect("写文件失败");
        let guard = root_of(&dir);
        assert!(
            matches!(guard.file(".git/config"), Err(GuardError::Denied(_))),
            ".git/config 必须拒绝"
        );
    }

    #[test]
    fn resolve_new_rejects_escape_absolute_and_hidden() {
        let dir = temp_root("write-guard");
        let guard = root_of(&dir);

        // 写入不接受绝对路径：拼错一次就会写到别处，没有"读错了"这种退路。
        assert!(matches!(
            guard.resolve_new("/tmp/evil.html"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(
            guard.resolve_new("../evil.html"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(
            guard.resolve_new("sub/../../evil.html"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(
            guard.resolve_new(".env"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(
            guard.resolve_new(".git/config"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(
            guard.resolve_new("id_rsa"),
            Err(GuardError::Denied(_))
        ));
        assert!(matches!(guard.resolve_new(""), Err(GuardError::Invalid(_))));
    }

    #[test]
    fn resolve_new_keeps_missing_tail_and_reports_existing_file() {
        let dir = temp_root("write-new");
        std::fs::write(dir.join("old.html"), "<h1/>").expect("写文件失败");
        std::fs::create_dir_all(dir.join("prototypes")).expect("建目录失败");

        let guard = root_of(&dir);

        let fresh = guard
            .resolve_new("./prototypes/calc.html")
            .expect("新路径应通过");
        assert!(!fresh.exists);
        assert_eq!(fresh.relative, "prototypes/calc.html");
        assert_eq!(fresh.abs, dir.join("prototypes").join("calc.html"));

        let existing = guard.resolve_new("old.html").expect("已存在文件应通过");
        assert!(existing.exists);
        assert_eq!(existing.relative, "old.html");
    }

    #[test]
    fn resolve_new_strips_redundant_project_name_prefix() {
        let dir = temp_root("write-prefix");
        let guard = root_of(&dir);
        let name = dir
            .file_name()
            .expect("临时目录应有名字")
            .to_string_lossy()
            .to_string();

        // 根下还没有同名目录：模型把项目名当第一层，剥掉后写到根。
        let target = guard
            .resolve_new(&format!("{name}/hourglass.html"))
            .expect("应通过");
        assert_eq!(target.relative, "hourglass.html");
        assert_eq!(target.abs, dir.join("hourglass.html"));

        // 真有同名子目录：尊重原路径，不替用户改结构。
        std::fs::create_dir_all(dir.join(&name)).expect("建目录失败");
        let nested = guard
            .resolve_new(&format!("{name}/inner.html"))
            .expect("应通过");
        assert_eq!(nested.relative, format!("{name}/inner.html"));
    }

    #[test]
    fn resolve_new_refuses_symlink_that_leaves_root() {
        let dir = temp_root("write-symlink");
        let outside = temp_root("write-symlink-outside");

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, dir.join("escape")).expect("建软链接失败");
            let guard = root_of(&dir);
            // 逐级核对：已存在的那段（escape）规范化后不在根内，必须拒绝。
            assert!(matches!(
                guard.resolve_new("escape/evil.html"),
                Err(GuardError::Denied(_))
            ));
        }
    }

    #[test]
    fn allows_ordinary_file_named_like_config() {
        let dir = temp_root("ordinary");
        std::fs::write(dir.join("config.toml"), "a = 1").expect("写文件失败");
        let guard = root_of(&dir);
        assert!(guard.file("config.toml").is_ok(), "普通配置不应被拦");
    }
}
