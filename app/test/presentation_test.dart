import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:photo_client/app.dart';
import 'package:photo_client/services/core_gateway.dart';
import 'package:photo_client/ui/glass_surface.dart';
import 'package:photo_client/ui/backdrop_viewport.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/local_library_pane.dart';
import 'package:photo_client/ui/mode_selector.dart';
import 'package:photo_client/ui/photos_grid.dart';
import 'package:photo_client/ui/presentation_preferences.dart';
import 'package:photo_client/ui/runtime_controller.dart';

import 'fakes/local_gateway.dart';

const snapshot = CoreSnapshot(
  profileId: 'linux-test',
  profileDigest: 'verified-profile-digest',
  bridgeProtocolVersion: 1,
  sessionId: 'session-1',
  status: 'ready',
);

class FakeGateway implements CoreGateway {
  FakeGateway() {
    events = StreamController<CoreRuntimeEvent>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancellations++,
    );
  }

  late final StreamController<CoreRuntimeEvent> events;
  Completer<CoreSnapshot>? pendingInitialize;
  Completer<String>? pendingProbe;
  Completer<void>? pendingShutdown;
  bool failInitialize = false;
  bool failShutdown = false;
  int initializes = 0;
  int listens = 0;
  int cancellations = 0;
  int probes = 0;
  int shutdowns = 0;
  String? sentMessage;

  @override
  Future<CoreSnapshot> initialize() async {
    initializes++;
    if (failInitialize) throw StateError('PRIVATE native error');
    final pending = pendingInitialize;
    if (pending != null) return pending.future;
    return snapshot;
  }

  @override
  Stream<CoreRuntimeEvent> watchRuntime() => events.stream;

  @override
  Future<String> roundTrip(String message) async {
    probes++;
    sentMessage = message;
    final pending = pendingProbe;
    if (pending != null) return pending.future;
    return 'core:$message';
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
    if (failShutdown) throw StateError('PRIVATE shutdown error');
    await pendingShutdown?.future;
  }
}

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-shell-');
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
    await tester.pump();
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

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('sidebar-settings'))),
      );

  Future<void> openSettings(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('sidebar-settings')));
    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-close')), findsOneWidget);
  }

  Future<void> openSettingsCategory(WidgetTester tester, int index) async {
    await openSettings(tester);
    await tester.tap(find.byKey(ValueKey('settings-category-$index')));
    await tester.pumpAndSettle();
  }

  Future<void> closeSettings(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('settings-close')), findsNothing);
  }

  testWidgets('sidebar navigation switches photos, favorites and trash', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final container = containerOf(tester);
    expect(find.text('No photos yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-favorites')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
    // A filtered-away library is distinct from an empty one.
    expect(find.text('No matching photos'), findsOneWidget);
    expect(find.text('No photos yet'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sidebar-trash')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Trash is empty'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-photos')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(find.text('No photos yet'), findsOneWidget);
    expect(gateway.initializes, 1);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('sidebar collapses to an icon rail under 700px and keeps flow', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    // Wide: the 240px sidebar shows destination labels.
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);

    tester.view.physicalSize = const Size(390, 900);
    await tester.pumpAndSettle();
    // Compact: the 72px rail keeps every destination, labels become tooltips.
    expect(find.text('Trash'), findsNothing);
    for (final key in [
      'sidebar-photos',
      'sidebar-favorites',
      'sidebar-trash',
      'sidebar-settings',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await openSettings(tester);
    expect(gateway.initializes, 1);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.text('Trash'), findsOneWidget);
    expect(gateway.initializes, 1);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('settings dialog owns appearance and sources', (tester) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    await openSettings(tester);
    // Runtime plumbing stays internal: no "core" status is user-facing.
    expect(find.textContaining('core'), findsNothing);
    expect(find.byType(ChoiceChip), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('settings-category-1')));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-background-blur')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-files')), findsOneWidget);
    // Without an injected picker the app falls back to its in-app chooser.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('add-folder')))
          .onPressed,
      isNotNull,
    );
    await closeSettings(tester);
    await disposeApp(tester, gateway);
  });

  testWidgets('theme, language and glass persist via presentationProvider', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final container = containerOf(tester);
    // Fixed lenses: navigation, search, options and the mode selector.
    // Individual photo tiles and navigation rows never own a live surface.
    final live = tester
        .widgetList<GlassSurface>(find.byType(GlassSurface))
        .where((surface) => surface.live)
        .toList();
    expect(live.length, 4);
    expect(
      find.descendant(
        of: find.byType(ModeSelector),
        matching: find.byType(GlassSurface),
      ),
      findsOneWidget,
    );

    await openSettingsCategory(tester, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-theme-dark')),
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Dark'));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const ValueKey('settings-category-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '简体中文'));
    await tester.pumpAndSettle();
    expect(
      container.read(presentationProvider).locale,
      const Locale('zh', 'CN'),
    );
    expect(find.text('语言'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-category-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-glass-quality')), findsNothing);
    expect(find.byType(Slider), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('settings-follow-scroll')),
      findsOneWidget,
    );
    // The material is drawn by the glass layer, not by a hand-rolled blur, so
    // the contract is the surface itself: it exists, and its body is
    // translucent rather than solid.
    final surfaces = tester.widgetList<GlassContainer>(
      find.byType(GlassContainer),
    );
    expect(surfaces, isNotEmpty);
    expect(
      surfaces.every((surface) => surface.settings!.glassColor.a < 1),
      isTrue,
    );

    // High contrast forces opaque surfaces even with glass enabled.
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<GlassContainer>(find.byType(GlassContainer))
          .every((surface) => surface.settings!.glassColor.a == 1),
      isTrue,
    );
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpAndSettle();

    // Appearance never restarts the core; preferences survive dialog cycles.
    expect(gateway.initializes, 1);
    await closeSettings(tester);
    await openSettingsCategory(tester, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-theme-dark')),
    );
    expect(container.read(presentationProvider).themeMode, ThemeMode.dark);
    expect(find.widgetWithText(ChoiceChip, '深色').evaluate().single, isNotNull);
    await closeSettings(tester);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('pending initialization shows loading and no stale event', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..pendingInitialize = Completer<CoreSnapshot>();
    await mount(tester, gateway);
    expect(find.text('Loading photos…'), findsOneWidget);
    expect(find.textContaining('core'), findsNothing);
    final container = containerOf(tester);
    expect(gateway.listens, 0);

    gateway.pendingInitialize!.complete(snapshot);
    await tester.pumpAndSettle();
    expect(find.text('No photos yet'), findsOneWidget);
    expect(gateway.listens, 1);

    gateway.events.add(const CoreRuntimeEvent(sequence: 9, status: 'running'));
    await tester.pumpAndSettle();
    expect(container.read(runtimeProvider).sequence, 9);
    expect(container.read(runtimeProvider).runtimeStatus, 'running');
    // A stale (lower-sequence) event never overwrites a newer one.
    gateway.events.add(const CoreRuntimeEvent(sequence: 8, status: 'stale'));
    await tester.pumpAndSettle();
    expect(container.read(runtimeProvider).sequence, 9);
    expect(container.read(runtimeProvider).runtimeStatus, 'running');
    await disposeApp(tester, gateway);
  });

  testWidgets('initialization error is safe, retry creates a fresh session', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)..failInitialize = true;
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    expect(find.text('Photos failed to load'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.textContaining('core'), findsNothing);
    expect(gateway.initializes, 1);

    // Retry is offered on the library surface itself, not buried in settings.
    gateway.failInitialize = false;
    await tester.tap(find.byKey(const ValueKey('retry-runtime')));
    await tester.pumpAndSettle();
    expect(gateway.initializes, 2);
    expect(gateway.shutdowns, 1);
    expect(gateway.listens, 1);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.text('No photos yet'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('stream failure recovers through the library retry', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final runtime = containerOf(tester).read(runtimeProvider.notifier);
    gateway.events.addError(StateError('PRIVATE stream failure'));
    await tester.pumpAndSettle();
    expect(find.text('Photos failed to load'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.byKey(const ValueKey('retry-runtime')), findsOneWidget);
    expect(gateway.cancellations, 1);

    // Cancelling the errored broadcast subscription completes on the real
    // event loop, so the retry runs outside fake async.
    await tester.runAsync(() => runtime.initialize());
    await tester.pumpAndSettle();
    expect(gateway.listens, 2);
    expect(gateway.initializes, 2);
    expect(find.text('No photos yet'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('round trip probes only real replies and blocks concurrency', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..pendingProbe = Completer<String>();
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final container = containerOf(tester);
    final runtime = container.read(runtimeProvider.notifier);

    unawaited(runtime.probe());
    await tester.pump();
    expect(gateway.sentMessage, 'photo-client:s01');
    expect(container.read(runtimeProvider).probing, isTrue);
    expect(container.read(runtimeProvider).reply, isNull);
    // A concurrent probe is refused while one is in flight.
    await runtime.probe();
    expect(gateway.probes, 1);

    gateway.pendingProbe!.complete('verified native reply');
    await tester.pumpAndSettle();
    expect(container.read(runtimeProvider).reply, 'verified native reply');
    expect(container.read(runtimeProvider).probing, isFalse);
    expect(gateway.probes, 1);
    await disposeApp(tester, gateway);
  });

  testWidgets(
    'failed probe clears a previous reply instead of implying success',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image);
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      final container = containerOf(tester);
      final runtime = container.read(runtimeProvider.notifier);
      await runtime.probe();
      expect(container.read(runtimeProvider).reply, 'core:photo-client:s01');

      gateway.pendingProbe = Completer<String>();
      unawaited(runtime.probe());
      await tester.pump();
      // The stale reply is cleared before the outcome is known.
      expect(container.read(runtimeProvider).reply, isNull);
      gateway.pendingProbe!.completeError(StateError('PRIVATE failed probe'));
      await tester.pumpAndSettle();
      final state = container.read(runtimeProvider);
      expect(state.problem, RuntimeProblem.roundTrip);
      expect(state.reply, isNull);
      expect(state.phase, ConnectionPhase.ready);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('backgrounding keeps core, detach and teardown clean up once', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(gateway.shutdowns, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(gateway.cancellations, 1);
    expect(gateway.shutdowns, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(gateway.shutdowns, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gateway.changes.close();
    await gateway.events.close();
  });

  testWidgets(
    'teardown waits for pending initialization and releases session',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image)
        ..pendingInitialize = Completer<CoreSnapshot>();
      await mount(tester, gateway);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(gateway.shutdowns, 0);
      gateway.pendingInitialize!.complete(snapshot);
      await tester.pump();
      await tester.pump();
      expect(gateway.shutdowns, 1);
      expect(gateway.listens, 0);
      expect(tester.takeException(), isNull);
      await gateway.changes.close();
      await gateway.events.close();
    },
  );

  testWidgets(
    'closing during retry cleanup does not initialize or close twice',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image)..failInitialize = true;
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      final runtime = containerOf(tester).read(runtimeProvider.notifier);
      gateway.pendingShutdown = Completer<void>();
      gateway.failInitialize = false;
      unawaited(runtime.initialize());
      await tester.pump();
      expect(gateway.shutdowns, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      gateway.pendingShutdown!.complete();
      await tester.pump();
      await tester.pump();
      expect(gateway.initializes, 1);
      expect(gateway.shutdowns, 1);
      expect(tester.takeException(), isNull);
      await gateway.changes.close();
      await gateway.events.close();
    },
  );

  testWidgets('shutdown failure does not escape asynchronous teardown', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)..failShutdown = true;
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(gateway.shutdowns, 1);
    expect(gateway.cancellations, 1);
    expect(tester.takeException(), isNull);
    await gateway.changes.close();
    await gateway.events.close();
  });

  testWidgets(
    'header keeps the title left and search before the options button',
    (tester) async {
      for (final width in [390.0, 800.0, 1440.0, 1920.0]) {
        final gateway = FakeLocalGateway(imagePath: image);
        await mount(tester, gateway, width: width);
        await tester.pumpAndSettle();

        // The header title is the only Text carrying the photos label inside
        // the content pane.
        final title = find.descendant(
          of: find.byType(LocalLibraryPane),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.data == 'Photos' &&
                w.style?.fontWeight == FontWeight.w600,
            description: 'photos header title',
          ),
        );
        expect(title, findsOneWidget, reason: 'width $width');
        final pane = tester.getRect(find.byType(LocalLibraryPane));
        final titleRect = tester.getRect(title);

        // The destination name hugs the left edge of the content pane.
        expect(
          titleRect.left - pane.left,
          closeTo(24.0, 1.0),
          reason: 'title is not left aligned at width $width',
        );

        // The circular search is immediately before the far-right options.
        final search = find.byKey(const ValueKey('library-search'));
        expect(search, findsOneWidget, reason: 'width $width');
        final searchRect = tester.getRect(search);
        expect(
          pane.right - searchRect.right,
          closeTo(80.0, 1.0),
          reason: 'search does not leave room for options at width $width',
        );
        expect(
          searchRect.left,
          greaterThan(pane.center.dx),
          reason: 'search is not on the right half at width $width',
        );

        expect(tester.takeException(), isNull);
        await disposeApp(tester, gateway);
      }
    },
  );

  testWidgets(
    'scrolling publishes a throttled visible photo then the final resting photo',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 90);
      await mount(tester, gateway, width: 1440);
      await tester.pumpAndSettle();
      final container = containerOf(tester);
      final gridFinder = find.byKey(const ValueKey('local-photo-grid'));
      final scroll = tester.widget<CustomScrollView>(gridFinder).controller!;
      int centeredRank() {
        final grid = tester.getRect(gridFinder);
        final header = tester.getRect(
          find.byKey(const ValueKey('library-header')),
        );
        final center = Offset(
          grid.center.dx,
          (header.bottom + grid.bottom) / 2,
        );
        final tile =
            find
                    .byType(PhotoTile)
                    .evaluate()
                    .firstWhere(
                      (element) => tester
                          .getRect(find.byWidget(element.widget))
                          .contains(center),
                    )
                    .widget
                as PhotoTile;
        return container.read(localLibraryProvider).indexOf(tile.photo.id)!;
      }

      for (var step = 0; step < 12; step++) {
        scroll.jumpTo(250 + step * 50.0);
        await tester.pump(const Duration(milliseconds: 100));
        if (step < 11) expect(container.read(backdropViewportProvider), isNull);
      }
      final sampled = container.read(backdropViewportProvider)!;
      expect(sampled.rank, centeredRank());
      scroll.jumpTo(1300);
      await tester.pump(const Duration(milliseconds: 299));
      expect(container.read(backdropViewportProvider), sampled);
      await tester.pump(const Duration(milliseconds: 1));
      expect(container.read(backdropViewportProvider)!.rank, centeredRank());
      expect(
        container.read(backdropViewportProvider)!.rank,
        isNot(sampled.rank),
      );
      container.read(presentationProvider.notifier).setFollowScroll(false);
      await tester.pumpAndSettle();
      scroll.jumpTo(1600);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(container.read(backdropViewportProvider), isNull);
      container.read(presentationProvider.notifier).setFollowScroll(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(backdropViewportProvider)!.rank, centeredRank());
      scroll.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(backdropViewportProvider)!.rank, isNull);
      expect(gateway.scans, 0);
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets(
    'photos scroll under the pinned heading and its buttons stay clickable',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image, count: 90);
      await mount(tester, gateway, width: 1440);
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('library-header'));
      final search = find.byKey(const ValueKey('library-search'));
      final headerRect = tester.getRect(header);
      final searchRect = tester.getRect(search);
      final gridFinder = find.byKey(const ValueKey('local-photo-grid'));
      expect(
        tester
            .widget<ClipRRect>(find.byKey(const ValueKey('photo-panel-clip')))
            .borderRadius,
        BorderRadius.circular(18),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('photo-panel-clip'))),
        tester.getRect(find.byType(LocalLibraryPane)),
      );
      final albumPanel = tester.getRect(
        find.byKey(const ValueKey('library-navigation')),
      );
      final photoPanel = tester.getRect(
        find.byKey(const ValueKey('photo-panel-clip')),
      );
      expect(photoPanel.top, albumPanel.top);
      expect(photoPanel.bottom, albumPanel.bottom);
      expect(find.byKey(const ValueKey('photo-display-clip')), findsNothing);
      expect(
        tester.getRect(gridFinder).left,
        tester.getRect(find.byType(LocalLibraryPane)).left + 20,
      );
      expect(
        tester.getRect(gridFinder).top,
        tester.getRect(find.byType(LocalLibraryPane)).top,
      );
      tester.widget<CustomScrollView>(gridFinder).controller!.jumpTo(100);
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(const ValueKey('photo-p0')))
            .overlaps(headerRect),
        isTrue,
      );
      expect(tester.getRect(header), headerRect);
      expect(tester.getRect(search), searchRect);
      expect(search.hitTestable(), findsOneWidget);
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('pinned header keeps the visible photos when changing grouping', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 90);
    await mount(tester, gateway, width: 1440);
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('library-header'));
    final headerRect = tester.getRect(header);
    final grid = tester.widget<CustomScrollView>(
      find.byKey(const ValueKey('local-photo-grid')),
    );
    grid.controller!.jumpTo(700);
    await tester.pumpAndSettle();
    expect(tester.getRect(header), headerRect);
    final visible = find.byType(PhotoTile).evaluate().where((element) {
      final rect = tester.getRect(find.byWidget(element.widget));
      return rect.bottom > headerRect.bottom && rect.top < headerRect.bottom;
    }).toList();
    expect(visible, isNotEmpty);
    final anchor = (visible.first.widget as PhotoTile).photo.id;
    await tester.tap(find.byKey(const ValueKey('mode-month')));
    await tester.pumpAndSettle();
    final anchorRect = tester.getRect(find.byKey(ValueKey('photo-$anchor')));
    expect(anchorRect.bottom, greaterThan(headerRect.bottom));
    expect(anchorRect.top, lessThan(headerRect.bottom + anchorRect.height));
    expect(tester.getRect(header), headerRect);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('narrow layout remains usable with doubled text size', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester, gateway, width: 390);
    await tester.pumpAndSettle();
    await openSettings(tester);
    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });
}
