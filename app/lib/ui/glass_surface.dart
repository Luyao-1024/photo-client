import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation_preferences.dart';
import 'auto_glass_policy.dart';

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
enum GlassRole { chrome, raised, overlay, reading }

class GlassSurface extends ConsumerWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.live = false,
    this.enabled = true,
    this.radius = 20,
    this.role = GlassRole.chrome,
  });
  final Widget child;
  final bool live;
  final bool enabled;
  final double radius;
  final GlassRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final preferences = ref.watch(presentationProvider);
    final solid =
        !enabled || preferences.glassMode == 'plain' || media.highContrast;
    final reading = role == GlassRole.reading;
    final base = reading ? 0.96 : (dark ? 0.86 : .84);
    final alpha = (base + (1 - 2 * preferences.transparency) * .10).clamp(
      reading ? 0.94 : (dark ? 0.72 : .60),
      .98,
    );
    final reduced =
        preferences.glassMode == 'reduced' ||
        (preferences.glassMode == 'auto' && ref.watch(autoGlassProvider));
    final sigma = reduced ? 6.0 : 12.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = media.size.width * media.size.height;
        final boundedArea =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight
            ? constraints.maxWidth * constraints.maxHeight
            : double.infinity;
        final blur =
            live && !reading && !solid && area > 0 && boundedArea / area <= .20;
        final fill = dark ? const Color(0xff17202e) : Colors.white;
        final surface = DecoratedBox(
          decoration: BoxDecoration(
            color: fill.withValues(alpha: solid ? 1 : alpha),
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
                      fill.withValues(
                        alpha: (alpha + .04).clamp(reading ? 0.94 : 0.0, .98),
                      ),
                      fill.withValues(
                        alpha: (alpha - .04).clamp(
                          reading ? 0.94 : (dark ? 0.72 : .60),
                          .98,
                        ),
                      ),
                    ],
                  ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
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
                    filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: surface,
                  )
                : surface,
          ),
        );
      },
    );
  }
}
