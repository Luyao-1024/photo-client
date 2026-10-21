import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/ui/local_library_controller.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-responsive-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

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

  void expectVisibleAndSized(WidgetTester tester, String key) {
    final finder = find.byKey(ValueKey(key));
    expect(finder, findsOneWidget, reason: '$key missing');
    final rect = tester.getRect(finder);
    expect(rect.isFinite, isTrue, reason: '$key has no finite rect');
    expect(rect.width, greaterThanOrEqualTo(24), reason: '$key too narrow');
    expect(rect.height, greaterThanOrEqualTo(24), reason: '$key too short');
  }

  for (final size in [
    const Size(390, 844),
    const Size(800, 600),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'library → viewer → favorite → back → favorite filter works at '
      '${size.width.toInt()}x${size.height.toInt()} and hover changes nothing',
      (tester) async {
        final gateway = FakeLocalGateway(imagePath: image, count: 3);
        final picker = FakePicker();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.localeTestValue = const Locale('en');
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearLocaleTestValue();
        });
        await tester.pumpWidget(
          PhotoClientApp(gateway: gateway, sourcePicker: picker),
        );
        await tester.pumpAndSettle();

        // Grid and key library controls are visible and tappable.
        expectVisibleAndSized(tester, 'sidebar-favorites');
        expectVisibleAndSized(tester, 'library-search');
        expectVisibleAndSized(tester, 'photo-p0');

        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const ValueKey('local-photo-grid'))),
        );
        final listCallsBeforeHover = gateway.listCalls;

        // Hovering with a mouse must not change album/filter state.
        final mouse = await tester.createGesture(
          pointer: 10,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(
          location: tester.getCenter(find.byKey(const ValueKey('photo-p0'))),
        );
        await tester.pump();
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('sidebar-favorites'))),
        );
        await tester.pump();
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('sidebar-settings'))),
        );
        await tester.pump();
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('library-search'))),
        );
        await tester.pumpAndSettle();
        await mouse.removePointer();

        final hoveredState = container.read(localLibraryProvider);
        expect(hoveredState.folder, isNull);
        expect(hoveredState.favoritesOnly, isFalse);
        expect(hoveredState.search, isEmpty);
        expect(gateway.listCalls, listCallsBeforeHover);
        expect(gateway.scans, 0);

        // Open the viewer from the grid.
        await tester.tap(find.byKey(const ValueKey('photo-p0')));
        await tester.pumpAndSettle();
        expectVisibleAndSized(tester, 'viewer');
        expectVisibleAndSized(tester, 'viewer-favorite');
        expectVisibleAndSized(tester, 'viewer-close');
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('viewer-name'))).data,
          'Photo 0.png',
        );

        // Favorite from the viewer.
        await tester.tap(find.byKey(const ValueKey('viewer-favorite')));
        await tester.pumpAndSettle();
        expect(gateway.favorites, 1);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('viewer-favorite')))
              .isSelected,
          isTrue,
        );

        // Back to the grid.
        await tester.tap(find.byKey(const ValueKey('viewer-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('viewer')), findsNothing);
        expectVisibleAndSized(tester, 'photo-p0');
        expectVisibleAndSized(tester, 'photo-p1');

        // Favorites destination in the sidebar shows only the favorited photo.
        await tester.tap(find.byKey(const ValueKey('sidebar-favorites')));
        await tester.pumpAndSettle();
        expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
        expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
        expect(find.byKey(const ValueKey('photo-p1')), findsNothing);
        expect(tester.takeException(), isNull);
        await disposeApp(tester, gateway);
      },
    );
  }
}
