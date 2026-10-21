import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/cloud_sync_gateway.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/ui/library_shell.dart';
import 'package:photo_client/ui/local_library_controller.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-actions-');
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
    tester.view.physicalSize = const Size(1200, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
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

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('sidebar-settings'))),
      );

  Future<void> pressWith(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('batch delete confirms, moves to trash, and can be restored', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 3);
    await mount(tester, gateway);

    await pressWith(tester, LogicalKeyboardKey.keyA);
    expect(find.byKey(const ValueKey('selection-count')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-trash')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Move 3 item'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await tester.pumpAndSettle();
    expect(gateway.trashCalls, 1);
    expect(gateway.photos.every((p) => p.state == 'trashed'), isTrue);
    // Let the undo snackbar expire so it no longer covers the sidebar footer.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    // Trash destination lists them and can restore every selected item.
    await tester.tap(find.byKey(const ValueKey('sidebar-trash')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-p0')), findsOneWidget);
    await pressWith(tester, LogicalKeyboardKey.keyA);
    await tester.tap(find.byKey(const ValueKey('batch-restore')));
    await tester.pumpAndSettle();
    expect(gateway.restoreCalls, 1);
    expect(gateway.photos.every((p) => p.state == 'active'), isTrue);
    await disposeApp(tester, gateway);
  });

  testWidgets('empty trash confirms before permanently deleting', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await containerOf(tester)
        .read(localLibraryProvider.notifier)
        .trashPhotos(['p0', 'p1']);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sidebar-trash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('empty-trash')));
    await tester.pumpAndSettle();
    expect(find.text('Empty trash?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await tester.pumpAndSettle();
    expect(gateway.emptyTrashCalls, 1);
    expect(gateway.photos, isEmpty);
    await disposeApp(tester, gateway);
  });

  testWidgets('copy to album records the destination and copy semantics', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await pressWith(tester, LogicalKeyboardKey.keyA);
    await tester.tap(find.byKey(const ValueKey('batch-add-to-album')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy to album').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-target-/local/photos')));
    await tester.pumpAndSettle();
    expect(gateway.requestedAdds, hasLength(1));
    expect(gateway.requestedAdds.single.$3, isFalse);
    expect(gateway.requestedAdds.single.$2, '/local/photos');
    await disposeApp(tester, gateway);
  });

  testWidgets('Ctrl+F opens search and the scope selector drives the query', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    await pressWith(tester, LogicalKeyboardKey.keyF);
    expect(find.byKey(const ValueKey('search-scope')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-scope-date')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2024-01');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(gateway.requestedScopes.last, SearchScope.date);
    expect(gateway.requestedSearches.last, '2024/01');
    await disposeApp(tester, gateway);
  });

  testWidgets('F1 opens the keyboard shortcut reference', (tester) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    await mount(tester, gateway);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shortcuts-close')), findsOneWidget);
    expect(find.text('Ctrl+F'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shortcuts-close')));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);
    await disposeApp(tester, gateway);
  });

  testWidgets('viewer delete moves the current photo to trash and stays open', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 3);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-confirm-trash')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-confirm-trash')));
    await tester.pumpAndSettle();
    expect(gateway.trashCalls, 1);
    expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('editor rotates and overwrites the original on save', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 1);
    await mount(tester, gateway);
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('viewer-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editor-rotate-right')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-confirm-overwrite')));
    await tester.pumpAndSettle();
    expect(gateway.requestedEdits, hasLength(1));
    expect(gateway.requestedEdits.single.$2.rotationDegrees, 90);
    expect(gateway.requestedEdits.single.$2.saveCopy, isFalse);
    await disposeApp(tester, gateway);
  });

  testWidgets('search destination hides the date mode selector', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2);
    await mount(tester, gateway);
    expect(find.byType(LibraryShell), findsOneWidget);
    await pressWith(tester, LogicalKeyboardKey.keyF);
    // The floating Year/Month/Day capsule belongs to the library grid only.
    expect(find.text('Month'), findsNothing);
    expect(find.byKey(const ValueKey('search-scope-all')), findsOneWidget);
    await disposeApp(tester, gateway);
  });

  testWidgets('cloud-bound photo is read-only in the grid and viewer', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 2)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        state: 'idle',
        boundCount: 1,
      )
      ..cloudBoundIds = {'p0'};
    await mount(tester, gateway);

    expect(find.byKey(const ValueKey('cloud-badge-p0')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-badge-p1')), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tile-menu-favorite')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-upload-cloud')), findsNothing);
    expect(find.byKey(const ValueKey('tile-menu-rename')), findsNothing);
    expect(find.byKey(const ValueKey('tile-menu-move-album')), findsNothing);
    expect(find.byKey(const ValueKey('tile-menu-trash')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-edit')), findsNothing);
    final trashButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('viewer-trash')),
    );
    expect(trashButton.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-confirm-trash')), findsNothing);
    expect(gateway.trashCalls, 0);
    await disposeApp(tester, gateway);
  });

  testWidgets('batch upload queues only unbound photos and syncs', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: image, count: 3)
      ..cloudState = const CloudStatus(
        loggedIn: true,
        endpoint: 'http://127.0.0.1:8790',
        username: 'alice',
        state: 'idle',
        boundCount: 1,
      )
      ..cloudBoundIds = {'p1'};
    await mount(tester, gateway);
    final startupSyncs = gateway.cloudSyncCalls;

    await pressWith(tester, LogicalKeyboardKey.keyA);
    await tester.tap(find.byKey(const ValueKey('batch-upload-cloud')));
    await tester.pumpAndSettle();

    expect(gateway.cloudUploadCalls, [
      ['p0', 'p2'],
    ]);
    expect(gateway.cloudSyncCalls, startupSyncs + 1);
    expect(find.text('2 queued, 0 skipped, 0 rejected'), findsOneWidget);
    await disposeApp(tester, gateway);
  });
}
