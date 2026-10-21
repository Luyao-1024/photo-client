import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared material and interaction tokens. Content tiles never own a filter.
@immutable
class GlassTheme extends ThemeExtension<GlassTheme> {
  const GlassTheme({
    required this.tint,
    required this.edge,
    required this.inset,
    required this.selection,
    required this.shadow,
  });

  factory GlassTheme.fromScheme(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return GlassTheme(
      tint: dark ? const Color(0xff181818) : Colors.white,
      edge: scheme.onSurface.withValues(alpha: dark ? .06 : .07),
      inset: (dark ? Colors.white : scheme.primary).withValues(
        alpha: dark ? .045 : .035,
      ),
      selection: scheme.primary.withValues(alpha: dark ? .20 : .10),
      shadow: Colors.black.withValues(alpha: dark ? .22 : .07),
    );
  }

  static const photoRadius = 8.0;
  static const controlRadius = 12.0;
  static const panelRadius = 18.0;
  static const dialogRadius = 24.0;
  static const windowRadius = 24.0;

  final Color tint, edge, inset, selection, shadow;

  static GlassTheme of(BuildContext context) =>
      Theme.of(context).extension<GlassTheme>() ??
      GlassTheme.fromScheme(Theme.of(context).colorScheme);

  @override
  GlassTheme copyWith({
    Color? tint,
    Color? edge,
    Color? inset,
    Color? selection,
    Color? shadow,
  }) => GlassTheme(
    tint: tint ?? this.tint,
    edge: edge ?? this.edge,
    inset: inset ?? this.inset,
    selection: selection ?? this.selection,
    shadow: shadow ?? this.shadow,
  );

  @override
  GlassTheme lerp(GlassTheme? other, double t) => other == null
      ? this
      : GlassTheme(
          tint: Color.lerp(tint, other.tint, t)!,
          edge: Color.lerp(edge, other.edge, t)!,
          inset: Color.lerp(inset, other.inset, t)!,
          selection: Color.lerp(selection, other.selection, t)!,
          shadow: Color.lerp(shadow, other.shadow, t)!,
        );
}

/// The album photo fills the window under a neutral light or dark frost.
/// Only the low-resolution still image is blurred, never the whole scene.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({
    super.key,
    required this.child,
    this.image,
    this.blurSigma = 18,
  });
  final Widget child;
  final ImageProvider? image;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = theme.scaffoldBackgroundColor;
    return ColoredBox(
      color: base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null && !MediaQuery.highContrastOf(context))
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _BackdropPhoto(
                          image: image!,
                          blurSigma: blurSigma,
                          animate: !MediaQuery.disableAnimationsOf(context),
                        ),
                        ColoredBox(
                          color: (dark ? Colors.black : Colors.white)
                              .withValues(alpha: dark ? .56 : .72),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// Keep the outgoing photo fully opaque while the incoming photo fades over
/// it. Fading both out/in would expose the neutral base halfway through.
/// Rapid changes queue only the newest target; at most two images are painted.
class _BackdropPhoto extends StatefulWidget {
  const _BackdropPhoto({
    required this.image,
    required this.animate,
    required this.blurSigma,
  });
  final ImageProvider image;
  final bool animate;
  final double blurSigma;

  @override
  State<_BackdropPhoto> createState() => _BackdropPhotoState();
}

class _BackdropPhotoState extends State<_BackdropPhoto>
    with SingleTickerProviderStateMixin {
  late ImageProvider _current = widget.image;
  ImageProvider? _previous, _queued;
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  )..addStatusListener(_finished);
  late final _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  void _finished(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _previous = null;
      final next = _queued;
      _queued = null;
      if (next != null && next != _current) _transition(next);
    });
  }

  void _transition(ImageProvider image) {
    _previous = _current;
    _current = image;
    _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(_BackdropPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate) {
      _controller.stop();
      _previous = _queued = null;
      _current = widget.image;
      _controller.value = 1;
    } else if (_controller.isAnimating) {
      _queued = widget.image == _current ? null : widget.image;
    } else if (widget.image != _current) {
      _transition(widget.image);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  Widget _photo(ImageProvider image) => RepaintBoundary(
    child: ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: widget.blurSigma,
        sigmaY: widget.blurSigma,
        tileMode: TileMode.clamp,
      ),
      child: Image(
        image: image,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, error, stack) => const SizedBox.shrink(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_previous != null) _photo(_previous!),
      FadeTransition(opacity: _fade, child: _photo(_current)),
    ],
  );
}

/// Preference groups share their parent's material instead of adding shaders.
class GlassSection extends StatelessWidget {
  const GlassSection({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = GlassTheme.of(context);
    return Material(
      color: glass.inset,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
