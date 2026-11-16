import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/project_paths.dart';

void main() {
  test('POSIX 路径按项目根截断', () {
    expect(projectRelativePath('/tmp/demo/cat.html', '/tmp/demo'), 'cat.html');
    expect(
      projectRelativePath('/tmp/demo/styles/theme.css', '/tmp/demo'),
      'styles/theme.css',
    );
  });

  test('根路径带尾斜杠不影响匹配', () {
    expect(projectRelativePath('/tmp/demo/a.txt', '/tmp/demo/'), 'a.txt');
  });

  test('Windows 服务端：反斜杠归一化且大小写不敏感', () {
    expect(
      projectRelativePath(r'C:\Users\Yao\demo\cat.html', r'C:\Users\Yao\demo'),
      'cat.html',
    );
    expect(
      projectRelativePath(r'c:\users\yao\demo\sub\a.txt', r'C:\Users\Yao\demo'),
      'sub/a.txt',
    );
  });

  test('前缀只按整段比较：demo2 不算 demo 的子路径', () {
    expect(
      projectRelativePath('/tmp/demo2/a.txt', '/tmp/demo'),
      '/tmp/demo2/a.txt',
    );
  });

  test('根自身与根外路径退化为完整绝对路径', () {
    expect(projectRelativePath('/tmp/demo', '/tmp/demo'), '/tmp/demo');
    expect(
      projectRelativePath('/tmp/other/a.txt', '/tmp/demo'),
      '/tmp/other/a.txt',
    );
  });

  test('没有根信息时返回归一化后的完整路径', () {
    expect(projectRelativePath(r'C:\demo\a.txt', ''), 'C:/demo/a.txt');
  });

  test('POSIX 根目录下的路径', () {
    expect(projectRelativePath('/tmp/a.txt', '/'), 'tmp/a.txt');
  });
}
