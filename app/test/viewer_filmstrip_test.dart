import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-viewer-strip-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  const tolerance = 2.5;

  Future<FakeLocalGateway> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    final gateway = FakeLocalGateway(imagePath: image, count: 30);
    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
    await tester.pumpAndSettle();
    return gateway;
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

  /// Horizontal distance between the current thumbnail and the strip centre.
  double offsetFromCenter(WidgetTester tester, String photoId) {
    final strip = tester.getRect(
      find.byKey(const ValueKey('viewer-filmstrip')),
    );
    final active = tester.getRect(
      find.byKey(ValueKey('viewer-strip-$photoId')),
    );
    return active.center.dx - strip.center.dx;
  }

  void expectCentered(WidgetTester tester, String photoId) {
    expect(
      offsetFromCenter(tester, photoId).abs(),
      lessThanOrEqualTo(tolerance),
      reason: 'the current thumbnail $photoId is not centred in the filmstrip',
    );
  }

  Future<void> waitForPosition(WidgetTester tester, String label) async {
    for (var i = 0; i < 10 && find.text(label).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the current filmstrip thumbnail is centred', (tester) async {
    final gateway = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('photo-p5')));
    await tester.pumpAndSettle();
    expect(find.text('6 / 30'), findsOneWidget);
    expectCentered(tester, 'p5');

    // Selecting a thumbnail from the strip keeps the same invariant.
    await tester.tap(find.byKey(const ValueKey('viewer-strip-p0')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pumpAndSettle();
    expect(find.text('1 / 30'), findsOneWidget);
    expectCentered(tester, 'p0');

    // The strip must already be centred on the first frame in which the new
    // photo becomes current, not only after a scroll animation settles.
    await tester.tap(find.byKey(const ValueKey('viewer-next')));
    await tester.pump();
    await waitForPosition(tester, '2 / 30');
    expect(find.text('2 / 30'), findsOneWidget);
    expectCentered(tester, 'p1');

    for (var index = 2; index <= 15; index += 1) {
      await tester.tap(find.byKey(const ValueKey('viewer-next')));
      await tester.pumpAndSettle();
      await waitForPosition(tester, '${index + 1} / 30');
      expect(find.text('${index + 1} / 30'), findsOneWidget);
    }
    expectCentered(tester, 'p15');

    await tester.tap(find.byKey(const ValueKey('viewer-strip-p18')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pumpAndSettle();
    expect(find.text('19 / 30'), findsOneWidget);
    expectCentered(tester, 'p18');

    for (var index = 19; index <= 29; index += 1) {
      await tester.tap(find.byKey(const ValueKey('viewer-next')));
      await tester.pumpAndSettle();
      await waitForPosition(tester, '${index + 1} / 30');
      expect(find.text('${index + 1} / 30'), findsOneWidget);
    }
    // The last photo must centre too, with trailing space instead of a clamp.
    expectCentered(tester, 'p29');

    await disposeApp(tester, gateway);
  });
}
