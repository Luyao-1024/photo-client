import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/thumbnail_pipeline.dart';
import 'package:photo_client/ui/local_photo_image.dart';
import 'package:photo_client/ui/photo_theme.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-viewer-fill-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  Future<void> mount(WidgetTester tester, FakeLocalGateway gateway) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
    await tester.pumpAndSettle();
  }

  Future<void> disposeApp(WidgetTester tester, FakeLocalGateway gateway) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await gateway.changes.close();
    await gateway.events.close();
  }

  Future<void> openViewer(WidgetTester tester, String photoId) async {
    await tester.tap(find.byKey(ValueKey('photo-$photoId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
  }

  testWidgets(
    'letterbox gaps get a blurred cover fill behind a framed original',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 2);
      gateway.photos[0] = gateway.photo(0, width: 2000, height: 1000);
      gateway.photos[1] = gateway.photo(1, width: 1000, height: 2000);
      await mount(tester, gateway);
      await openViewer(tester, 'p0');

      final viewport = tester.getRect(find.byType(InteractiveViewer));
      final wide = tester.getRect(
        find.byKey(const ValueKey('viewer-photo-frame')),
      );
      // The wide photo leaves top/bottom gaps and spans the full width.
      expect(wide.width, closeTo(viewport.width, 1));
      expect(wide.height, closeTo(viewport.width / 2, 1));
      expect(wide.height, lessThan(viewport.height));
      expect(wide.center.dx, closeTo(viewport.center.dx, .5));
      expect(wide.center.dy, closeTo(viewport.center.dy, .5));

      // The gap fill is a full-viewport cover crop outside the zoom surface.
      final fill = tester.widget<Image>(
        find.byKey(const ValueKey('viewer-photo-fill-image')),
      );
      expect(fill.fit, BoxFit.cover);
      expect(
        find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byKey(const ValueKey('viewer-photo-fill-image')),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('viewer-photo-fill-blur')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('viewer-photo-fill-scrim')),
        findsOneWidget,
      );
      // A visible hairline keeps the untouched original's edge unambiguous.
      final frame = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('viewer-photo-frame')),
      );
      final decoration = frame.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      expect(decoration.border!.top.color.a, greaterThan(0));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.pumpAndSettle();

      // The tall photo flips the gaps to the left/right; the fill follows the
      // current photo instead of leaving the previous backdrop behind.
      final tall = tester.getRect(
        find.byKey(const ValueKey('viewer-photo-frame')),
      );
      expect(tall.height, closeTo(viewport.height, 1));
      expect(tall.width, closeTo(viewport.height / 2, 1));
      expect(tall.width, lessThan(viewport.width));
      expect(fillMediaId(tester), 'p1');
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets(
    'left/right navigation cross-fades the media and its blurred fill',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 2);
      gateway.photos[0] = gateway.photo(0, width: 2000, height: 1000);
      gateway.photos[1] = gateway.photo(1, width: 1000, height: 2000);
      await mount(tester, gateway);
      await openViewer(tester, 'p0');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (find
            .byKey(const ValueKey('viewer-stage-p1-1'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      // The outgoing stage stays mounted while the incoming photo and its
      // blurred backdrop fade over the top.
      expect(find.byKey(const ValueKey('viewer-stage-p0-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-stage-p1-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewer-photo-fill-image')),
        findsNWidgets(2),
      );

      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-stage-p0-1')), findsNothing);
      expect(find.byKey(const ValueKey('viewer-stage-p1-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewer-photo-fill-image')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('the cached fill placeholder is blurred with the backdrop', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    gateway.photos[0] = gateway.photo(0, width: 2000, height: 1000);
    ThumbnailPool.forGateway(gateway)
        .rememberCached(gateway.photos[0], 512, image);
    await mount(tester, gateway);
    await openViewer(tester, 'p0');

    final placeholder = find.byKey(
      const ValueKey('viewer-photo-fill-placeholder'),
    );
    expect(placeholder, findsOneWidget);
    // The thumbnail must blur with the backdrop; a sharp placeholder flashes
    // a clear fill before the blurred original paints after a swipe.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('viewer-photo-fill-blur')),
        matching: placeholder,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('the fill scrim and hairline follow the app light/dark theme', (
    tester,
  ) async {
    final light = photoTheme(Brightness.light).colorScheme;
    final dark = photoTheme(Brightness.dark).colorScheme;

    Color scrimColor(WidgetTester tester) => tester
        .widget<ColoredBox>(
          find.byKey(const ValueKey('viewer-photo-fill-scrim')),
        )
        .color;
    Color borderColor(WidgetTester tester) =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('viewer-photo-frame')),
                    )
                    .decoration
                as BoxDecoration)
            .border!
            .top
            .color;

    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    gateway.photos[0] = gateway.photo(0, width: 2000, height: 1000);
    await mount(tester, gateway);
    await openViewer(tester, 'p0');
    expect(scrimColor(tester), light.surface.withValues(alpha: .62));
    expect(borderColor(tester), light.onSurface.withValues(alpha: .30));
    await disposeApp(tester, gateway);

    // A dark system theme resolves to the dark scrim and hairline.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final darkGateway = FakeLocalGateway(imagePath: image, count: 1);
    darkGateway.photos[0] = darkGateway.photo(0, width: 2000, height: 1000);
    await mount(tester, darkGateway);
    await openViewer(tester, 'p0');
    expect(scrimColor(tester), dark.surface.withValues(alpha: .58));
    expect(borderColor(tester), dark.onSurface.withValues(alpha: .34));
    expect(tester.takeException(), isNull);
    await disposeApp(tester, darkGateway);
  });
}

String fillMediaId(WidgetTester tester) {
  final image = tester.widget<Image>(
    find.byKey(const ValueKey('viewer-photo-fill-image')),
  );
  final provider = image.image is ResizeImage
      ? (image.image as ResizeImage).imageProvider
      : image.image;
  return (provider as LocalPhotoImage).mediaId;
}
