import 'package:flutter/foundation.dart';
import 'package:re_highlight/languages/bash.dart' show langBash;
import 'package:re_highlight/languages/c.dart' show langC;
import 'package:re_highlight/languages/cmake.dart' show langCmake;
import 'package:re_highlight/languages/cpp.dart' show langCpp;
import 'package:re_highlight/languages/csharp.dart' show langCsharp;
import 'package:re_highlight/languages/css.dart' show langCss;
import 'package:re_highlight/languages/dart.dart' show langDart;
import 'package:re_highlight/languages/diff.dart' show langDiff;
import 'package:re_highlight/languages/dockerfile.dart' show langDockerfile;
import 'package:re_highlight/languages/go.dart' show langGo;
import 'package:re_highlight/languages/gradle.dart' show langGradle;
import 'package:re_highlight/languages/graphql.dart' show langGraphql;
import 'package:re_highlight/languages/http.dart' show langHttp;
import 'package:re_highlight/languages/ini.dart' show langIni;
import 'package:re_highlight/languages/java.dart' show langJava;
import 'package:re_highlight/languages/javascript.dart' show langJavascript;
import 'package:re_highlight/languages/json.dart' show langJson;
import 'package:re_highlight/languages/kotlin.dart' show langKotlin;
import 'package:re_highlight/languages/less.dart' show langLess;
import 'package:re_highlight/languages/lua.dart' show langLua;
import 'package:re_highlight/languages/makefile.dart' show langMakefile;
import 'package:re_highlight/languages/markdown.dart' show langMarkdown;
import 'package:re_highlight/languages/nginx.dart' show langNginx;
import 'package:re_highlight/languages/objectivec.dart' show langObjectivec;
import 'package:re_highlight/languages/perl.dart' show langPerl;
import 'package:re_highlight/languages/php.dart' show langPhp;
import 'package:re_highlight/languages/plaintext.dart' show langPlaintext;
import 'package:re_highlight/languages/powershell.dart' show langPowershell;
import 'package:re_highlight/languages/properties.dart' show langProperties;
import 'package:re_highlight/languages/protobuf.dart' show langProtobuf;
import 'package:re_highlight/languages/python.dart' show langPython;
import 'package:re_highlight/languages/r.dart' show langR;
import 'package:re_highlight/languages/ruby.dart' show langRuby;
import 'package:re_highlight/languages/rust.dart' show langRust;
import 'package:re_highlight/languages/scss.dart' show langScss;
import 'package:re_highlight/languages/shell.dart' show langShell;
import 'package:re_highlight/languages/sql.dart' show langSql;
import 'package:re_highlight/languages/swift.dart' show langSwift;
import 'package:re_highlight/languages/typescript.dart' show langTypescript;
import 'package:re_highlight/languages/vue.dart' show langVue;
import 'package:re_highlight/languages/xml.dart' show langXml;
import 'package:re_highlight/languages/yaml.dart' show langYaml;
import 'package:re_highlight/re_highlight.dart' show Mode;

/// 一种可以被高亮的语言。
///
/// 界面层只认 [id] / [label]：真正的语法定义（`Mode`）留在
/// [grammarOf] 里，避免 UI 文件 import `re_highlight`。
@immutable
class SyntaxLanguage {
  const SyntaxLanguage({required this.id, required this.label});

  /// `re_highlight` 的语言名，同时是注册名，如 `dart`。
  final String id;

  /// 展示名，如 `Dart`；Markdown 代码块的表头用它。
  final String label;

  @override
  bool operator ==(Object other) => other is SyntaxLanguage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SyntaxLanguage($id)';
}

/// 支持的 42 种语言。
///
/// 刻意不用 `languages/all.dart`：那会把 180+ 种语法定义一起打进包里，
/// 其中绝大多数在个人项目里永远不会出现。这里只 import 实际用得到的，
/// 新增语言要同时改 import、[grammarOf] 与 [_byAlias]——三处漏一处会编译报错。
const Map<String, SyntaxLanguage> _languages = <String, SyntaxLanguage>{
  'bash': SyntaxLanguage(id: 'bash', label: 'Bash'),
  'c': SyntaxLanguage(id: 'c', label: 'C'),
  'cmake': SyntaxLanguage(id: 'cmake', label: 'CMake'),
  'cpp': SyntaxLanguage(id: 'cpp', label: 'C++'),
  'csharp': SyntaxLanguage(id: 'csharp', label: 'C#'),
  'css': SyntaxLanguage(id: 'css', label: 'CSS'),
  'dart': SyntaxLanguage(id: 'dart', label: 'Dart'),
  'diff': SyntaxLanguage(id: 'diff', label: 'Diff'),
  'dockerfile': SyntaxLanguage(id: 'dockerfile', label: 'Dockerfile'),
  'go': SyntaxLanguage(id: 'go', label: 'Go'),
  'gradle': SyntaxLanguage(id: 'gradle', label: 'Gradle'),
  'graphql': SyntaxLanguage(id: 'graphql', label: 'GraphQL'),
  'http': SyntaxLanguage(id: 'http', label: 'HTTP'),
  'ini': SyntaxLanguage(id: 'ini', label: 'INI'),
  'java': SyntaxLanguage(id: 'java', label: 'Java'),
  'javascript': SyntaxLanguage(id: 'javascript', label: 'JavaScript'),
  'json': SyntaxLanguage(id: 'json', label: 'JSON'),
  'kotlin': SyntaxLanguage(id: 'kotlin', label: 'Kotlin'),
  'less': SyntaxLanguage(id: 'less', label: 'Less'),
  'lua': SyntaxLanguage(id: 'lua', label: 'Lua'),
  'makefile': SyntaxLanguage(id: 'makefile', label: 'Makefile'),
  'markdown': SyntaxLanguage(id: 'markdown', label: 'Markdown'),
  'nginx': SyntaxLanguage(id: 'nginx', label: 'Nginx'),
  'objectivec': SyntaxLanguage(id: 'objectivec', label: 'Objective-C'),
  'perl': SyntaxLanguage(id: 'perl', label: 'Perl'),
  'php': SyntaxLanguage(id: 'php', label: 'PHP'),
  'plaintext': SyntaxLanguage(id: 'plaintext', label: 'Plain text'),
  'powershell': SyntaxLanguage(id: 'powershell', label: 'PowerShell'),
  'properties': SyntaxLanguage(id: 'properties', label: 'Properties'),
  'protobuf': SyntaxLanguage(id: 'protobuf', label: 'Protobuf'),
  'python': SyntaxLanguage(id: 'python', label: 'Python'),
  'r': SyntaxLanguage(id: 'r', label: 'R'),
  'ruby': SyntaxLanguage(id: 'ruby', label: 'Ruby'),
  'rust': SyntaxLanguage(id: 'rust', label: 'Rust'),
  'scss': SyntaxLanguage(id: 'scss', label: 'SCSS'),
  'shell': SyntaxLanguage(id: 'shell', label: 'Shell'),
  'sql': SyntaxLanguage(id: 'sql', label: 'SQL'),
  'swift': SyntaxLanguage(id: 'swift', label: 'Swift'),
  'typescript': SyntaxLanguage(id: 'typescript', label: 'TypeScript'),
  'vue': SyntaxLanguage(id: 'vue', label: 'Vue'),
  'xml': SyntaxLanguage(id: 'xml', label: 'XML'),
  'yaml': SyntaxLanguage(id: 'yaml', label: 'YAML'),
};

/// 扩展名与语言别名 → 语言 id。
///
/// 一张表两用：文件按扩展名查，Markdown 代码块按 `language-xxx` 查。
/// `toml` 没有独立的语法定义，归到 `ini`（键值 + `[section]` + `#` 注释
/// 三类结构完全一致，TOML 的日期与多行字符串会退化成普通值）。
const Map<String, String> _byAlias = <String, String>{
  'bash': 'bash',
  'bat': 'bash',
  'c': 'c',
  'c++': 'cpp',
  'cc': 'cpp',
  'cfg': 'ini',
  'cmake': 'cmake',
  'cmd': 'bash',
  'conf': 'ini',
  'config': 'ini',
  'cpp': 'cpp',
  'cs': 'csharp',
  'csharp': 'csharp',
  'css': 'css',
  'csv': 'plaintext',
  'cxx': 'cpp',
  'dart': 'dart',
  'diff': 'diff',
  'docker': 'dockerfile',
  'dockerfile': 'dockerfile',
  'editorconfig': 'ini',
  'env': 'properties',
  'fish': 'bash',
  'gemspec': 'ruby',
  'go': 'go',
  'golang': 'go',
  'gql': 'graphql',
  'gradle': 'gradle',
  'graphql': 'graphql',
  'h': 'c',
  'hh': 'cpp',
  'hpp': 'cpp',
  'htm': 'xml',
  'html': 'xml',
  'http': 'http',
  'hxx': 'cpp',
  'ini': 'ini',
  'java': 'java',
  'js': 'javascript',
  'json': 'json',
  'json5': 'json',
  'jsonc': 'json',
  'jsx': 'javascript',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'ksh': 'bash',
  'less': 'less',
  'lua': 'lua',
  'm': 'objectivec',
  'make': 'makefile',
  'makefile': 'makefile',
  'markdown': 'markdown',
  'md': 'markdown',
  'mdx': 'markdown',
  'mjs': 'javascript',
  'mk': 'makefile',
  'mm': 'objectivec',
  'mts': 'typescript',
  'nginx': 'nginx',
  'objc': 'objectivec',
  'objective-c': 'objectivec',
  'patch': 'diff',
  'perl': 'perl',
  'php': 'php',
  'pl': 'perl',
  'plain': 'plaintext',
  'plaintext': 'plaintext',
  'plist': 'xml',
  'pm': 'perl',
  'powershell': 'powershell',
  'properties': 'properties',
  'proto': 'protobuf',
  'protobuf': 'protobuf',
  'ps1': 'powershell',
  'psd1': 'powershell',
  'psm1': 'powershell',
  'pwsh': 'powershell',
  'py': 'python',
  'pyi': 'python',
  'python': 'python',
  'python3': 'python',
  'pyw': 'python',
  'r': 'r',
  'rake': 'ruby',
  'rb': 'ruby',
  'rest': 'http',
  'rs': 'rust',
  'ru': 'ruby',
  'ruby': 'ruby',
  'rust': 'rust',
  'sass': 'scss',
  'scss': 'scss',
  'sh': 'bash',
  'shell': 'shell',
  'sql': 'sql',
  'svg': 'xml',
  'swift': 'swift',
  'text': 'plaintext',
  'toml': 'ini',
  'ts': 'typescript',
  'tsv': 'plaintext',
  'tsx': 'typescript',
  'txt': 'plaintext',
  'typescript': 'typescript',
  'vue': 'vue',
  'xhtml': 'xml',
  'xml': 'xml',
  'xsd': 'xml',
  'xsl': 'xml',
  'xslt': 'xml',
  'yaml': 'yaml',
  'yml': 'yaml',
  'zsh': 'bash',
};

/// 没有扩展名、或不靠扩展名就能认出来的文件。
///
/// 只收"打开概率高且认错代价大"的那几个：`Dockerfile` 当成纯文本还好，
/// 当成 `Makefile` 会把 `RUN` 整行染成关键字。
const Map<String, String> _byFileName = <String, String>{
  '.bash_aliases': 'bash',
  '.bash_profile': 'bash',
  '.bashrc': 'bash',
  '.babelrc': 'json',
  '.dockerignore': 'properties',
  '.editorconfig': 'ini',
  '.eslintrc': 'json',
  '.gitattributes': 'properties',
  '.gitconfig': 'properties',
  '.gitignore': 'properties',
  '.npmrc': 'properties',
  '.prettierrc': 'json',
  '.profile': 'bash',
  '.zprofile': 'bash',
  '.zshenv': 'bash',
  '.zshrc': 'bash',
  'brewfile': 'ruby',
  'cmakelists.txt': 'cmake',
  'containerfile': 'dockerfile',
  'dockerfile': 'dockerfile',
  'fastfile': 'ruby',
  'gemfile': 'ruby',
  'gnumakefile': 'makefile',
  'justfile': 'makefile',
  'makefile': 'makefile',
  'nginx.conf': 'nginx',
  'podfile': 'ruby',
  'rakefile': 'ruby',
  'vagrantfile': 'ruby',
};

/// 路径 → 语言。未知扩展名返回 `null`（界面按纯文本渲染）。
SyntaxLanguage? syntaxLanguageOfPath(String path) {
  final name = _baseName(path);
  if (name.isEmpty) {
    return null;
  }

  // `.env` / `.env.local` 没有"扩展名"，按前缀认。
  if (name == '.env' || name.startsWith('.env.')) {
    return _languages['properties'];
  }

  final byName = _byFileName[name];
  if (byName != null) {
    return _languages[byName];
  }

  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= name.length) {
    return null;
  }
  final id = _byAlias[name.substring(dot + 1)];
  return id == null ? null : _languages[id];
}

/// Markdown 代码块的语言标签 → 语言。
///
/// `language-xxx` 里的写法不受控（`ts` / `Typescript` / `node` 都有），
/// 这里统一小写后查表；表里没有就当作"没写语言"，不给高亮。
SyntaxLanguage? syntaxLanguageOfAlias(String? alias) {
  if (alias == null) {
    return null;
  }
  final key = alias.trim().toLowerCase();
  if (key.isEmpty) {
    return null;
  }
  final id = _byAlias[key];
  return id == null ? null : _languages[id];
}

/// 界面拿不到 [SyntaxLanguage] 时的兜底：纯文本，不加色。
SyntaxLanguage get plainTextLanguage => _languages['plaintext']!;

/// 语法定义里的 `subLanguage` 指向的语言，必须先注册到同一个 `Highlight`。
///
/// `re_highlight` 的 `processSubLanguage` 在目标语言没注册时会把整段
/// `addText` 掉（不报错、不抛异常），表现就是"文件打开了、行号在，
/// 但一个颜色都没有"。Vue 的根 Mode 本身就是 `subLanguage: 'xml'`，
/// 所以只注册 `vue` 等于什么都没高亮；HTML 的 `<script>` / `<style>`、
/// JS/TS 的 `css\`` 与 `gql\`` 模板、Dart 的 `///` 文档注释同理。
const Map<String, List<String>> _subLanguageIds = <String, List<String>>{
  'dockerfile': <String>['bash'],
  'dart': <String>['markdown'],
  'javascript': <String>['css', 'graphql', 'xml'],
  'markdown': <String>['xml'],
  'shell': <String>['bash'],
  'typescript': <String>['css', 'graphql', 'xml'],
  'vue': <String>['xml', 'javascript', 'typescript', 'css', 'scss'],
  'xml': <String>['css', 'javascript'],
  'yaml': <String>['ruby'],
};

/// 某个语言的子语言依赖（已过滤掉本表里没有的语言 id）。
List<SyntaxLanguage> subLanguagesOf(SyntaxLanguage language) {
  final ids = _subLanguageIds[language.id];
  if (ids == null) {
    return const <SyntaxLanguage>[];
  }
  return <SyntaxLanguage>[
    for (final id in ids)
      if (_languages[id] != null) _languages[id]!,
  ];
}

/// Vue 3 的 `<script setup>` 不在 highlight.js 的 vue 定义里
/// （它只认 `<script>` 与 `<script lang="ts">`），而这是现在最常见的写法。
/// 不补这一条，整段脚本会退回 xml：标签有颜色、`const` / `ref` 没有。
///
/// 补法是复制一份 vue 定义并在 `contains` 最前面插一条规则。**必须复制**：
/// 直接改全局 `langVue.contains` 时，若这个 Mode 已经被编译过（`isCompiled`），
/// 后续注册不会再编译新增的子规则，改了也不生效。副本只在第一次取用，
/// 之后复用同一个已编译对象。
Mode _vueWithScriptSetup() {
  final cached = _vueGrammarCache;
  if (cached != null) {
    return cached;
  }
  final grammar = langVue.copyWith(
    Mode(
      contains: <Mode>[
        Mode(
          begin: '^(\\s*)(<script\\s+setup[^>]*>)',
          end: '^(\\s*)(<\\/script>)',
          // `<script setup>` 没写 lang 时是 JS，但 TS 是 JS 的超集，
          // 用 typescript 一套规则能同时覆盖两种写法。
          subLanguage: 'typescript',
          excludeBegin: true,
          excludeEnd: true,
        ),
        ...?langVue.contains,
      ],
    ),
  );
  _vueGrammarCache = grammar;
  return grammar;
}

Mode? _vueGrammarCache;

/// 语言 id → `re_highlight` 的语法定义。
///
/// 只在高亮层内部调用；返回的 `Mode` 不要往 UI 层传。
Mode grammarOf(SyntaxLanguage language) => switch (language.id) {
  'bash' => langBash,
  'c' => langC,
  'cmake' => langCmake,
  'cpp' => langCpp,
  'csharp' => langCsharp,
  'css' => langCss,
  'dart' => langDart,
  'diff' => langDiff,
  'dockerfile' => langDockerfile,
  'go' => langGo,
  'gradle' => langGradle,
  'graphql' => langGraphql,
  'http' => langHttp,
  'ini' => langIni,
  'java' => langJava,
  'javascript' => langJavascript,
  'json' => langJson,
  'kotlin' => langKotlin,
  'less' => langLess,
  'lua' => langLua,
  'makefile' => langMakefile,
  'markdown' => langMarkdown,
  'nginx' => langNginx,
  'objectivec' => langObjectivec,
  'perl' => langPerl,
  'php' => langPhp,
  'plaintext' => langPlaintext,
  'powershell' => langPowershell,
  'properties' => langProperties,
  'protobuf' => langProtobuf,
  'python' => langPython,
  'r' => langR,
  'ruby' => langRuby,
  'rust' => langRust,
  'scss' => langScss,
  'shell' => langShell,
  'sql' => langSql,
  'swift' => langSwift,
  'typescript' => langTypescript,
  'vue' => _vueWithScriptSetup(),
  'xml' => langXml,
  'yaml' => langYaml,
  // `_languages` 与这里一一对应，走到这里说明表被改漏了：
  // 退回纯文本而不是抛异常，预览不该因为一个语言名崩掉。
  _ => langPlaintext,
};

String _baseName(String path) {
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  return name.toLowerCase();
}
