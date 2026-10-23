import 'dart:math' as math;
import 'dart:ui';

import '../services/local_library_gateway.dart';

/// Stable thumbnail widths for one query. Keep resolved sizes when a page is
/// evicted so browsing a long strip cannot move previously measured items.
class ViewerFilmstripLayout {
  ViewerFilmstripLayout({required this.count, required this.height})
    : _sizes = List.filled(count, Size.square(height)),
      _offsets = List.filled(count + 1, 0);

  static const gap = 12.0;
  static const activeScale = 1.12;
  final int count;
  final double height;
  final List<Size> _sizes;
  final List<double> _offsets;
  int _dirtyFrom = 0;
  int revision = 0;

  Size sizeAt(int index) => _sizes[index];
  double extentAt(int index) => math.max(48, _sizes[index].width) + gap;

  Size sizeFor(LocalPhoto photo) {
    final width = photo.width, sourceHeight = photo.height;
    if (width == null ||
        sourceHeight == null ||
        width <= 0 ||
        sourceHeight <= 0) {
      return Size.square(height);
    }
    final ratio = photo.orientation >= 5
        ? sourceHeight / width
        : width / sourceHeight;
    // Extreme panoramas remain complete, but must not consume the whole strip.
    final displayWidth = math.min(height * ratio, height * 3);
    return Size(displayWidth, displayWidth / ratio);
  }

  void update(int index, LocalPhoto photo) {
    if (index < 0 || index >= count) return;
    final size = sizeFor(photo);
    if (_sizes[index] == size) return;
    _sizes[index] = size;
    _dirtyFrom = math.min(_dirtyFrom, index);
    revision++;
  }

  void _measure() {
    for (var index = _dirtyFrom; index < count; index++) {
      _offsets[index + 1] = _offsets[index] + extentAt(index);
    }
    _dirtyFrom = count;
  }

  double centerAt(int index) {
    _measure();
    return _offsets[index] + extentAt(index) / 2;
  }

  double leadingInset(double viewport) =>
      count == 0 ? 16 : math.max(16, (viewport - extentAt(0)) / 2);
  double trailingInset(double viewport) =>
      count == 0 ? 16 : math.max(16, (viewport - extentAt(count - 1)) / 2);

  double centeredOffset(int index, double viewport) =>
      leadingInset(viewport) + centerAt(index) - viewport / 2;

  /// Item containing a content offset; padding is excluded from this offset.
  int indexAt(double offset) {
    if (count == 0) return 0;
    _measure();
    var low = 0, high = count;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_offsets[middle + 1] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low.clamp(0, count - 1);
  }
}
