import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photo_client/app.dart';
import 'package:photo_client/ui/library_layout.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/presentation_preferences.dart';
import 'package:photo_client/ui/mode_selector.dart';

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
    final gateway = FakeLocalGateway(imagePath: image, count: 6);
    await mount(tester, gateway);

    expect(find.byKey(const ValueKey('library-navigation')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-photos')), findsNothing);
    for (final key in ['mobile-nav-photos', 'mobile-nav-albums']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.byKey(const ValueKey('mobile-nav-favorites')), findsNothing);
    expect(headerText('Photos'), findsOneWidget);

    expect(find.byKey(const ValueKey('mobile-nav-more')), findsNothing);
    // Day columns follow the saved preference; the sixth starts a new row.
    final first = tester.getTopLeft(find.byKey(const ValueKey('photo-p0')));
    final second = tester.getTopLeft(find.byKey(const ValueKey('photo-p1')));
    final third = tester.getTopLeft(find.byKey(const ValueKey('photo-p2')));
    final sixth = tester.getTopLeft(find.byKey(const ValueKey('photo-p5')));
    expect(second.dy, first.dy);
    expect(third.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));
    expect(third.dx, greaterThan(second.dx));
    expect(sixth.dy, greaterThan(first.dy));
    await disposeApp(tester, gateway);
  });

  testWidgets('overscroll never stretches the photo grid on Android', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = FakeLocalGateway(imagePath: image, count: 12);
      await mount(tester, gateway);

      // Material 3 applies a stretch indicator to every scrollable on Android;
      // it scales the whole grid, visibly distorting photo thumbnails.
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
      await disposeApp(tester, gateway);
    } finally {
      // The binding checks foundation debug variables before tearDowns run.
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'phone capsule stays centered and its selection slides between tabs',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 4);
      await mount(tester, gateway);
      final navigation = find.byKey(const ValueKey('mobile-navigation'));
      final mode = find.byKey(const ValueKey('mobile-group-mode'));
      expect(tester.getCenter(navigation).dx, 195);
      expect(
        tester.getTopLeft(navigation).dx,
        greaterThan(tester.getBottomRight(mode).dx),
      );
      final indicator = find.descendant(
        of: find.byKey(const ValueKey('mobile-navigation-indicator')),
        matching: find.byType(DecoratedBox),
      );
      final pill = tester.getRect(navigation);
      // The accent is a half-pill that reaches the glass rim on the selected
      // side instead of a small inset rectangle.
      expect(tester.getRect(indicator).left, closeTo(pill.left, .5));
      expect(tester.getRect(indicator).top, closeTo(pill.top, .5));
      expect(tester.getRect(indicator).height, closeTo(pill.height, .5));
      expect(tester.getRect(indicator).width, closeTo(pill.width / 2, .5));
      final start = tester.getCenter(indicator).dx;
      await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final during = tester.getCenter(indicator).dx;
      expect(during, greaterThan(start));
      await tester.pumpAndSettle();
      final end = tester.getCenter(indicator).dx;
      expect(during, lessThan(end));
      expect(tester.getRect(indicator).right, closeTo(pill.right, .5));
      expect(tester.getCenter(navigation).dx, 195);
      expect(find.byKey(const ValueKey('mobile-group-mode')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mobile-nav-photos')));
      await tester.pumpAndSettle();
      expect(tester.getCenter(navigation).dx, 195);
      expect(tester.getCenter(indicator).dx, start);
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('phone settings use grouped rows, sheets and system back', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    await mount(tester, gateway);
    final container = containerOf(tester);
    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-settings-page')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('settings-category-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-nav-photos')).hitTestable(),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('mobile-settings-close')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-order')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile-setting-choice-date_asc')),
    );
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).order, 'date_asc');
    expect(find.text('Oldest first'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-theme')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile-setting-choice-ThemeMode.dark')),
    );
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).themeMode, ThemeMode.dark);
    expect(
      Theme.of(
        tester.element(find.byKey(const ValueKey('mobile-settings-cloud'))),
      ).brightness,
      Brightness.dark,
    );

    final scroll = find.byKey(const PageStorageKey('mobile-settings-scroll'));
    final appearance = find.byKey(const ValueKey('mobile-settings-appearance'));
    await tester.scrollUntilVisible(
      appearance.hitTestable(),
      180,
      scrollable: find
          .descendant(of: scroll, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    final offset = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        )
        .position
        .pixels;
    await tester.tap(appearance);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-background-blur')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(
            find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .pixels,
      offset,
    );
    expect(find.byKey(const ValueKey('mobile-settings-page')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-reduce-motion')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-reduce-motion')));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).reduceMotion, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-nav-photos')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('phone settings stay usable at narrow widths with large text', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 0);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('mobile-settings-cloud')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final order = find.byKey(const ValueKey('settings-order'));
    await tester.scrollUntilVisible(
      order.hitTestable(),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('mobile-settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(order);
    await tester.pumpAndSettle();
    final choice = find.byKey(
      const ValueKey('mobile-setting-choice-name_desc'),
    );
    await tester.scrollUntilVisible(
      choice.hitTestable(),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('mobile-setting-choices')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('phone year and month overviews show progressively more photos', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 180);
    await mount(tester, gateway);
    final tile = find.byKey(const ValueKey('photo-p0'));
    final day = tester.getSize(tile).width;
    final modeButton = find.byKey(const ValueKey('mobile-group-mode'));
    expect(
      find.descendant(of: modeButton, matching: find.text('Day')),
      findsOneWidget,
    );
    expect(find.byType(ModeSelector), findsNothing);
    expect(
      tester.getCenter(modeButton).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('mobile-navigation'))).dx,
      ),
    );
    final dayTiles = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith('photo-p'),
        )
        .evaluate()
        .length;
    await tester.tap(modeButton);
    await tester.pumpAndSettle();
    final month = tester.getSize(tile).width;
    expect(
      find.descendant(of: modeButton, matching: find.text('Month')),
      findsOneWidget,
    );
    await tester.tap(modeButton);
    await tester.pumpAndSettle();
    final year = tester.getSize(tile).width;
    expect(
      find.descendant(of: modeButton, matching: find.text('Year')),
      findsOneWidget,
    );
    final yearTiles = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith('photo-p'),
        )
        .evaluate()
        .length;
    expect(month, lessThan(day * .75));
    expect(year, lessThan(month * .75));
    expect(yearTiles, greaterThan(dayTiles));
    await tester.tap(modeButton);
    await tester.pumpAndSettle();
    expect(tester.getSize(tile).width, day);
    expect(
      find.descendant(of: modeButton, matching: find.text('Day')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('phone photo lists pull to refresh even when empty', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 0);
    await mount(tester, gateway);
    final before = gateway.openCalls;
    await tester.drag(
      find.byKey(const ValueKey('local-photo-grid')),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(gateway.openCalls, greaterThan(before));
    expect(find.byKey(const ValueKey('mobile-more-refresh')), findsNothing);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    await disposeApp(tester, gateway);
  });

  testWidgets('touch viewer swipes between photos without desktop chrome', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 6);
    await mount(tester, gateway);

    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
    for (final key in [
      'viewer-previous',
      'viewer-next',
      'viewer-filmstrip',
      'viewer-zoom-in',
      'viewer-zoom-out',
      'viewer-zoom-reset',
      'viewer-immersive',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.byKey(const ValueKey('viewer-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-favorite')), findsOneWidget);
    expect(find.textContaining('1 / 6'), findsOneWidget);

    // Secondary actions live in the sheet instead of crowding the header.
    await tester.tap(find.byKey(const ValueKey('viewer-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-more-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-more-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-more-details')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-more-trash')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-more-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-details-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-details-close')));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byKey(const ValueKey('viewer')));
    await tester.dragFrom(center, const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 6'), findsOneWidget);

    await tester.dragFrom(center, const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 6'), findsOneWidget);

    // A tap owns the chrome on touch; the header folds away and returns.
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-header')), findsNothing);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-header')), findsOneWidget);

    await disposeApp(tester, gateway);
  });

  testWidgets('touch viewer tracks the finger and hands off the next page', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 6);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();

    final frame = find.descendant(
      of: find.byKey(const ValueKey('viewer-stage-p0-1')),
      matching: find.byKey(const ValueKey('viewer-photo-frame')),
    );
    final start = tester.getRect(frame).left;
    final center = tester.getCenter(find.byKey(const ValueKey('viewer')));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-90, 0));
    await tester.pump();

    // The current page travels with the finger and the neighbour rides in
    // from the right edge in the same frame.
    expect(tester.getRect(frame).left, closeTo(start - 130, 1));
    final preview = find.byKey(const ValueKey('viewer-swipe-preview-next'));
    expect(preview, findsOneWidget);
    final width = tester.getSize(find.byKey(const ValueKey('viewer'))).width;
    expect(tester.getRect(preview).left, closeTo(width - 130, 1));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 6'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('viewer-swipe-preview-next')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('albums page owns favorites, videos, trash and search', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 4);
    await mount(tester, gateway);
    final container = containerOf(tester);

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

    // Favorites is an album detail, not a bottom tab.
    await tester.tap(
      find.byKey(const ValueKey('mobile-smart-album-favorites')),
    );
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
    expect(headerText('Favorites'), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-albums-page')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-nav-albums')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-album-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-album-back')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(find.byKey(const ValueKey('mobile-albums-page')), findsOneWidget);

    final album = find.byKey(const ValueKey('mobile-album-/local/photos'));
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
    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();

    final trash = find.byKey(const ValueKey('mobile-smart-album-trash'));
    await tester.ensureVisible(trash);
    await tester.tap(trash);
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).trashed, isTrue);
    expect(headerText('Trash'), findsOneWidget);
    expect(find.textContaining('Trash is empty'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-album-back')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).trashed, isFalse);
    expect(find.byKey(const ValueKey('mobile-albums-page')), findsOneWidget);

    expect(find.byKey(const ValueKey('mobile-nav-more')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-albums-options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-settings-page')), findsOneWidget);
    await tester.binding.handlePopRoute();
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

  testWidgets('back walks album detail, albums list and search', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    final container = containerOf(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('mobile-smart-album-favorites')),
    );
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(find.byKey(const ValueKey('mobile-albums-page')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
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
