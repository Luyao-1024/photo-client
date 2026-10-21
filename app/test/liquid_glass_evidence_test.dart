// Renders the real glass material over a real photo backdrop and checks the
// material contract the product depends on.
//
// This is a headless check: it proves the roles, the alpha floors and the
// high-contrast rule, not the GPU result. The GPU result is proven on the
// real desktop and on Android by the isolated bench (see
// docs/verification/local-features/liquid-glass/report.json).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:photo_client/ui/glass_surface.dart';
import 'package:photo_client/ui/mode_selector.dart';
import 'package:photo_client/ui/photos_grid.dart';
import 'package:photo_client/ui/presentation_preferences.dart';

/// The photo grid the app shows, reused as the backdrop the glass samples.
File _backdrop() {
  final file = File(
    '${Directory.current.path}/../docs/verification/S02-S04/local-journey/01-grid.png',
  );
  if (!file.existsSync()) {
    throw StateError('the backdrop screenshot is missing: ${file.path}');
  }
  return file;
}

Widget _scene({
  required Brightness brightness,
  required String glassMode,
  required ImageProvider backdrop,
}) {
  return ProviderScope(
    overrides: [
      presentationProvider.overrideWith(() => _FixedModeController(glassMode)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(brightness),
      home: Stack(
        fit: StackFit.expand,
        children: [
          Image(image: backdrop, fit: BoxFit.cover),
          // The chrome the app floats over the grid.
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 240,
              child: GlassSurface(
                radius: 0,
                child: _Sidebar(brightness: brightness),
              ),
            ),
          ),
          // The focal control: the raised capsule with the full material.
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: ModeSelector(mode: GroupMode.month, onChanged: _noop),
            ),
          ),
          // A reading surface: text legibility over the same backdrop.
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GlassSurface(
                role: GlassRole.reading,
                radius: 18,
                child: const SizedBox(width: 260, child: _ReadingPanel()),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Pins the material mode so a frame always shows the same tier.
class _FixedModeController extends PresentationController {
  _FixedModeController(this.mode);
  final String mode;

  @override
  PresentationPreferences build() => PresentationPreferences(glassMode: mode);
}

void _noop(GroupMode _) {}

ThemeData _theme(Brightness brightness) => ThemeData(
  useMaterial3: true,
  brightness: brightness,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff4f8eff),
    brightness: brightness,
  ),
  scaffoldBackgroundColor: brightness == Brightness.dark
      ? const Color(0xff121721)
      : const Color(0xffeef1f6),
);

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final on = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          for (final (icon, label) in [
            (Icons.photo_outlined, '照片'),
            (Icons.album_outlined, '相册'),
            (Icons.favorite_outline, '收藏'),
            (Icons.movie_outlined, '视频'),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: on.withValues(alpha: .75)),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(fontSize: 13, color: on.withValues(alpha: .8)),
                  ),
                ],
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.settings_outlined,
                  size: 20,
                  color: on.withValues(alpha: .75),
                ),
                const SizedBox(width: 12),
                Text(
                  '设置',
                  style: TextStyle(fontSize: 13, color: on.withValues(alpha: .8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadingPanel extends StatelessWidget {
  const _ReadingPanel();

  @override
  Widget build(BuildContext context) {
    final on = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '详细信息',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: on.withValues(alpha: .92),
            ),
          ),
          const SizedBox(height: 12),
          for (final line in ['2026-10-21 17:20', '4032 × 3024 · HEIC', '4.2 MB'])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                line,
                style: TextStyle(fontSize: 12, color: on.withValues(alpha: .7)),
              ),
            ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets('the glass material over a photo backdrop', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final bytes = _backdrop().readAsBytesSync();
    await tester.pumpWidget(
      _scene(
        brightness: Brightness.dark,
        glassMode: 'full',
        backdrop: MemoryImage(bytes),
      ),
    );
    await tester.pumpAndSettle();

    final surfaces = tester.widgetList<GlassContainer>(
      find.byType(GlassContainer),
    );
    expect(surfaces.length, greaterThanOrEqualTo(3));
    for (final surface in surfaces) {
      final settings = surface.settings!;
      if (surface.quality == GlassQuality.minimal) {
        // A reading panel is a wall: the text has to stay legible.
        expect(settings.glassColor.a, greaterThanOrEqualTo(.94));
      } else {
        // Chrome and the raised capsule are mostly air.
        expect(settings.glassColor.a, lessThanOrEqualTo(.40));
        expect(settings.glassColor.a, greaterThanOrEqualTo(.12));
      }
    }

    // The raised capsule is the focal control and runs the full material.
    final capsule = tester.widget<GlassContainer>(
      find
          .descendant(
            of: find.byType(ModeSelector),
            matching: find.byType(GlassContainer),
          )
          .first,
    );
    expect(capsule.quality, GlassQuality.premium);
    expect(capsule.settings!.chromaticAberration, lessThanOrEqualTo(.004));
  });

  testWidgets('high contrast makes every surface opaque', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);

    final bytes = _backdrop().readAsBytesSync();
    await tester.pumpWidget(
      _scene(
        brightness: Brightness.dark,
        glassMode: 'full',
        backdrop: MemoryImage(bytes),
      ),
    );
    await tester.pumpAndSettle();

    for (final surface in tester.widgetList<GlassContainer>(
      find.byType(GlassContainer),
    )) {
      expect(surface.settings!.glassColor.a, 1);
      // An opaque body has nothing to refract, so it must not sample the
      // backdrop either.
      expect(surface.quality, GlassQuality.minimal);
    }
  });
}
