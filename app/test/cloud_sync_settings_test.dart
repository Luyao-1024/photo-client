import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/cloud_sync_gateway.dart';
import 'package:photo_client/services/core_gateway.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/services/local_library_tools.dart';

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

  Future<void> mount(
    WidgetTester tester,
    FakeLocalGateway gateway, {
    LocalSourcePicker? sourcePicker,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(
      PhotoClientApp(gateway: gateway, sourcePicker: sourcePicker),
    );
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

  Future<void> submitLogin(WidgetTester tester) async {
    final login = find.byKey(const ValueKey('cloud-login'));
    await tester.ensureVisible(login);
    await tester.pumpAndSettle();
    await tester.tap(login);
    await tester.pumpAndSettle();
  }

  testWidgets('sign-in shows the account and never echoes the password', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await openCloudSettings(tester);

    // The sign-in form stays collapsed until it is requested, while the
    // controls that explain the feature remain visible.
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-signed-out')), findsOneWidget);
    final toggle = find.byKey(const ValueKey('cloud-auto-sync'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('cloud-login-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);
    await enterCredentials(tester);
    await submitLogin(tester);

    expect(gateway.cloudLoginCalls, 1);
    expect(gateway.cloudSeenPasswords, ['correct horse']);
    expect(find.byKey(const ValueKey('cloud-account')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsNothing);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8790'), findsOneWidget);
    expect(find.text('correct horse'), findsNothing);
    // Signing in establishes the session and nothing else: it must not start
    // a download behind the user's back.
    expect(gateway.cloudSyncCalls, 0);
    await disposeApp(tester, gateway);
  });

  testWidgets(
    'download progress sits in the photo header between title and search',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: image)
        ..cloudState = const CloudStatus(
          loggedIn: true,
          accountId: 'a1',
          endpoint: 'http://127.0.0.1:8790',
          username: 'alice',
          syncing: true,
          activity: CloudActivity(
            phase: 'receiving',
            syncing: true,
            downloaded: 1,
            downloadTotal: 4,
          ),
        );
      await mount(tester, gateway);

      final progress = find.byKey(const ValueKey('cloud-sync-progress'));
      expect(progress, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-header')),
          matching: progress,
        ),
        findsOneWidget,
      );
      expect(find.text('Syncing… 1/4 synced'), findsOneWidget);
      await disposeApp(tester, gateway);
    },
  );

  testWidgets('upload progress names the completed and total photos', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        syncing: true,
        activity: CloudActivity(
          phase: 'uploading',
          syncing: true,
          uploaded: 2,
          uploadTotal: 5,
        ),
      );
    await mount(tester, gateway);

    expect(find.text('Uploading… 2/5 uploaded'), findsOneWidget);
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
    // Turning auto sync on takes effect at once instead of waiting for the
    // next app start.
    expect(gateway.cloudSyncCalls, 1);
    await disposeApp(tester, gateway);
  });

  testWidgets('the sign-in form only expands on request and can be dismissed', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image);
    await mount(tester, gateway);
    await openCloudSettings(tester);

    expect(find.byKey(const ValueKey('cloud-endpoint')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cloud-login-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);

    final cancel = find.byKey(const ValueKey('cloud-login-cancel'));
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cloud-endpoint')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-login-toggle')), findsOneWidget);
    expect(gateway.cloudLoginCalls, 0);
    await disposeApp(tester, gateway);
  });

  testWidgets('failed sign-in surfaces a stable code without the password', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)..failCloudLogin = true;
    await mount(tester, gateway);
    await openCloudSettings(tester);
    await tester.tap(find.byKey(const ValueKey('cloud-login-toggle')));
    await tester.pumpAndSettle();
    await enterCredentials(tester);
    await submitLogin(tester);

    expect(gateway.cloudLoginCalls, 1);
    expect(find.byKey(const ValueKey('cloud-error')), findsOneWidget);
    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.text('correct horse'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-account')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);
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
    // Signing out collapses the form again instead of always showing it.
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-login-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-auto-sync')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-login-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-endpoint')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('sync progress explains the phase, counts and progress bar', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        pendingUploads: 2,
        pendingFavorites: 1,
        boundCount: 4,
        syncing: true,
        activity: CloudActivity(
          phase: 'receiving',
          syncing: true,
          downloaded: 1,
          downloadTotal: 3,
        ),
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
        ],
      );
    await mount(tester, gateway);
    await openCloudSettings(tester);

    expect(find.text('Receiving cloud photos…'), findsOneWidget);
    expect(find.text('Downloaded 1 / 3 photos'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-progress')), findsOneWidget);
    expect(find.text('Pending uploads'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('a failed sync shows a headline and an actionable reason', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        state: 'error',
        errorCode: 'Network',
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
        ],
      );
    await mount(tester, gateway);
    await openCloudSettings(tester);

    expect(find.text('Network unavailable'), findsOneWidget);
    expect(
      find.text('Cannot reach the server. Check the connection and retry.'),
      findsOneWidget,
    );
    await disposeApp(tester, gateway);
  });

  testWidgets('upload scope saves the selected albums for automatic upload', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..photos = [
        FakeLocalGateway(imagePath: image).photo(0, parent: '/local/album-a'),
        FakeLocalGateway(imagePath: image).photo(1, parent: '/local/album-b'),
      ]
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
        ],
      );
    await mount(tester, gateway);
    await openCloudSettings(tester);

    expect(find.text('Receive only'), findsOneWidget);
    final choose = find.byKey(const ValueKey('cloud-choose-albums'));
    await tester.ensureVisible(choose);
    await tester.pumpAndSettle();
    await tester.tap(choose);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-scope-selected')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cloud-scope-album-/local/album-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-upload-scope-save')));
    await tester.pumpAndSettle();

    expect(gateway.cloudScopeCalls, 1);
    expect(gateway.lastCloudScope?.$1, 'selected');
    expect(gateway.lastCloudScope?.$2, ['/local/album-a']);
    expect(find.text('1 albums selected for upload'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('saved accounts can be switched without signing in again', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
          CloudAccount(
            accountId: 'a2',
            endpoint: 'http://127.0.0.1:8791',
            username: 'bob',
            active: false,
            signedIn: true,
          ),
        ],
      );
    await mount(tester, gateway);
    await openCloudSettings(tester);

    await tester.tap(find.byKey(const ValueKey('cloud-switch-account')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-account-a2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-account-a2')));
    await tester.pumpAndSettle();

    expect(gateway.cloudSwitchCalls, 1);
    expect(gateway.cloudState.accountId, 'a2');
    expect(find.text('bob'), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('a background sweep shows progress and settles on its own', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
      );
    await mount(tester, gateway);
    expect(find.byKey(const ValueKey('cloud-sync-progress')), findsNothing);

    gateway.cloudState = const CloudStatus(
      loggedIn: true,
      accountId: 'a1',
      endpoint: 'http://127.0.0.1:8790',
      username: 'alice',
      syncing: true,
      activity: CloudActivity(
        phase: 'receiving',
        syncing: true,
        downloaded: 1,
        downloadTotal: 4,
      ),
    );
    gateway.events.add(
      const CoreRuntimeEvent(sequence: 1, status: 'cloud_auto_sync_started'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Syncing… 1/4 synced'), findsOneWidget);

    gateway.cloudState = const CloudStatus(
      loggedIn: true,
      accountId: 'a1',
      endpoint: 'http://127.0.0.1:8790',
      username: 'alice',
    );
    gateway.events.add(
      const CoreRuntimeEvent(sequence: 2, status: 'cloud_auto_sync_finished'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-sync-progress')), findsNothing);
    await disposeApp(tester, gateway);
  });

  testWidgets('auto sync follows account switches and scope changes', (
    tester,
  ) async {
    final gateway = _AutoSyncGateway(imagePath: image);
    gateway.cloudState = const CloudStatus(
      loggedIn: true,
      accountId: 'a1',
      endpoint: 'http://127.0.0.1:8790',
      username: 'alice',
      accounts: [
        CloudAccount(
          accountId: 'a1',
          endpoint: 'http://127.0.0.1:8790',
          username: 'alice',
          active: true,
          signedIn: true,
        ),
        CloudAccount(
          accountId: 'a2',
          endpoint: 'http://127.0.0.1:8791',
          username: 'bob',
          active: false,
          signedIn: true,
        ),
      ],
    );
    await mount(tester, gateway);
    await openCloudSettings(tester);
    // The switch is already on, so startup establishes the baseline sweep.
    expect(gateway.cloudSyncCalls, 1);

    await tester.tap(find.byKey(const ValueKey('cloud-switch-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-account-a2')));
    await tester.pumpAndSettle();
    expect(gateway.cloudSwitchCalls, 1);
    expect(gateway.cloudSyncCalls, 2);

    final choose = find.byKey(const ValueKey('cloud-choose-albums'));
    await tester.ensureVisible(choose);
    await tester.pumpAndSettle();
    await tester.tap(choose);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-scope-selected')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cloud-scope-album-/local/album-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-upload-scope-save')));
    await tester.pumpAndSettle();
    expect(gateway.cloudScopeCalls, 1);
    expect(gateway.cloudSyncCalls, 3);
    await disposeApp(tester, gateway);
  });
  testWidgets('the download folder is chosen and shown for the account', (
    tester,
  ) async {
    const root = '/home/alice/Pictures/Cloud';
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
        ],
      );
    await mount(
      tester,
      gateway,
      sourcePicker: _FixedSourcePicker(root),
    );
    await openCloudSettings(tester);

    expect(
      find.text('Not chosen; pick a real folder before syncing'),
      findsOneWidget,
    );
    final choose = find.byKey(const ValueKey('cloud-choose-download-root'));
    await tester.ensureVisible(choose);
    await tester.pumpAndSettle();
    await tester.tap(choose);
    await tester.pumpAndSettle();

    expect(gateway.cloudDownloadRootCalls, [root]);
    expect(find.text(root), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('a sync without a download folder asks for one', (tester) async {
    const root = '/home/alice/Pictures/Cloud';
    final gateway = FakeLocalGateway(imagePath: image)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        accountId: 'a1',
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        accounts: [
          CloudAccount(
            accountId: 'a1',
            endpoint: 'http://127.0.0.1:8790',
            username: 'alice',
            active: true,
            signedIn: true,
          ),
        ],
      )
      ..cloudReport = const CloudSyncReport(
        failed: 1,
        state: 'error',
        errorCode: 'DownloadRootMissing',
      );
    await mount(
      tester,
      gateway,
      sourcePicker: _FixedSourcePicker(root),
    );
    await openCloudSettings(tester);

    final sync = find.byKey(const ValueKey('cloud-sync-now'));
    await tester.ensureVisible(sync);
    await tester.pumpAndSettle();
    await tester.tap(sync);
    await tester.pumpAndSettle();

    expect(gateway.cloudDownloadRootCalls, [root]);
    await disposeApp(tester, gateway);
  });
}

class _FixedSourcePicker implements LocalSourcePicker {
  _FixedSourcePicker(this.directory);

  final String? directory;

  @override
  Future<List<String>> chooseFiles() async => const [];

  @override
  Future<String?> chooseDirectory() async => directory;
}

class _AutoSyncGateway extends FakeLocalGateway implements LocalLibraryTools {
  _AutoSyncGateway({required super.imagePath});

  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    if (command['op'] == 'preferences') {
      return <String, Object?>{'cloudAutoSync': true};
    }
    // The controller takes the indexed native path once this interface is
    // implemented. An empty window is enough for this scheduling test.
    if (command['op'] == 'window') {
      return <String, Object?>{
        'items': <Object?>[],
        'total': 0,
        'revision': 1,
        'groups': <Object?>[],
      };
    }
    return null;
  }

  @override
  Future<List<LocalAlbum>> listAlbums() async => const [
    LocalAlbum(path: '/local/album-a', name: 'album-a', count: 0),
    LocalAlbum(path: '/local/album-b', name: 'album-b', count: 0),
  ];
}
