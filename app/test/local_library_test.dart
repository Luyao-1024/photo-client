import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/runtime_controller.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-presentation-');
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
    double width = 1100,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
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

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-folder')), findsOneWidget);
  }

  /// Escape-closes the dialog with bounded pumps: while a scan spinner runs,
  /// pumpAndSettle would never return.
  Future<void> closeSettingsQuietly(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('add-folder')), findsNothing);
  }

  testWidgets(
    'real mode opens an empty local library and disables unavailable picker',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image);
      await mount(tester, gateway);
      expect(find.text('Library is empty'), findsOneWidget);
      // The empty state offers a live path into Settings (not a dead button);
      // the quiet overview with counts only renders once there is content.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('open-settings')))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('cloud'), findsNothing);
      await openSettings(tester);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('add-files')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('add-folder')))
            .onPressed,
        isNull,
      );
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('picker cancellation does not scan or report an import success', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    final picker = FakePicker()
      ..directory = null
      ..files = [];
    await mount(tester, gateway, picker: picker);
    await openSettings(tester);
    await tester.tap(find.byKey(const ValueKey('add-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-files')));
    await tester.pumpAndSettle();
    expect(picker.directoryRequests, 1);
    expect(picker.fileRequests, 1);
    expect(gateway.scans, 0);
    expect(find.textContaining('Scan finished'), findsNothing);
    await disposeApp(tester, gateway);
  });

  for (final directory in [false, true]) {
    testWidgets(
      '${directory ? 'directory' : 'file'} selection calls addPaths and shows actual scan result',
      (tester) async {
        final gateway = FakeLocalGateway(imagePath: image);
        final picker = FakePicker();
        await mount(tester, gateway, picker: picker, width: 390);
        await openSettings(tester);
        await tester.tap(
          find.byKey(ValueKey(directory ? 'add-folder' : 'add-files')),
        );
        await tester.pumpAndSettle();
        expect(
          gateway.addedPaths,
          directory ? ['/chosen/photos'] : ['/chosen/photo.png'],
        );
        expect(find.text('1 photos'), findsOneWidget);
        expect(
          find.text('Scan finished: 1 discovered, 0 skipped, 0 failed'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeApp(tester, gateway);
      },
    );
  }

  testWidgets(
    'viewer opens by tap, zooms, changes photo by keyboard, and closes with escape',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 3);
      await mount(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('photo-p0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final first = await tester.createGesture(pointer: 1);
      final second = await tester.createGesture(pointer: 2);
      await first.down(center - const Offset(20, 0));
      await second.down(center + const Offset(20, 0));
      await tester.pump();
      await first.moveTo(center - const Offset(90, 0));
      await second.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('viewer-name'))).data,
        'Photo 1.png',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('viewer-details')));
      await tester.pumpAndSettle();
      expect(find.text(image), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer')), findsNothing);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('favorite write and favorite filter use actual gateway results', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('viewer-favorite')));
    await tester.pumpAndSettle();
    expect(gateway.favorites, 1);
    expect(gateway.photos.first.favorite, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('viewer-favorite')))
          .isSelected,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('viewer-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-favorites')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-p1')), findsNothing);
    expect(find.text('1 photos'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets(
    'search is debounced and an unmatched result is distinct from an empty library',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 4);
      await mount(tester, gateway);
      // The search field is hidden behind the round search button at rest.
      await tester.tap(find.byKey(const ValueKey('library-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'not-present');
      await tester.pump(const Duration(milliseconds: 100));
      expect(gateway.listCalls, 1);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(gateway.requestedSearches.last, 'not-present');
      // An unmatched search is distinct from an empty library: the no-matches
      // state shows, and the empty-library state never does.
      expect(find.text('No matching photos'), findsOneWidget);
      expect(find.text('Library is empty'), findsNothing);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets(
    'load failure shows a safe error, retry succeeds without pretending library is empty',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image)..failOpen = true;
      await mount(tester, gateway);
      expect(find.byKey(const ValueKey('library-error')), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.text('Library is empty'), findsNothing);
      gateway.failOpen = false;
      await tester.tap(find.byKey(const ValueKey('retry-library')));
      await tester.pumpAndSettle();
      expect(find.text('Library is empty'), findsOneWidget);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('favorite failure retains original value and displays an error', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1)
      ..failFavorite = true;
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('viewer-favorite')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('viewer-favorite')))
          .isSelected,
      isFalse,
    );
    expect(
      find.text('The favorite change was not saved. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE'), findsNothing);
    await disposeApp(tester, gateway);
  });

  testWidgets(
    'scan events refresh progressively while final result remains pending',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image)
        ..pendingScan = Completer<LocalScanResult>();
      await mount(tester, gateway, picker: FakePicker());
      await openSettings(tester);
      await tester.tap(find.byKey(const ValueKey('add-folder')));
      await tester.pump();
      await closeSettingsQuietly(tester);
      // Empty library + active scan: the indexing status page shows instead
      // of the grid, and its spinner never lets pumpAndSettle return.
      expect(find.text('Scanning local sources…'), findsOneWidget);
      gateway.photos.add(gateway.photo(0));
      gateway.revision++;
      for (var index = 0; index < 10; index++) {
        gateway.changes.add(null);
      }
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Indexing…'), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
      expect(gateway.listCalls, 2);
      gateway.pendingScan!.complete(
        const LocalScanResult(
          discovered: 1,
          skipped: 2,
          failed: 1,
          cancelled: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Scan cancelled: 1 discovered, 2 skipped, 1 failed'),
        findsOneWidget,
      );
      await disposeApp(tester, gateway);
    },
  );

  testWidgets(
    'cancel acknowledgement keeps scan pending until its actual result',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 1)
        ..pendingScan = Completer<LocalScanResult>();
      await mount(tester, gateway, picker: FakePicker());
      expect(find.byKey(const ValueKey('cancel-scan')), findsNothing);
      await openSettings(tester);
      await tester.tap(find.byKey(const ValueKey('add-folder')));
      await tester.pump();
      await closeSettingsQuietly(tester);
      await tester.tap(find.byKey(const ValueKey('cancel-scan')));
      await tester.pump();
      expect(gateway.cancellationsRequested, 1);
      expect(find.text('Indexing…'), findsOneWidget);
      expect(find.textContaining('Scan cancelled:'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('cancel-scan')))
            .onPressed,
        isNull,
      );
      // Reopening settings during the scan shows add-folder disabled.
      await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('add-folder')))
            .onPressed,
        isNull,
      );
      await closeSettingsQuietly(tester);
      gateway.pendingScan!.complete(
        const LocalScanResult(
          discovered: 0,
          skipped: 0,
          failed: 0,
          cancelled: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Scan cancelled: 0 discovered, 0 skipped, 0 failed'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cancel-scan')), findsNothing);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets(
    'visible evicted pages reload on repeated visits without stuck placeholders',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 1100);
      await mount(tester, gateway);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('local-photo-grid'))),
      );
      final controller = container.read(localLibraryProvider.notifier);
      for (var page = 1; page <= 10; page++) {
        await controller.loadNext();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
      final beforeReload = gateway.listCalls;
      for (var page = 1; page <= 10; page++) {
        await controller.ensurePage(page);
      }
      await tester.pumpAndSettle();
      expect(gateway.listCalls, greaterThan(beforeReload));
      expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  test(
    'paging retains a bounded DTO cache and can reload an evicted visited page',
    () async {
      final gateway = FakeLocalGateway(imagePath: image, count: 1100);
      final container = ProviderContainer(
        overrides: [coreGatewayProvider.overrideWithValue(gateway)],
      );
      final controller = container.read(localLibraryProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      for (var page = 1; page <= 10; page++) {
        await controller.loadNext();
      }
      final state = container.read(localLibraryProvider);
      expect(state.extent, 1100);
      expect(
        state.pages.values.fold<int>(0, (sum, photos) => sum + photos.length),
        lessThanOrEqualTo(800),
      );
      expect(state.photoAt(0), isNull);
      expect((await controller.photoAt(0))?.id, 'p0');
      expect(gateway.limits.every((limit) => limit == 100), isTrue);
      container.dispose();
      await gateway.changes.close();
      await gateway.events.close();
    },
  );
}
