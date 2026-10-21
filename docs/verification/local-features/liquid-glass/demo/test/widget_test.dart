// A structural check of the bench, not a pixel check.
//
// The glass shader only runs on a real GPU, so the pixels are proven by the
// archived screenshots in ../report.json. What this test can prove is the
// wiring: every tier renders as its own glass surface, on the tier the app
// maps that role onto.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glasslab/main.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  testWidgets('the bench shows one capsule per material tier', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const BenchApp(backdrop: ColoredBox(color: Color(0xff203040))),
    );
    await tester.pump();

    final capsules = tester.widgetList<GlassBenchCapsule>(
      find.byType(GlassBenchCapsule),
    );
    expect(capsules.length, benchTiers.length);

    final surfaces = tester.widgetList<GlassContainer>(
      find.byType(GlassContainer),
    );
    expect(surfaces.length, greaterThanOrEqualTo(benchTiers.length));

    for (final tier in benchTiers) {
      final capsule = tester.widget<GlassBenchCapsule>(
        find.widgetWithText(GlassBenchCapsule, tier.capsule),
      );
      expect(capsule.quality, tier.quality);
      expect(capsule.settings, tier.settings);
    }
  });

  testWidgets('the reading tier is opaque, the other tiers are mostly air', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const BenchApp(backdrop: ColoredBox(color: Color(0xff203040))),
    );
    await tester.pump();

    for (final tier in benchTiers) {
      if (tier.quality == GlassQuality.minimal) {
        expect(tier.settings.glassColor.a, greaterThanOrEqualTo(.94));
      } else {
        expect(tier.settings.glassColor.a, lessThanOrEqualTo(.40));
        expect(tier.settings.glassColor.a, greaterThanOrEqualTo(.12));
      }
    }
  });
}
