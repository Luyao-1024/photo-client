import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/ui/local_photo_image.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-viewer-zoom-');
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

  /// The scale the media stage's [InteractiveViewer] currently applies.
  double stageScale(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  testWidgets(
    'keyboard zoom drives the InteractiveViewer transform within [1, 8]',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 3);
      await mount(tester, gateway);
      await openViewer(tester, 'p0');

      // The chrome exposes an explicit zoom toolbar and percentage readout.
      expect(find.byKey(const ValueKey('viewer-zoom-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-zoom-out')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-zoom-reset')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // At fit scale the stage rests at 1.0.
      expect(stageScale(tester), closeTo(1, 1e-6));

      // The toolbar drives the same transform as the keyboard.
      await tester.tap(find.byKey(const ValueKey('viewer-zoom-in')));
      await tester.pump();
      expect(stageScale(tester), closeTo(1.25, 1e-6));
      expect(find.text('125%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('viewer-zoom-reset')));
      await tester.pump();
      expect(stageScale(tester), closeTo(1, 1e-6));

      // Zoom in via the =/+ key (both bindings use equal).
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(stageScale(tester), closeTo(1.25, 1e-6));
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(stageScale(tester), closeTo(1.5625, 1e-6));

      // Zoom out via the - key.
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.pump();
      expect(stageScale(tester), closeTo(1.25, 1e-6));

      // Reset via the 0 key.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(stageScale(tester), closeTo(1, 1e-6));

      // Lower bound: repeated - clamps at fit (1.0). InteractiveViewer never
      // lets a viewport-filling child scale below 1.0.
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.pump();
      }
      expect(stageScale(tester), closeTo(1, 1e-6));

      // Upper bound: repeated + clamps at 8.0.
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(stageScale(tester), closeTo(8, 1e-3));

      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      expect(stageScale(tester), closeTo(1, 1e-6));
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('immersive toggles with the button and F; I opens details', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await openViewer(tester, 'p0');
    expect(find.byKey(const ValueKey('viewer-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-immersive-exit')), findsNothing);

    // Enter immersive via the header button: header, filmstrip, and the
    // bottom-right nav pair fold away; only the exit control remains.
    await tester.tap(find.byKey(const ValueKey('viewer-immersive')));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-immersive-exit')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-close')), findsNothing);
    expect(find.byKey(const ValueKey('viewer-name')), findsNothing);
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsNothing);
    expect(find.byKey(const ValueKey('viewer-previous')), findsNothing);
    expect(find.byKey(const ValueKey('viewer-next')), findsNothing);
    // The media stage itself survives immersion.
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // Exit with the F key restores the chrome.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-immersive-exit')), findsNothing);

    // Enter with the F key, exit with the dedicated button.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-immersive-exit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-immersive-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-name')), findsOneWidget);

    // The I key opens the details panel (as in the original viewer) rather
    // than the legacy immersive toggle.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-details-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-immersive-exit')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-details-panel')), findsNothing);
    expect(find.byKey(const ValueKey('viewer-close')), findsOneWidget);

    // Escape leaves immersive first and only pops on a second press.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-close')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer')), findsNothing);

    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets(
    'rapid Right/Left bursts keep viewer-name, position counter, and the '
    'stage image in sync and reset the zoom anchor',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 6);
      await mount(tester, gateway);
      await openViewer(tester, 'p0');

      // Zoom first: switching photos must reset the transform.
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pumpAndSettle();
      expect(stageScale(tester), closeTo(1.5625, 1e-6));

      // Deterministic fast stepping (one pump per key, no full settle).
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('viewer-name'))).data,
        'Photo 3.png',
      );
      expect(find.text('4 / 6'), findsOneWidget);
      expect(stageScale(tester), closeTo(1, 1e-6));
      expect(stageImageMediaId(tester), 'p3');
      expect(
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).key,
        const ValueKey('viewer-image-p3-1'),
      );

      // Burst of Right keys dispatched back-to-back without pumping.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      _expectViewerConsistent(tester, find, total: 6);

      // Mixed Right/Left burst, again without intermediate pumps.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      _expectViewerConsistent(tester, find, total: 6);

      // No stale media widgets remain on the stage: exactly one stage image,
      // matching the displayed photo, and a single InteractiveViewer.
      expect(
        find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );
}

/// The media id currently wired into the media stage's [Image] provider.
String stageImageMediaId(WidgetTester tester) {
  final image = tester.widget<Image>(
    find.descendant(
      of: find.byType(InteractiveViewer),
      matching: find.byType(Image),
    ),
  );
  final provider = image.image is ResizeImage
      ? (image.image as ResizeImage).imageProvider
      : image.image;
  return (provider as LocalPhotoImage).mediaId;
}

/// Asserts that the viewer name, the "i / total" position counter, and the
/// rendered stage image provider all describe the same photo.
void _expectViewerConsistent(
  WidgetTester tester,
  CommonFinders find, {
  required int total,
}) {
  final name = tester
      .widget<Text>(find.byKey(const ValueKey('viewer-name')))
      .data!;
  final match = RegExp('^(\\d+) / $total\$')
      .firstMatch(tester.widget<Text>(find.textContaining('/ $total')).data!);
  expect(match, isNotNull, reason: 'position counter not found');
  final index = int.parse(match!.group(1)!) - 1;
  expect(name, 'Photo $index.png');
  expect(stageImageMediaId(tester), 'p$index');
  expect(
    tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).key,
    ValueKey('viewer-image-p$index-1'),
  );
}
