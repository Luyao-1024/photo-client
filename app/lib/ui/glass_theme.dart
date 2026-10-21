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
      tint: dark ? const Color(0xff17202e) : Colors.white,
      edge: Colors.white.withValues(alpha: dark ? .14 : .70),
      inset: (dark ? Colors.white : scheme.primary).withValues(
        alpha: dark ? .045 : .035,
      ),
      selection: scheme.primary.withValues(alpha: dark ? .20 : .10),
      shadow: Colors.black.withValues(alpha: dark ? .22 : .07),
    );
  }

  static const controlRadius = 12.0;
  static const panelRadius = 20.0;
  static const dialogRadius = 24.0;

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

/// A quiet, static backdrop gives the window chrome a common material context.
/// It creates no animation, image sampling or backdrop filters.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [
              theme.colorScheme.primary.withValues(alpha: dark ? .10 : .09),
              theme.colorScheme.primary.withValues(alpha: 0),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
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
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
