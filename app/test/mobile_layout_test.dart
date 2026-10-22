import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photo_client/app.dart';
import 'package:photo_client/ui/library_layout.dart';
import 'package:photo_client/ui/local_library_controller.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-mobile-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  Future<void> mount(
    WidgetTester tester,
    FakeLocalGateway gateway, {
    FakePicker? picker,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(
      PhotoClientApp(
        gateway: gateway,
        sourcePicker: picker,
        layout: LibraryLayout.mobile,
      ),
    );
    await tester.pumpAndSettle();
    // The thumbnail pool debounces viewport updates by 200ms.
    await tester.pump(const Duration(milliseconds: 220));
  }

  Future<void> disposeApp(WidgetTester tester, FakeLocalGateway gateway) async {
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await gateway.changes.close();
    await gateway.events.close();
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('mobile-library-shell'))),
      );

  Finder headerText(String text) => find.descendant(
    of: find.byKey(const ValueKey('library-header')),
    matching: find.text(text),
  );

  testWidgets('phone shell drops the sidebar for a floating bottom bar', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 4);
    await mount(tester, gateway);

    expect(find.byKey(const ValueKey('library-navigation')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-photos')), findsNothing);
    for (final key in [
      'mobile-nav-photos',
      'mobile-nav-albums',
      'mobile-nav-favorites',
      'mobile-nav-more',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(headerText('Photos'), findsOneWidget);

    // Three tiles fill the phone width; the fourth wraps to the next row.
    final first = tester.getTopLeft(find.byKey(const ValueKey('photo-p0')));
    final second = tester.getTopLeft(find.byKey(const ValueKey('photo-p1')));
    final third = tester.getTopLeft(find.byKey(const ValueKey('photo-p2')));
    final fourth = tester.getTopLeft(find.byKey(const ValueKey('photo-p3')));
    expect(second.dy, first.dy);
    expect(third.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));
    expect(third.dx, greaterThan(second.dx));
    expect(fourth.dy, greaterThan(first.dy));
    await disposeApp(tester, gateway);
  });

  testWidgets('bottom navigation reaches albums, favorites, trash and search', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 4);
    await mount(tester, gateway);
    final container = containerOf(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-favorites')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
    expect(headerText('Favorites'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-albums-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-smart-album-favorites')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-smart-album-trash')),
      findsOneWidget,
    );
    final album = find.byKey(const ValueKey('mobile-album-/local/photos'));
    expect(album, findsOneWidget);
    await tester.ensureVisible(album);
    await tester.tap(album);
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).folder, '/local/photos');
    expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    final videos = find.byKey(const ValueKey('mobile-smart-album-videos'));
    await tester.ensureVisible(videos);
    await tester.tap(videos);
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).mediaKind, 'video');
    expect(headerText('Videos'), findsOneWidget);
    expect(find.text('No matching photos'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-more-trash')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-more-trash')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).trashed, isTrue);
    expect(find.textContaining('Trash is empty'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-albums-search')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(container.read(localLibraryProvider).trashed, isFalse);
    expect(find.byKey(const ValueKey('mobile-library-shell')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('library-search-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-nav-photos')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-search-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-nav-photos')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('album page adds, renames and reorders albums', (tester) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 3);
    gateway.photos.add(gateway.photo(3, parent: '/local/trips'));
    final picker = FakePicker();
    await mount(tester, gateway, picker: picker);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-album-/local/photos')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-album-/local/trips')),
      findsOneWidget,
    );

    final album = find.byKey(const ValueKey('mobile-album-/local/photos'));
    await tester.ensureVisible(album);
    await tester.longPress(album);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-album-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-album-remove')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-album-rename')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-album-rename-field')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-albums-reorder')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-albums-reorder')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-album-order-/local/photos')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mobile-album-order-done')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('mobile-albums-add')));
    await tester.tap(find.byKey(const ValueKey('mobile-albums-add')));
    await tester.pumpAndSettle();
    expect(picker.directoryRequests, 1);
    expect(find.byKey(const ValueKey('album-name-field')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('system back clears search and filtered destinations first', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    final container = containerOf(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-favorites')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(headerText('Photos'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Photo 1');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).search, 'Photo 1');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).search, isEmpty);
    expect(find.byType(TextField), findsNothing);
    await disposeApp(tester, gateway);
  });
}
