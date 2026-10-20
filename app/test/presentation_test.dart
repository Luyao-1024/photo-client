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
    expect(find.byKey(const ValueKey('add-folder')), findsOneWidget);
  }

  Future<void> closeSettings(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('add-folder')), findsNothing);
  }

  Finder connectionStatus() => find.byKey(const ValueKey('connection-status'));

  testWidgets('sidebar navigation switches photos, favorites and trash', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final container = containerOf(tester);
    expect(find.text('Library is empty'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-favorites')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isTrue);
    // A filtered-away library is distinct from an empty one.
    expect(find.text('No matching photos'), findsOneWidget);
    expect(find.text('Library is empty'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sidebar-trash')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Trash is empty'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-photos')));
    await tester.pumpAndSettle();
    expect(container.read(localLibraryProvider).favoritesOnly, isFalse);
    expect(find.text('Library is empty'), findsOneWidget);
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
    expect(connectionStatus(), findsOneWidget);
    expect(gateway.initializes, 1);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.text('Trash'), findsOneWidget);
    expect(gateway.initializes, 1);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('settings dialog owns connection status, appearance and sources', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    // The old persistent connection card is gone from the shell chrome.
    expect(connectionStatus(), findsNothing);
    await openSettings(tester);
    expect(tester.widget<Text>(connectionStatus()).data, 'Local core connected');
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(find.widgetWithText(ChoiceChip, 'Dark'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byKey(const ValueKey('add-files')), findsOneWidget);
    // No picker was supplied: the source buttons stay honestly disabled.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('add-folder')))
          .onPressed,
      isNull,
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

    await openSettings(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Dark'));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '简体中文'));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).locale, const Locale('zh', 'CN'));
    expect(find.text('语言'), findsOneWidget);

    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(container.read(presentationProvider).glass, isFalse);
    expect(find.byType(BackdropFilter), findsNothing);

    // High contrast forces solid surfaces even with glass enabled again.
    await tester.tap(find.byType(SwitchListTile));
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
    await openSettings(tester);
    expect(container.read(presentationProvider).themeMode, ThemeMode.dark);
    expect(find.widgetWithText(ChoiceChip, '深色').evaluate().single, isNotNull);
    await closeSettings(tester);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });

  testWidgets('pending initialization never reports a connection or an event', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..pendingInitialize = Completer<CoreSnapshot>();
    await mount(tester, gateway);
    expect(find.text('Connecting to the local core…'), findsOneWidget);
    await openSettings(tester);
    final container = containerOf(tester);
    expect(
      tester.widget<Text>(connectionStatus()).data,
      'Connecting to the local core…',
    );
    expect(gateway.listens, 0);

    gateway.pendingInitialize!.complete(snapshot);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(connectionStatus()).data, 'Local core connected');
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
    expect(find.text('Local core unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    await openSettings(tester);
    expect(
      tester.widget<Text>(connectionStatus()).data,
      'Local core unavailable',
    );
    final runtime = containerOf(tester).read(runtimeProvider.notifier);
    // Retry with the dialog closed: the shell must never keep a stale surface
    // open across a connection transition.
    await closeSettings(tester);

    gateway.failInitialize = false;
    await runtime.initialize();
    await tester.pumpAndSettle();
    expect(gateway.initializes, 2);
    expect(gateway.shutdowns, 1);
    expect(gateway.listens, 1);
    expect(find.textContaining('PRIVATE'), findsNothing);
    await openSettings(tester);
    expect(tester.widget<Text>(connectionStatus()).data, 'Local core connected');
    await closeSettings(tester);
    await disposeApp(tester, gateway);
  });

  testWidgets('stream failure marks stale connection and retry rerescribes', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    final runtime = containerOf(tester).read(runtimeProvider.notifier);
    gateway.events.addError(StateError('PRIVATE stream failure'));
    await tester.pumpAndSettle();
    expect(find.text('Local core unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(gateway.cancellations, 1);
    await openSettings(tester);
    expect(
      tester.widget<Text>(connectionStatus()).data,
      'Local core unavailable',
    );
    await closeSettings(tester);

    // Cancelling the errored broadcast subscription completes on the real
    // event loop, so the retry runs outside fake async.
    await tester.runAsync(() => runtime.initialize());
    await tester.pumpAndSettle();
    expect(gateway.listens, 2);
    expect(gateway.initializes, 2);
    await openSettings(tester);
    expect(tester.widget<Text>(connectionStatus()).data, 'Local core connected');
    await closeSettings(tester);
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

  testWidgets('failed probe clears a previous reply instead of implying success', (
    tester,
  ) async {
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
  });

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

  testWidgets('teardown waits for pending initialization and releases session', (
    tester,
  ) async {
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
  });

  testWidgets('closing during retry cleanup does not initialize or close twice', (
    tester,
  ) async {
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
  });

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

  testWidgets('narrow layout remains usable with doubled text size', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester, gateway, width: 390);
    await tester.pumpAndSettle();
    await openSettings(tester);
    expect(connectionStatus(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeApp(tester, gateway);
  });
}
