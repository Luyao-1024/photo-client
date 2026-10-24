import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassMaterializeTransition;

import 'package:photo_client/app.dart';
import 'package:photo_client/ui/glass_surface.dart';
import 'package:photo_client/ui/library_layout.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/presentation_preferences.dart';
import 'package:photo_client/ui/mode_selector.dart';

import 'fakes/local_gateway.dart';
import 'helpers/filmstrip_frames.dart';

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
    // Earlier tests can leave decoded thumbnails pinning the shared cache,
    // which makes later precacheImage calls wait indefinitely.
    imageCache.clear();
    imageCache.clearLiveImages();
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

  testWidgets('phone menus open under their buttons with compact rows', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 8);
    await mount(tester, gateway);

    final options = find.byKey(const ValueKey('library-options'));
    final button = tester.getRect(options);
    await tester.tap(options);
    await tester.pumpAndSettle();

    final viewRow = tester.getRect(
      find.byKey(const ValueKey('library-menu-view')),
    );
    expect(viewRow.height, closeTo(48, .5));
    expect(viewRow.top, greaterThanOrEqualTo(button.bottom));
    expect(
      tester.getRect(find.byKey(const ValueKey('library-menu-select'))).height,
      closeTo(48, .5),
    );
    // The parent row no longer advertises the active view mode.
    expect(find.text('Date view'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-menu-view')));
    await tester.pumpAndSettle();
    final dateOption = tester.getRect(
      find.byKey(const ValueKey('view-mode-date')),
    );
    expect(dateOption.height, closeTo(48, .5));
    expect(dateOption.top, greaterThanOrEqualTo(button.bottom));
    expect(
      tester.getRect(find.byKey(const ValueKey('view-mode-compact'))).height,
      closeTo(48, .5),
    );
    await tester.tap(find.byKey(const ValueKey('view-mode-compact')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-grid-compact')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-nav-albums')));
    await tester.pumpAndSettle();
    final albumsOptions = find.byKey(const ValueKey('mobile-albums-options'));
    final albumsButton = tester.getRect(albumsOptions);
    await tester.tap(albumsOptions);
    await tester.pumpAndSettle();
    final settings = tester.getRect(
      find.byKey(const ValueKey('mobile-albums-menu-settings')),
    );
    expect(settings.height, closeTo(48, .5));
    expect(settings.top, greaterThanOrEqualTo(albumsButton.bottom));
    await disposeApp(tester, gateway);
  });

  testWidgets('phone photo menu selects and switches between the two views', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 8);
    await mount(tester, gateway);

    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-menu-select')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-menu-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-menu-settings')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-menu-view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('view-mode-date')), findsOneWidget);
    expect(find.byKey(const ValueKey('view-mode-compact')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('view-mode-compact')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-grid-compact')), findsOneWidget);
    // Grouping stays available on the photos page in both views.
    expect(find.byKey(const ValueKey('mobile-group-mode')), findsOneWidget);
    final first = tester.getRect(find.byKey(const ValueKey('photo-p0')));
    final second = tester.getRect(find.byKey(const ValueKey('photo-p1')));
    final nextRow = tester.getRect(find.byKey(const ValueKey('photo-p5')));
    expect(second.left - first.right, closeTo(2, .5));
    expect(nextRow.top - first.bottom, closeTo(2, .5));

    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view-mode-date')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-grid-compact')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-group-mode')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('exit-selection')), findsOneWidget);
    expect(find.byKey(const ValueKey('select-all')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('phone settings use grouped rows, sheets and system back', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    await mount(tester, gateway);
    final container = containerOf(tester);
    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-settings')));
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
    await tester.tap(find.byKey(const ValueKey('library-menu-settings')));
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

  testWidgets('phone header stays fixed and reveals its info below on pull', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 9);
    await mount(tester, gateway);
    final grid = find.byKey(const ValueKey('local-photo-grid'));
    final barTitle = headerText('Photos');
    final barTop = tester.getTopLeft(barTitle).dy;
    final count = find.byKey(const ValueKey('library-header-count'));
    final range = find.byKey(const ValueKey('library-header-range'));
    final backdrop = find.byKey(
      const ValueKey('mobile-library-header-backdrop'),
    );
    List<Color> backdropColors() =>
        ((tester.widget<DecoratedBox>(backdrop).decoration as BoxDecoration)
                    .gradient
                as LinearGradient)
            .colors;
    final barHeight = tester.getSize(backdrop).height;
    expect(count, findsNothing);
    expect(range, findsNothing);
    // The bar keeps its fading edge whether or not anything scrolls.
    expect(backdropColors().last.a, 0);

    await tester.drag(grid, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(count, findsOneWidget);
    expect(find.text('9 photos'), findsOneWidget);
    // Date view has no visible date span; only the count belongs here.
    expect(range, findsNothing);
    // Showing the info does not stretch the bar or its background.
    expect(tester.getSize(backdrop).height, barHeight);
    expect(backdropColors().last.a, 0);
    expect(
      tester.getTopLeft(count).dy,
      greaterThan(tester.getBottomLeft(backdrop).dy),
    );
    // The info strip hugs the bar instead of leaving an empty band.
    expect(
      tester.getTopLeft(count).dy - tester.getBottomLeft(backdrop).dy,
      lessThan(4.5),
    );
    expect(tester.getTopLeft(barTitle).dy, barTop);

    // The bar never scrolls away, and dragging up retracts the panel even
    // though a short grid has no scroll extent of its own.
    await tester.drag(grid, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(count, findsNothing);
    expect(tester.getTopLeft(barTitle).dy, barTop);

    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view-mode-compact')));
    await tester.pumpAndSettle();
    // The compact date is part of the header before any pull.
    expect(range, findsOneWidget);
    await tester.drag(grid, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(range, findsOneWidget);
    expect(count, findsOneWidget);
    expect(find.text('9 photos'), findsOneWidget);
    expect(tester.getTopLeft(barTitle).dy, barTop);
    await tester.drag(grid, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(count, findsNothing);
    // Retracting the info leaves the header's compact date in place.
    expect(range, findsOneWidget);
    expect(
      tester.getRect(range).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('library-header'))).bottom,
      ),
    );
    await disposeApp(tester, gateway);
  });

  testWidgets('phone compact view keeps the visible date in the header', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 80);
    await mount(tester, gateway);
    final sectionTitle = tester.widget<Text>(
      find.byKey(const ValueKey('library-date-header')).first,
    );
    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view-mode-compact')));
    await tester.pumpAndSettle();

    final grid = find.byKey(const ValueKey('local-photo-grid'));
    final header = find.byKey(const ValueKey('library-header'));
    final range = find.byKey(const ValueKey('library-header-range'));
    expect(range, findsOneWidget);
    final headerRect = tester.getRect(header);
    // The compact date is part of the fixed header, not the scroll content.
    expect(tester.getRect(range).top, greaterThan(headerRect.top));
    expect(tester.getRect(range).bottom, lessThanOrEqualTo(headerRect.bottom));
    expect(tester.widget<Text>(range).data, isNotEmpty);
    // It matches the date-view section headers and lines up with the title.
    final rangeText = tester.widget<Text>(range);
    expect(rangeText.style?.fontSize, sectionTitle.style?.fontSize);
    expect(rangeText.style?.fontWeight, sectionTitle.style?.fontWeight);
    expect(rangeText.textAlign, TextAlign.start);
    expect(
      tester.getTopLeft(range).dx,
      tester.getTopLeft(headerText('Photos')).dx,
    );

    await tester.drag(grid, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(range, findsOneWidget);
    expect(tester.getRect(header), headerRect);
    expect(tester.widget<Text>(range).data, isNotEmpty);

    // The pull-revealed info no longer repeats the compact range.
    await tester.drag(grid, const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(range, findsOneWidget);
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
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsOneWidget);
    for (final key in [
      'viewer-previous',
      'viewer-next',
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
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsNothing);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('viewer-strip-p2')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('3 / 6'), findsOneWidget);

    await disposeApp(tester, gateway);
  });

  testWidgets('returning chrome materializes its glass without a fade layer', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byKey(const ValueKey('viewer')));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-header')), findsNothing);

    await tester.tapAt(center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final header = find.byKey(const ValueKey('viewer-header'));
    expect(header, findsOneWidget);
    // A backdrop pass under an ancestor Opacity samples black, which is the
    // dark plate that used to appear before the frost on the returning bar.
    expect(
      find.ancestor(of: header, matching: find.byType(Opacity)),
      findsNothing,
    );
    final scope = tester.widget<GlassRevealScope>(
      find.ancestor(of: header, matching: find.byType(GlassRevealScope)).first,
    );
    expect(scope.progress, inExclusiveRange(0, 1));
    expect(
      find.ancestor(
        of: header,
        matching: find.byType(GlassMaterializeTransition),
      ),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(header, findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('filmstrip follows the page turn and returns on cancel', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 6);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();

    final first = find.byKey(const ValueKey('viewer-strip-p0'));
    final settled = tester.getRect(first);
    final center = tester.getCenter(find.byKey(const ValueKey('viewer')));

    // A short drag moves the strip in phase with the photo, then walks it
    // back when the page returns.
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(tester.getRect(first).left, lessThan(settled.left - 3));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(first).left, closeTo(settled.left, .01));
    expect(find.textContaining('1 / 6'), findsOneWidget);

    // A committed turn hands the follow translation over to the strip's
    // centring, leaving the incoming tile in the middle.
    await tester.dragFrom(center, const Offset(-320, 0));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 6'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('viewer-strip-p1'))).dx,
      closeTo(center.dx, 1),
    );

    await disposeApp(tester, gateway);
  });

  testWidgets('revealed chrome keeps the filmstrip on the current photo', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 12);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byKey(const ValueKey('viewer')));
    await tester.dragFrom(center, const Offset(-320, 0));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 12'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('viewer-strip-p1'))).dx,
      closeTo(center.dx, 1),
    );

    // Hiding the chrome unmounts the strip once its fold ends; revealing it
    // builds a fresh list, which must re-centre instead of starting at p0.
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-filmstrip')), findsNothing);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const ValueKey('viewer-strip-p1'))).dx,
      closeTo(center.dx, 1),
    );

    await disposeApp(tester, gateway);
  });

  testWidgets('touch viewer header clears the status bar', (tester) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 6);
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();

    final header = tester.getRect(find.byKey(const ValueKey('viewer-header')));
    expect(header.top, 32);
    expect(header.left, 12);
    expect(header.right, 390 - 12);
    // The pill hugs its controls instead of carrying the status-bar inset.
    expect(header.height, lessThan(60));
    await disposeApp(tester, gateway);
  });

  testWidgets('phone filmstrip uses uniform square thumbnails', (tester) async {
    final gateway = FakeLocalGateway(imagePath: image);
    gateway.photos = [
      for (var i = 0; i < 2; i++) gateway.photo(i, width: 300, height: 400),
      for (var i = 2; i < 6; i++) gateway.photo(i, width: 400, height: 300),
    ];
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();

    // p0 is drawn at the selected scale, so compare the two following items.
    final first = tester.getRect(
      find.byKey(const ValueKey('viewer-strip-image-p1')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('viewer-strip-image-p2')),
    );
    expect(first.size, const Size(48, 48));
    expect(second.center.dx - first.center.dx, closeTo(56, .5));
    expect(second.left - first.right, closeTo(8, .5));
    // Landscape and portrait sources both fill the same tile by cropping.
    expect(
      tester.getSize(find.byKey(const ValueKey('viewer-strip-image-p2'))),
      const Size(48, 48),
    );
    final thumbnail = tester.widget<Image>(
      find
          .descendant(
            of: find.byKey(const ValueKey('viewer-strip-image-p1')),
            matching: find.byType(Image),
          )
          .first,
    );
    expect(thumbnail.fit, BoxFit.cover);
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
    // The year/month/day switch belongs to the Photos page only.
    expect(find.byKey(const ValueKey('mobile-group-mode')), findsNothing);
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
    expect(find.byKey(const ValueKey('mobile-group-mode')), findsNothing);
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
    expect(
      find.byKey(const ValueKey('mobile-albums-menu-settings')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mobile-albums-menu-settings')));
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
