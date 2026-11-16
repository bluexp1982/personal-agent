import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/features/preview/zoom_ladder.dart';

void main() {
  test('加一档只走一格，且不因为浮点误差跳两格', () {
    expect(nextZoomStep(1.0), 1.25);
    expect(nextZoomStep(1.03), 1.25);
    expect(nextZoomStep(1.25), 1.5, reason: '正好在档位上时不能再停在原地');
    expect(nextZoomStep(2.0), 2.5);
    expect(nextZoomStep(7.9), 8.0);
  });

  test('到顶不回环', () {
    expect(nextZoomStep(8.0), isNull);
    expect(nextZoomStep(9.5), isNull);
  });

  test('减一档只走一格，到底不回环', () {
    expect(previousZoomStep(1.03), 1.0);
    expect(previousZoomStep(1.25), 1.0);
    expect(previousZoomStep(2.0), 1.75);
    // 100% 以下还有两档：PDF 缩到半页能一次看两页。
    // 图片查看器会把它们裁到"适应窗口"，所以那边按到 100% 就停住。
    expect(previousZoomStep(1.0), 0.75);
    expect(previousZoomStep(0.75), 0.5);
    expect(previousZoomStep(0.5), isNull);
    expect(previousZoomStep(0.4), isNull);
  });

  test('百分比照实显示，不吸附到档位', () {
    expect(zoomPercentOf(1.0), 100);
    expect(zoomPercentOf(1.374), 137);
    expect(zoomPercentOf(2.5), 250);
    // 异常值兜底成 100：宁可按"适应窗口"显示，也不要出现 NaN%。
    expect(zoomPercentOf(double.nan), 100);
    expect(zoomPercentOf(0), 100);
  });

  test('pdfrx 停靠点 = fit × 梯度，并补齐库的上下限', () {
    final stops = zoomStopsFor(fit: 1.0, min: 0.5, max: 8.0);

    expect(stops.first, 0.5);
    expect(stops.last, 8.0);
    expect(stops, contains(1.0));
    expect(stops, contains(1.25));
    expect(stops, contains(2.5));
    expect(
      stops,
      orderedEquals(List<double>.of(stops)..sort()),
      reason: 'pdfrx 要求升序',
    );
    expect(stops.toSet().length, stops.length, reason: '不能有重复停靠点');
  });

  test('fit 较大时（扫描件铺满宽度）也不会重复或超上限', () {
    final stops = zoomStopsFor(fit: 2.39, min: 0.5, max: 8.0);

    expect(stops.first, 0.5);
    expect(stops.last, 8.0);
    expect(stops, contains(closeTo(2.39, 1e-9)));
    // 2.39 × 8 = 19.12 超过库上限，必须被裁掉，只留 8。
    expect(stops.where((z) => z > 8.0), isEmpty);
  });

  test('参数异常时给出至少一个可用停靠点', () {
    final stops = zoomStopsFor(fit: 0, min: 0, max: 8);
    expect(stops, isNotEmpty);
    expect(stops.last, 8.0);
  });

  test('停靠点委托是值相等：build 重建不会让文档反复打开', () {
    expect(const LadderZoomStepsProvider(), const LadderZoomStepsProvider());
    expect(
      const LadderZoomStepsProvider().hashCode,
      const LadderZoomStepsProvider().hashCode,
    );
  });
}
