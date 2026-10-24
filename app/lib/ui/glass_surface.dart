import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' hide GlassTheme;

import 'glass_theme.dart';
import 'presentation_preferences.dart';

/// Material roles. Chrome is a floating surface over the page; reading keeps
/// text on a near-opaque panel.
enum GlassRole { chrome, raised, overlay, reading }

/// Reveal progress for glass chrome. The shader fades the backdrop through its
/// visibility uniform; this scope only carries the matching content fade,
/// applied below the glass layer so the backdrop pass stays outside any
/// ancestor [Opacity].
class GlassRevealScope extends InheritedWidget {
  const GlassRevealScope({
    required this.progress,
    required super.child,
    super.key,
  });

  final double progress;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassRevealScope>()?.progress;

  @override
  bool updateShouldNotify(GlassRevealScope oldWidget) =>
      progress != oldWidget.progress;
}

/// A translucent surface.
///
/// The rendering comes from `liquid_glass_widgets`, which draws the real
/// liquid glass pipeline: a refracting bevel and chromatic aberration over the live backdrop.
/// A directional native rim defines depth without an application-drawn outline.
class GlassSurface extends ConsumerWidget {
  static final _reportedLenses = <String>{};
  const GlassSurface({
    super.key,
    required this.child,
    this.live = false,
    this.radius = GlassTheme.panelRadius,
    this.role = GlassRole.chrome,
  });
  final Widget child;

  /// A focal control. It runs the full pipeline — the premium shader with its
  /// texture capture — instead of the lightweight one.
  final bool live;
  final double radius;
  final GlassRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final preferences = ref.watch(presentationProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reading = role == GlassRole.reading;
    final overlay = role == GlassRole.overlay;
    final raised = role == GlassRole.raised;
    final glass = GlassTheme.of(context);
    final nested =
        context
            .dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()
            ?.avoidsRefraction ??
        false;
    // High contrast is an accessibility limit, not a material style: the body
    // goes opaque and the refraction is dropped so text keeps its contrast.
    final opaque = media.highContrast;
    final base = reading ? .96 : (overlay ? .52 : (raised ? .18 : .22));
    final alpha = (base + (1 - 2 * preferences.transparency) * .10).clamp(
      reading ? .94 : (overlay ? .42 : .10),
      reading ? .98 : (overlay ? .62 : (raised ? .28 : .32)),
    );
    final flat = reading || opaque;
    final reveal = GlassRevealScope.maybeOf(context);
    // Start from the package's native-material example: paraxial folded lens,
    // independent frost and blur, and directional rim shading. A low blur
    // preserves the displaced backdrop rather than hiding it under frosting.
    final native = dark
        ? LiquidGlassSettings.ios27Dark
        : LiquidGlassSettings.ios27Light;
    final settings = native.copyWith(
      glassColor: glass.tint.withValues(alpha: opaque ? 1 : alpha),
      thickness: flat ? 0 : (live ? 42 : 32),
      refractiveIndex: flat ? 1 : (live ? 1.34 : 1.26),
      blur: flat ? 0 : (live ? .6 : 1.2),
      frost: flat ? 0 : (overlay ? 14 : 6),
      frostWeight: live ? .6 : 1,
      blurWeight: dark ? 1.4 : .8,
      chromaticAberration: flat ? 0 : (live ? .012 : .006),
      saturation: flat ? 1 : 1.35,
      lightAngle: -1.5707963267948966,
      lightIntensity: 0,
      fresnelStrength: 0,
      rimLight: flat ? 0 : .65,
      rimShade: flat ? 0 : 1,
      rimShadeEnds: 0,
      edgeAbsorption: flat ? 0 : .06,
      bodyShade: dark && !flat ? .18 : 0,
      shadowElevation: 0,
      shadow: const [],
    );
    final premium = !flat && !nested;
    final quality = flat
        ? GlassQuality.minimal
        : (premium ? GlassQuality.premium : GlassQuality.standard);
    // Standard has a hard-coded white perimeter. Premium uses its directional
    // native rim and needs the complete boundary to draw the folded lens.
    final overscan = premium ? 0.0 : 2.0;
    Widget background = GlassContainer(
      shape: LiquidRoundedSuperellipse(borderRadius: radius + overscan),
      settings: nested ? null : settings,
      quality: quality,
      useOwnLayer: !nested,
      child: const SizedBox.expand(),
    );
    if (premium && live) {
      // Keep fixed lenses on the full pipeline even in independently hosted
      // surfaces. No automatic tier or frost switching is allowed.
      final lens = background;
      background = GlassAdaptiveScope(
        minQuality: GlassQuality.premium,
        maxQuality: GlassQuality.premium,
        frostStep: false,
        allowStepUp: false,
        child: Builder(
          builder: (context) {
            final data = GlassAdaptiveScopeData.of(context);
            final report =
                '${role.name}/${data.effectiveQuality.name}/frost=${data.frostEnabled}';
            if (_reportedLenses.add(report)) debugPrint('GLASS_LENS $report');
            return lens;
          },
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: radius == 0 || reading || opaque
            ? const []
            : [
                BoxShadow(
                  color: glass.shadow,
                  blurRadius: overlay ? 32 : 16,
                  offset: Offset(0, overlay ? 12 : 4),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              left: -overscan,
              top: -overscan,
              right: -overscan,
              bottom: -overscan,
              child: background,
            ),
            // Keep the package's container contract even though its background
            // is a sibling (so the standard rim can be clipped independently).
            // Nested search/buttons use vibrancy, not another backdrop read.
            // Content fades below the glass layer; an opacity above it would
            // black out the backdrop pass during the reveal.
            InheritedLiquidGlass(
              settings: settings,
              quality: quality,
              avoidsRefraction: true,
              child: Material(
                type: MaterialType.transparency,
                // Keep this wrapper in place at every progress: inserting or
                // removing it remounts the content, which resets a contained
                // scrollable (the filmstrip) to offset zero.
                child: reveal == null
                    ? child
                    : Opacity(opacity: reveal.clamp(0.0, 1.0), child: child),
              ),
            ),
            if (opaque)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
