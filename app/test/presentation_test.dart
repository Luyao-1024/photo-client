import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photo_client/app.dart';
import 'package:photo_client/services/core_gateway.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/local_library_pane.dart';
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
    expect(find.widgetWithText(ChoiceChip, 'Dark'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-glass')), findsOneWidget);
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
    // The floating mode selector is the single live glass surface.
    expect(find.byType(BackdropFilter), findsOneWidget);

    await openSettingsCategory(tester, 1);
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
    await tester.ensureVisible(find.byKey(const ValueKey('settings-glass')));
    await tester.tap(find.byKey(const ValueKey('settings-glass')));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).glass, isFalse);
    expect(find.byType(BackdropFilter), findsNothing);

    // High contrast forces solid surfaces even with glass enabled again.
    await tester.tap(find.byKey(const ValueKey('settings-glass')));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).glass, isTrue);
    expect(find.byType(BackdropFilter), findsOneWidget);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpAndSettle();

    // Appearance never restarts the core; preferences survive dialog cycles.
    expect(gateway.initializes, 1);
    await closeSettings(tester);
    await openSettingsCategory(tester, 1);
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

  testWidgets('header puts the destination name left and search right', (
    tester,
  ) async {
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
        closeTo(12.0, 1.0),
        reason: 'title is not left aligned at width $width',
      );

      // The search button sits at the far right of the same bar.
      final search = find.byKey(const ValueKey('library-search'));
      expect(search, findsOneWidget, reason: 'width $width');
      final searchRect = tester.getRect(search);
      expect(
        pane.right - searchRect.right,
        closeTo(12.0, 1.0),
        reason: 'search is not flush right at width $width',
      );
      expect(
        searchRect.left,
        greaterThan(pane.center.dx),
        reason: 'search is not on the right half at width $width',
      );

      expect(tester.takeException(), isNull);
      await disposeApp(tester, gateway);
    }
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
