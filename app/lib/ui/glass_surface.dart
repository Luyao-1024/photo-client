import 'dart:ui';

import 'package:flutter/material.dart';

ThemeData photoTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff4f8eff),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff121721)
        : const Color(0xffeef1f6),
    visualDensity: VisualDensity.standard,
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
  );
}

/// Chrome is static. The single raised toolbar can opt into clipped real blur.
/// Short windows fall back to static material to preserve the 20% area budget.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.live = false,
    this.enabled = true,
    this.radius = 20,
  });
  final Widget child;
  final bool live;
  final bool enabled;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final solid = !enabled || media.highContrast || media.disableAnimations;
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = media.size.width * media.size.height;
        final boundedArea =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight
            ? constraints.maxWidth * constraints.maxHeight
            : double.infinity;
        final blur = live && !solid && area > 0 && boundedArea / area <= .20;
        final fill = dark ? const Color(0xff17202e) : Colors.white;
        final surface = DecoratedBox(
          decoration: BoxDecoration(
            color: fill.withValues(
              alpha: solid
                  ? 1
                  : dark
                  ? .86
                  : .84,
            ),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: media.highContrast
                  ? Theme.of(context).colorScheme.outline
                  : Colors.white.withValues(alpha: dark ? .16 : .70),
              width: media.highContrast ? 2 : 1,
            ),
            gradient: solid
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      fill.withValues(alpha: dark ? .88 : .90),
                      fill.withValues(alpha: dark ? .78 : .72),
                    ],
                  ),
          ),
          child: child,
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? .12 : .05),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: blur
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: surface,
                  )
                : surface,
          ),
        );
      },
    );
  }
}
