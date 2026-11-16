import 'package:jarvis_app/src/core/ui/shell_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 解析按钮样式里的形状：`shape` 是按状态给的，这里取默认态。
RoundedRectangleBorder _shapeOf(ButtonStyle style) {
  final shape = style.shape?.resolve(<WidgetState>{});
  expect(shape, isA<RoundedRectangleBorder>());
  return shape! as RoundedRectangleBorder;
}

/// 圆角方形的半径。只取左上角作代表：四角用的是同一个 `Radius.circular`。
double _radiusOf(ButtonStyle style) {
  final radius = _shapeOf(style).borderRadius
      .resolve(TextDirection.ltr)
      .topLeft;
  return radius.x;
}

void main() {
  test('栏头图标按钮的悬停底是 8dp 圆角方形，不是正圆', () {
    final style = shellIconButtonStyle(minimumSize: const Size.square(24));

    expect(_radiusOf(style), kShellIconButtonRadius);
    // 正圆（StadiumBorder）在小方块里就是圆形浮层，这里必须排除掉。
    expect(_shapeOf(style), isNot(isA<StadiumBorder>()));

    // 尺寸与紧凑度保持原样：改形状不该顺带把按钮改大或加内边距。
    expect(style.minimumSize?.resolve(<WidgetState>{}), const Size.square(24));
    expect(style.padding?.resolve(<WidgetState>{}), EdgeInsets.zero);
    expect(style.tapTargetSize, MaterialTapTargetSize.shrinkWrap);
  });

  test('裸按钮用的形状补丁只改轮廓，不碰尺寸', () {
    final style = shellIconButtonShape();

    expect(_radiusOf(style), kShellIconButtonRadius);
    // 三个尺寸相关字段都保持 null，交给主题/调用方，栏头「…」才不会缩水。
    expect(style.minimumSize, isNull);
    expect(style.padding, isNull);
    expect(style.tapTargetSize, isNull);
    // 颜色也要留给主题：悬停灰、禁用态由 ColorScheme 决定。
    expect(style.overlayColor, isNull);
    expect(style.foregroundColor, isNull);
  });

  test('小号命中区可以配更小的圆角', () {
    // 右栏标签上的关闭叉：16 见方的槽位，8 的圆角会接近正圆，改用 5。
    final style = shellIconButtonStyle(
      minimumSize: const Size.square(16),
      radius: 5,
    );

    expect(_radiusOf(style), 5);
    expect(style.minimumSize?.resolve(<WidgetState>{}), const Size.square(16));
    // 默认值不受影响：其他地方仍是 8。
    expect(_radiusOf(shellIconButtonShape()), kShellIconButtonRadius);
  });
}
