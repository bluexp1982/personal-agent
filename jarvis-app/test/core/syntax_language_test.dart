import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/syntax/syntax_language.dart';

void main() {
  test('常见扩展名映射到对应语言', () {
    expect(syntaxLanguageOfPath('lib/main.dart')?.id, 'dart');
    expect(syntaxLanguageOfPath('src/app.ts')?.id, 'typescript');
    expect(syntaxLanguageOfPath('script.PY')?.id, 'python');
    expect(syntaxLanguageOfPath('Cargo.toml')?.id, 'ini');
    expect(syntaxLanguageOfPath('config.yaml')?.id, 'yaml');
    expect(syntaxLanguageOfPath('index.html')?.id, 'xml');
    expect(syntaxLanguageOfPath('styles.scss')?.id, 'scss');
    expect(syntaxLanguageOfPath('query.sql')?.id, 'sql');
    expect(syntaxLanguageOfPath('server.go')?.id, 'go');
    expect(syntaxLanguageOfPath('Dockerfile')?.id, 'dockerfile');
    expect(syntaxLanguageOfPath('Makefile')?.id, 'makefile');
  });

  test('无扩展名文件按文件名识别', () {
    expect(syntaxLanguageOfPath('.gitignore')?.id, 'properties');
    expect(syntaxLanguageOfPath('/tmp/proj/.env')?.id, 'properties');
    expect(syntaxLanguageOfPath('/tmp/proj/.env.local')?.id, 'properties');
    expect(syntaxLanguageOfPath('.zshrc')?.id, 'bash');
    expect(syntaxLanguageOfPath('CMakeLists.txt')?.id, 'cmake');
    expect(syntaxLanguageOfPath('Gemfile')?.id, 'ruby');
  });

  test('未知扩展名与认不出的文件名返回 null', () {
    expect(syntaxLanguageOfPath('notes.unknownext'), isNull);
    expect(syntaxLanguageOfPath('LICENSE'), isNull);
    expect(syntaxLanguageOfPath('/tmp/'), isNull);
  });

  test('代码块语言标签归一化', () {
    expect(syntaxLanguageOfAlias('ts')?.id, 'typescript');
    expect(syntaxLanguageOfAlias('JS')?.id, 'javascript');
    expect(syntaxLanguageOfAlias('c++')?.id, 'cpp');
    expect(syntaxLanguageOfAlias('yml')?.id, 'yaml');
    expect(syntaxLanguageOfAlias('sh')?.id, 'bash');
    expect(syntaxLanguageOfAlias('node')?.id, isNull);
    expect(syntaxLanguageOfAlias('随便写的'), isNull);
    expect(syntaxLanguageOfAlias(''), isNull);
    expect(syntaxLanguageOfAlias(null), isNull);
  });

  test('所有登记的语言都能拿到语法定义', () {
    for (final alias in <String>[
      'dart',
      'typescript',
      'python',
      'rust',
      'go',
      'json',
      'yaml',
      'ini',
      'dockerfile',
      'makefile',
      'xml',
      'bash',
      'markdown',
      'plaintext',
    ]) {
      final language = syntaxLanguageOfAlias(alias);
      expect(language, isNotNull, reason: alias);
      // 定义缺失会在这里抛（`grammarOf` 的兜底分支只对空表有效）。
      expect(grammarOf(language!), isNotNull, reason: alias);
    }
  });
}
