import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/features/ssh/ssh_terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 终端不再固定黑底：浅色主题下必须给出一套浅色配色，
/// 深色主题保持原来的暗色方案。
///
/// 配色现在挂在统一的 [AppPalette] 上（`palette.terminal`），
/// 所以断言也跟着从 `TerminalPalette.forBrightness` 改成 `AppPalette` 入口。
void main() {
  group('terminalPaletteFor', () {
    test('浅色 palette 是浅底深字', () {
      final palette = AppPalette.forBrightness(Brightness.light).terminal;

      expect(palette.background.computeLuminance(), greaterThan(0.8));
      expect(palette.theme.foreground.computeLuminance(), lessThan(0.2));
      expect(palette.keyboardAppearance, Brightness.light);
      expect(
        palette.theme.background,
        palette.background,
        reason: '画布底色与 xterm 背景必须一致，否则边缘会露出一圈异色',
      );
    });

    test('深色 palette 沿用原来的暗色', () {
      final palette = AppPalette.forBrightness(Brightness.dark).terminal;

      expect(palette.background, const Color(0xFF0B0F14));
      expect(palette.chrome, const Color(0xFF111820));
      expect(palette.keyboardAppearance, Brightness.dark);
    });

    test('两套配色互不相同，且状态栏与终端同族', () {
      final light = AppPalette.forBrightness(Brightness.light).terminal;
      final dark = AppPalette.forBrightness(Brightness.dark).terminal;

      expect(light.background, isNot(dark.background));
      expect(light.chrome, isNot(dark.chrome));
      expect(
        light.chrome.computeLuminance(),
        greaterThan(light.background.computeLuminance() - 0.1),
        reason: '浅色状态栏应比终端底色略深或接近，不能反过来变成深色条',
      );
      expect(
        dark.chrome.computeLuminance(),
        lessThan(dark.background.computeLuminance() + 0.1),
      );
    });
  });

  testWidgets('浅色主题下终端拿到的是浅色背景', (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: Scaffold(body: SshTerminalView(terminal: terminal)),
      ),
    );
    await tester.pumpAndSettle();

    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.theme, isNotNull);
    expect(
      view.theme.background,
      AppPalette.forBrightness(Brightness.light).terminal.background,
      reason: '浅色界面里不能再是一块纯黑终端',
    );
  });

  testWidgets('深色主题下终端仍是暗色', (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: SshTerminalView(terminal: terminal)),
      ),
    );
    await tester.pumpAndSettle();

    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      view.theme.background,
      AppPalette.forBrightness(Brightness.dark).terminal.background,
    );
    expect(view.keyboardAppearance, Brightness.dark);
  });

  testWidgets('终端不吃窗口顶端的安全区留白', (tester) async {
    final terminal = Terminal(maxLines: 100);

    // macOS 隐藏标题栏后，`HiddenWindowTitleBarInset` 会把
    // `MediaQuery.padding.top` 补成 32（给红绿灯让位）。xterm 会把它当成
    // "被系统 UI 遮住的安全区"，把内容整体下推 32dp 并从行数里扣掉，
    // 终端顶边因此空出一条黑带。终端在面板内部，必须不受这份留白影响。
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(top: 32),
            viewPadding: EdgeInsets.only(top: 32),
          ),
          child: Scaffold(body: SshTerminalView(terminal: terminal)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(TerminalView));
    expect(
      MediaQuery.of(context).padding.top,
      0,
      reason: 'xterm 用 MediaQuery.padding 计算绘制偏移，这里必须清掉顶部安全区',
    );
  });
}
