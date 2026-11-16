import 'package:jarvis_app/src/core/browser/browser_zoom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('梯度与 Chrome 一致：25% 到 500%，严格递增', () {
    expect(kBrowserZoomLadder.first, kBrowserZoomMin);
    expect(kBrowserZoomLadder.last, kBrowserZoomMax);
    expect(kBrowserZoomLadder, contains(1.0));

    for (var i = 1; i < kBrowserZoomLadder.length; i++) {
      expect(
        kBrowserZoomLadder[i],
        greaterThan(kBrowserZoomLadder[i - 1]),
        reason: '档位必须单调递增，方向键才不会在原地打转',
      );
    }
  });

  test('逐档跳；两端返回 null，不回环到另一头', () {
    expect(nextBrowserZoom(1.0), 1.10);
    expect(previousBrowserZoom(1.0), 0.90);

    expect(nextBrowserZoom(kBrowserZoomMax), isNull);
    expect(previousBrowserZoom(kBrowserZoomMax), isNotNull);
    expect(previousBrowserZoom(kBrowserZoomMin), isNull);
    expect(nextBrowserZoom(kBrowserZoomMin), isNotNull);
  });

  test('浮点误差不会让一次点击跳两格', () {
    // `0.9` 经一次乘除常见 `0.8999999`；没有容差时"当前档"判定失败，
    // 表现为点一下直接跳到 1.25。
    expect(nextBrowserZoom(0.8999999), 1.0);
    expect(previousBrowserZoom(1.0000001), 0.9);
  });

  test('百分比文案按实际比例显示', () {
    expect(browserZoomLabel(1), '100%');
    expect(browserZoomLabel(1.10), '110%');
    expect(browserZoomLabel(0.67), '67%');
    expect(browserZoomLabel(5), '500%');
  });

  test('非 Apple 平台脚本：100% 清内联样式，其余写绝对百分比并夹住范围', () {
    expect(zoomScript(1), contains('removeProperty'));
    expect(zoomScript(1.5), contains("'150%'"));
    expect(zoomScript(9), contains("'500%'"), reason: '超过上限要夹住');
    expect(zoomScript(0.1), contains("'25%'"), reason: '低于下限也要夹住');
  });
}
