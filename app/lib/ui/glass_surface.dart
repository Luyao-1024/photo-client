import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' hide GlassTheme;

import 'glass_theme.dart';
import 'presentation_preferences.dart';

/// Material roles. Chrome is a floating surface over the page; reading keeps
/// text on a near-opaque panel.
enum GlassRole { chrome, raised, overlay, reading }

/// A translucent surface.
///
/// The rendering comes from `liquid_glass_widgets`, which draws the real
/// liquid glass pipeline: a refracting bevel, a specular rim, Fresnel
/// lighting and chromatic aberration over the live backdrop.
class GlassSurface extends ConsumerWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.live = false,
    this.radius = 20,
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
    // High contrast is an accessibility limit, not a material style: the body
    // goes opaque and the refraction is dropped so text keeps its contrast.
    final opaque = media.highContrast;
    // A liquid material is mostly air. The body only tints what is behind it;
    // the bevel, the rim and the refraction do the reading. A body this
    // opaque turns the surface into a flat panel with a lit border, which is
    // the opposite of the effect.
    final base = reading ? .96 : (overlay ? .88 : (raised ? .40 : .25));
    final alpha = (base + (1 - 2 * preferences.transparency) * .10).clamp(
      reading ? .94 : (overlay ? .86 : (raised ? .32 : .12)),
      reading ? .98 : (overlay ? .94 : (raised ? .50 : .40)),
    );
    final fill = glass.tint;
    final settings = LiquidGlassSettings(
      glassColor: fill.withValues(alpha: opaque ? 1 : alpha),
      // A reading panel is a wall, not a lens: no bevel, no refraction.
      // A deep bevel plus a wide blur costs resolution and pushes the
      // displacement sampler past the captured backdrop, which shows up as a
      // jagged ring at the edge. A shallow bevel with a tight blur keeps the
      // refraction and keeps the edge clean.
      thickness: reading ? 0 : (live ? 16 : 12),
      blur: reading ? 0 : (overlay ? 6 : 2),
      frost: 0,
      chromaticAberration: live ? 0.004 : 0,
      saturation: reading ? 1 : 1.4,
      lightAngle: -1.2,
      lightIntensity: dark ? 0.26 : 0.3,
      // A uniform bright rim reads as a drawn border, not as glass. The depth
      // comes from a dark band just inside the edge, with only a restrained
      // highlight on top of it.
      fresnelStrength: reading ? 0 : 0.4,
      rimLight: reading ? 0.2 : 0.35,
      rimShade: reading ? 0 : 0.9,
      rimShadeEnds: 0,
      edgeAbsorption: reading ? 0 : 0.035,
      bodyShade: dark ? 0.2 : 0,
      shadowElevation: reading ? 0 : 1,
    );
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
      child: GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        settings: settings,
        // Reading panels stay on the shader-free path: a near-opaque body makes
        // the backdrop invisible, so sampling it would only cost frames. The
        // same goes for high contrast, where the body is fully opaque.
        quality: reading || opaque
            ? GlassQuality.minimal
            : (live ? GlassQuality.premium : GlassQuality.standard),
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: opaque
                  ? Theme.of(context).colorScheme.outline
                  : glass.edge,
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}
