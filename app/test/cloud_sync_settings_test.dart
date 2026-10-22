import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/cloud_sync_gateway.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-cloud-settings-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  Future<void> mount(WidgetTester tester, FakeLocalGateway gateway) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
    await tester.pumpAndSettle();
  }

  Future<void> openCloudSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-category-4')));
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

  Future<void> enterCredentials(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('cloud-endpoint')),
      'http://127.0.0.1:8790',
    );
    await tester.enterText(
      find.byKey(const ValueKey('cloud-username')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const ValueKey('cloud-password')),
      'correct horse',
    );
  }

  testWidgets('sign-in shows the account and never echoes the password', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await openCloudSettings(tester);

    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);
    await enterCredentials(tester);
    await tester.tap(find.byKey(const ValueKey('cloud-login')));
    await tester.pumpAndSettle();

    expect(gateway.cloudLoginCalls, 1);
    expect(gateway.cloudSeenPasswords, ['correct horse']);
    expect(find.byKey(const ValueKey('cloud-account')), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8790'), findsOneWidget);
    expect(find.text('correct horse'), findsNothing);
    // Signing in establishes the session and nothing else: it must not start
    // a download behind the user's back.
    expect(gateway.cloudSyncCalls, 0);
    await disposeApp(tester, gateway);
  });

  testWidgets('the auto sync switch is off by default and stays a choice', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
      );
    await mount(tester, gateway);
    await openCloudSettings(tester);

    final toggle = find.byKey(const ValueKey('cloud-auto-sync'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    // A signed-in account does not sweep on its own at startup.
    expect(gateway.cloudSyncCalls, 0);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await disposeApp(tester, gateway);
  });

  testWidgets('failed sign-in surfaces a stable code without the password', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)..failCloudLogin = true;
    await mount(tester, gateway);
    await openCloudSettings(tester);
    await enterCredentials(tester);
    await tester.tap(find.byKey(const ValueKey('cloud-login')));
    await tester.pumpAndSettle();

    expect(gateway.cloudLoginCalls, 1);
    expect(find.byKey(const ValueKey('cloud-error')), findsOneWidget);
    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.text('correct horse'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-account')), findsNothing);
    await disposeApp(tester, gateway);
  });

  testWidgets('startup syncs a signed-in account and sync now reports counts', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        state: 'idle',
        pendingUploads: 2,
        pendingFavorites: 1,
        boundCount: 1,
      )
      ..cloudReport = const CloudSyncReport(
        downloaded: 2,
        uploaded: 1,
        favoritesApplied: 1,
      )
      ..cloudBoundIds = {'p0'};
    await mount(tester, gateway);
    // Startup does not sweep unless auto sync was turned on.
    expect(gateway.cloudSyncCalls, 0);

    await openCloudSettings(tester);
    expect(find.byKey(const ValueKey('cloud-account')), findsOneWidget);
    expect(find.text('Pending uploads'), findsOneWidget);
    expect(find.text('Pending favorites'), findsOneWidget);
    expect(find.text('Cloud photos'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cloud-sync-now')));
    await tester.pumpAndSettle();
    expect(gateway.cloudSyncCalls, 1);
    expect(
      find.text('Synced: 2 downloaded, 1 uploaded, 1 favorites'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('cloud-logout')));
    await tester.pumpAndSettle();
    expect(gateway.cloudLogoutCalls, 1);
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);
    await disposeApp(tester, gateway);
  });
}
