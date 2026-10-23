import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/viewer_filmstrip_layout.dart';

void main() {
  for (final height in [48.0, 60.0]) {
    test('every thumbnail is one square tile at height $height', () {
      final layout = ViewerFilmstripLayout(count: 3, height: height);
      for (var i = 0; i < layout.count; i++) {
        expect(layout.sizeAt(i), Size.square(height));
        expect(layout.extentAt(i), height + ViewerFilmstripLayout.defaultGap);
      }
      final compact = ViewerFilmstripLayout(count: 3, height: height, gap: 8);
      expect(compact.extentAt(0), height + 8);
    });

    test('uniform tiles centre first, middle and last at height $height', () {
      final layout = ViewerFilmstripLayout(count: 3, height: height);
      const viewport = 360.0;
      for (var i = 0; i < layout.count; i++) {
        final offset = layout.centeredOffset(i, viewport);
        expect(
          layout.leadingInset(viewport) + layout.centerAt(i) - offset,
          closeTo(viewport / 2, .001),
        );
      }
      expect(layout.centeredOffset(0, viewport), 0);
      final last = layout.count - 1;
      final contentWidth = layout.centerAt(last) + layout.extentAt(last) / 2;
      final maxScroll =
          layout.leadingInset(viewport) +
          contentWidth +
          layout.trailingInset(viewport) -
          viewport;
      expect(layout.centeredOffset(last, viewport), closeTo(maxScroll, .001));
    });
  }

  test('index lookup clamps to the uniform range', () {
    final layout = ViewerFilmstripLayout(count: 1000, height: 48);
    expect(layout.extentAt(50), 60);
    expect(layout.indexAt(layout.centerAt(50)), 50);
    expect(layout.indexAt(-100), 0);
    expect(layout.indexAt(double.infinity), 999);
  });

  test('an empty library remains safe', () {
    final empty = ViewerFilmstripLayout(count: 0, height: 48);
    expect(empty.indexAt(0), 0);
    expect(empty.leadingInset(360), 16);
    expect(empty.trailingInset(360), 16);
  });
}
