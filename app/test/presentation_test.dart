import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photo_client/app.dart';
import 'package:photo_client/services/core_gateway.dart';

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

Future<void> mount(
  WidgetTester tester,
  FakeGateway gateway, {
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
  await tester.pumpWidget(PhotoClientApp(gateway: gateway));
  await tester.pump();
}

Future<void> openConnection(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-connection')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pending initialization never reports a connection or an event', (
    tester,
  ) async {
    final gateway = FakeGateway()
      ..pendingInitialize = Completer<CoreSnapshot>();
    await mount(tester, gateway);
    expect(find.text('Connecting to the local core…'), findsOneWidget);
    expect(find.text('Local core connected'), findsNothing);
    expect(gateway.listens, 0);

    gateway.pendingInitialize!.complete(snapshot);
    await tester.pumpAndSettle();
    expect(find.text('Local core connected'), findsOneWidget);
    expect(gateway.listens, 1);
    await openConnection(tester);
    expect(find.text('linux-test'), findsOneWidget);
    expect(find.text('Waiting for an event'), findsOneWidget);

    gateway.events.add(const CoreRuntimeEvent(sequence: 9, status: 'running'));
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    gateway.events.add(const CoreRuntimeEvent(sequence: 8, status: 'stale'));
    await tester.pumpAndSettle();
    expect(find.text('stale'), findsNothing);
    expect(find.text('9'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.events.close();
  });

  testWidgets('initialization error is safe, retry creates a fresh session', (
    tester,
  ) async {
    final gateway = FakeGateway()..failInitialize = true;
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    expect(find.text('Local core unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    await openConnection(tester);
    expect(find.byKey(const ValueKey('core-error')), findsOneWidget);
    gateway.failInitialize = false;
    await tester.tap(find.byKey(const ValueKey('retry-connection')));
    await tester.pumpAndSettle();
    expect(gateway.initializes, 2);
    expect(gateway.shutdowns, 1);
    expect(gateway.listens, 1);
    expect(find.text('Local core connected'), findsOneWidget);
    expect(find.byKey(const ValueKey('core-error')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.events.close();
  });

  for (final (width, key) in [
    (390.0, 'compact-navigation'),
    (800.0, 'medium-navigation'),
    (1440.0, 'wide-navigation'),
  ]) {
    testWidgets('$width layout keeps core flow available through resize', (
      tester,
    ) async {
      final gateway = FakeGateway();
      await mount(tester, gateway, width: width);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(key)), findsOneWidget);
      expect(find.text('Your local library starts here'), findsOneWidget);
      expect(
        find.byType(BackdropFilter).evaluate().length,
        lessThanOrEqualTo(1),
      );
      await openConnection(tester);
      expect(find.text('session-1'), findsOneWidget);
      tester.view.physicalSize = Size(width == 390 ? 1440 : 390, 900);
      await tester.pumpAndSettle();
      expect(find.text('session-1'), findsOneWidget);
      expect(gateway.initializes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await gateway.events.close();
    });
  }

  testWidgets(
    'round trip displays only a real reply and prevents concurrent probes',
    (tester) async {
      final gateway = FakeGateway()..pendingProbe = Completer<String>();
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      await openConnection(tester);
      final probe = find.byKey(const ValueKey('round-trip'));
      await tester.ensureVisible(probe);
      await tester.tap(probe);
      await tester.pump();
      expect(gateway.sentMessage, 'photo-client:s01');
      expect(find.text('Core reply'), findsNothing);
      expect(tester.widget<FilledButton>(probe).onPressed, isNull);
      gateway.pendingProbe!.complete('verified native reply');
      await tester.pumpAndSettle();
      expect(find.text('verified native reply'), findsOneWidget);
      expect(gateway.probes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await gateway.events.close();
    },
  );

  testWidgets(
    'stream failure marks stale connection and retry cancels old stream',
    (tester) async {
      final gateway = FakeGateway();
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      await openConnection(tester);
      gateway.events.addError(StateError('PRIVATE stream failure'));
      await tester.pumpAndSettle();
      expect(find.text('Local core unavailable'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(gateway.cancellations, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('round-trip')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('retry-connection')));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(gateway.listens, 2);
      expect(gateway.initializes, 2);
      expect(find.text('Local core connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await gateway.events.close();
    },
  );

  testWidgets('backgrounding keeps core, detach and teardown clean up once', (
    tester,
  ) async {
    final gateway = FakeGateway();
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
    expect(find.text('Local core stopped'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(gateway.shutdowns, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gateway.events.close();
  });

  testWidgets(
    'teardown waits for pending initialization and releases late session',
    (tester) async {
      final gateway = FakeGateway()
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
      await gateway.events.close();
    },
  );

  testWidgets(
    'appearance supports Chinese, dark and solid without core restart',
    (tester) async {
      final gateway = FakeGateway();
      await mount(tester, gateway, width: 390);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-shortcut')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '简体中文'));
      await tester.pumpAndSettle();
      expect(find.text('语言'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '深色'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '纯色'));
      await tester.tap(find.widgetWithText(ChoiceChip, '纯色'));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(gateway.initializes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await gateway.events.close();
    },
  );

  testWidgets(
    'failed probe clears a previous reply instead of implying success',
    (tester) async {
      final gateway = FakeGateway();
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      await openConnection(tester);
      final probe = find.byKey(const ValueKey('round-trip'));
      await tester.ensureVisible(probe);
      await tester.tap(probe);
      await tester.pumpAndSettle();
      expect(find.text('core:photo-client:s01'), findsOneWidget);
      gateway.pendingProbe = Completer<String>();
      await tester.tap(probe);
      await tester.pump();
      expect(find.text('core:photo-client:s01'), findsNothing);
      gateway.pendingProbe!.completeError(StateError('PRIVATE failed probe'));
      await tester.pumpAndSettle();
      expect(
        find.text('The round trip failed. You can try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.text('Core reply'), findsNothing);
      expect(find.text('Local core connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await gateway.events.close();
    },
  );

  testWidgets(
    'closing during retry cleanup does not initialize or close twice',
    (tester) async {
      final gateway = FakeGateway()..failInitialize = true;
      await mount(tester, gateway);
      await tester.pumpAndSettle();
      await openConnection(tester);
      gateway.pendingShutdown = Completer<void>();
      gateway.failInitialize = false;
      await tester.tap(find.byKey(const ValueKey('retry-connection')));
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
      await gateway.events.close();
    },
  );

  testWidgets('shutdown failure does not escape asynchronous teardown', (
    tester,
  ) async {
    final gateway = FakeGateway()..failShutdown = true;
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
    await gateway.events.close();
  });

  testWidgets('glass respects accessibility and small-window area budget', (
    tester,
  ) async {
    final gateway = FakeGateway();
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await mount(tester, gateway);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = find.byType(BackdropFilter);
    expect(
      find.ancestor(of: filter, matching: find.byType(ClipRRect)),
      findsWidgets,
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    tester.view.physicalSize = const Size(390, 240);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.events.close();
  });

  testWidgets('narrow layout remains usable with doubled text size', (
    tester,
  ) async {
    final gateway = FakeGateway();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester, gateway, width: 390);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open-connection')));
    await openConnection(tester);
    expect(find.text('session-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.events.close();
  });
}
