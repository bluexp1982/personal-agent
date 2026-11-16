import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 一页已经加载出来的会话：`internalUri` 非空是"有页面"的判据。
  BrowserSessionState loaded({BrowserTarget? target, String? title}) {
    return BrowserSessionState(
      target: target,
      internalUri: Uri.parse('http://127.0.0.1:5555/'),
      address: 'localhost:3000',
      title: title,
    );
  }

  test('空白标签显示「新标签页」', () {
    expect(browserTabLabel(const BrowserSessionState()), kBrowserBlankTabLabel);
  });

  test('地址都填错了也还是「新标签页」：页面根本没打开', () {
    final state = BrowserSessionState(
      address: '',
      error: const BrowserFailure(
        kind: BrowserFailureKind.invalidInput,
        message: 'bad',
        hint: '地址无法识别',
      ),
    );
    expect(browserTabLabel(state), kBrowserBlankTabLabel);
  });

  test('有页面标题就用标题', () {
    expect(
      browserTabLabel(loaded(target: const ServerPortTarget(
        host: '127.0.0.1',
        port: 3000,
      )).copyWith(title: '示例站点')),
      '示例站点',
    );
  });

  test('标题只有空白时退回域名，而不是显示一行空白', () {
    expect(
      browserTabLabel(loaded(
        target: const ServerPortTarget(host: '127.0.0.1', port: 3000),
        title: '   ',
      )),
      'localhost:3000',
    );
  });

  group('没有标题时用域名', () {
    test('本机端口统一显示成 localhost', () {
      expect(
        browserTabLabel(loaded(
          target: const ClientPortTarget(host: '127.0.0.1', port: 5173),
        )),
        'localhost:5173',
      );
    });

    test('服务器端口保留原始主机名', () {
      expect(
        browserTabLabel(loaded(
          target: const ServerPortTarget(host: '10.0.0.2', port: 8080),
        )),
        '10.0.0.2:8080',
      );
    });

    test('互联网地址取域名', () {
      expect(
        browserTabLabel(loaded(
          target: InternetTarget(Uri.parse('https://example.com/a/b')),
        )),
        'example.com',
      );
    });

    test('本地目录取末段目录名', () {
      expect(
        browserTabLabel(loaded(
          target: const ClientDirectoryTarget('/tmp/hello-demo/'),
        )),
        'hello-demo',
      );
    });

    test('根目录没有名字，退回「浏览器」', () {
      expect(
        browserTabLabel(loaded(target: const ClientDirectoryTarget('/'))),
        '浏览器',
      );
    });
  });

  test('browserHostLabel 对空目标返回 null', () {
    expect(browserHostLabel(null), isNull);
  });
}
