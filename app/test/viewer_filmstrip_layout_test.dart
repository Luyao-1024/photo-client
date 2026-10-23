import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/ui/viewer_filmstrip_layout.dart';

LocalPhoto photo(int width, int height, {int orientation = 1}) => LocalPhoto(
  id: 'fixture',
  path: 'fixture.png',
  name: 'fixture.png',
  parent: 'fixture',
  sizeBytes: 1,
  modifiedMs: 0,
  contentVersion: 1,
  favorite: false,
  width: width,
  height: height,
  orientation: orientation,
);

void main() {
  for (final height in [48.0, 60.0]) {
    test('full photo proportions and rotation at thumbnail height $height', () {
      final layout = ViewerFilmstripLayout(count: 3, height: height);
      final landscape = layout.sizeFor(photo(400, 300));
      final portrait = layout.sizeFor(photo(300, 400));
      final rotated = layout.sizeFor(photo(400, 300, orientation: 6));
      expect(landscape.width / landscape.height, closeTo(4 / 3, .0001));
      expect(portrait.width / portrait.height, closeTo(3 / 4, .0001));
      expect(rotated, portrait);
      expect(landscape.height, height);
      expect(portrait.height, height);
      final panorama = layout.sizeFor(photo(12000, 1000));
      expect(panorama.width / panorama.height, 12);
      expect(panorama.width, lessThanOrEqualTo(height * 3));
    });

    test('mixed widths centre first, middle and last at height $height', () {
      final layout = ViewerFilmstripLayout(count: 3, height: height);
      layout.update(0, photo(300, 400));
      layout.update(1, photo(1600, 900));
      layout.update(2, photo(400, 300));
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

  test(
    'late dimensions update offsets without losing measured page widths',
    () {
      final layout = ViewerFilmstripLayout(count: 1000, height: 48);
      final before = layout.centerAt(50);
      layout.update(0, photo(1600, 900));
      layout.update(50, photo(300, 400));
      expect(layout.centerAt(50), greaterThan(before));
      final resolved = layout.centerAt(50);
      final revision = layout.revision;
      // Re-admitting an unchanged page must not move its cached allocation.
      layout.update(50, photo(300, 400));
      expect(layout.centerAt(50), resolved);
      expect(layout.revision, revision);
      expect(layout.extentAt(50), greaterThanOrEqualTo(48));
      expect(layout.indexAt(layout.centerAt(50)), 50);
      expect(layout.indexAt(-100), 0);
      expect(layout.indexAt(double.infinity), 999);
    },
  );

  test('missing dimensions and an empty library remain safe', () {
    final layout = ViewerFilmstripLayout(count: 1, height: 48);
    expect(layout.sizeFor(photo(0, 0)), const Size(48, 48));
    final empty = ViewerFilmstripLayout(count: 0, height: 48);
    expect(empty.indexAt(0), 0);
    expect(empty.leadingInset(360), 16);
    expect(empty.trailingInset(360), 16);
  });
}
