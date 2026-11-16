import 'dart:ui' show Size;

import 'package:jarvis_app/src/features/shell/narrow_tab_lens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一尺寸复用同一个滤镜实例', () {
    const size = Size(320, 61);
    final first = NarrowTabLens.filterFor(size);
    final second = NarrowTabLens.filterFor(size);

    expect(
      identical(first, second),
      isTrue,
      reason: '滤镜背后是原生对象，每帧新建会在滚动时反复分配',
    );
  });

  test('尺寸变化会换一个滤镜', () {
    final narrow = NarrowTabLens.filterFor(const Size(320, 61));
    final wide = NarrowTabLens.filterFor(const Size(372, 61));

    expect(identical(narrow, wide), isFalse);
  });

  test('倍率为 1 时退回纯模糊（平台不生效时的降级路径）', () {
    final filter = NarrowTabLens.filterFor(const Size(320, 61), scale: 1);

    // `ImageFilter.blur` 的实现类没有公开的 sigma getter，只能取运行时字段。
    final blur = filter as dynamic;
    expect(blur.sigmaX, kNavLensBlurSigma);
    expect(blur.sigmaY, kNavLensBlurSigma);
  });

  test('霜化量必须比磨砂版本轻，否则放大会被糊平', () {
    expect(kNavLensBlurSigma, lessThan(18));
    expect(kNavLensScale, greaterThan(1));
  });
}
