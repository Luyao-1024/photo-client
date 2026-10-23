import 'dart:math' as math;
import 'dart:ui';

/// Geometry for one filmstrip query. Every media gets the same square tile, so
/// a preview never grows with the source aspect ratio or a late dimension.
class ViewerFilmstripLayout {
  ViewerFilmstripLayout({
    required this.count,
    required this.height,
    this.gap = defaultGap,
  });

  static const defaultGap = 12.0;
  static const activeScale = 1.12;
  final int count;
  final double height;
  final double gap;

  double get _extent => height + gap;

  Size sizeAt(int index) => Size.square(height);

  double extentAt(int index) => _extent;

  double centerAt(int index) => index * _extent + _extent / 2;

  double leadingInset(double viewport) =>
      count == 0 ? 16 : math.max(16, (viewport - _extent) / 2);

  double trailingInset(double viewport) => leadingInset(viewport);

  double centeredOffset(int index, double viewport) =>
      leadingInset(viewport) + centerAt(index) - viewport / 2;

  /// Item containing a content offset; padding is excluded from this offset.
  int indexAt(double offset) {
    if (count == 0) return 0;
    if (offset <= 0) return 0;
    final index = offset / _extent;
    if (!index.isFinite) return count - 1;
    return index.floor().clamp(0, count - 1);
  }
}
