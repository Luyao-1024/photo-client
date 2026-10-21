import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/window_controller.dart';

import 'fakes/local_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('photo_client/window');
  late Directory fixtures;
  late String image;
  late List<MethodCall> calls;
  late bool maximized;

  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-window-frame-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  setUp(() {
    calls = <MethodCall>[];
    maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'maximize') {
            maximized = !maximized;
            return maximized;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final window = WindowController.instance;
    window.maximized.value = false;
    window.fullscreen.value = false;
    window.confirmClose = null;
    window.confirmLibraryClose = null;
    window.prepareClose = null;
  });

  Future<void> runAsLinux(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> mount(WidgetTester tester, FakeLocalGateway gateway) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 900);
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

  List<String> methods() => [for (final call in calls) call.method];

  testWidgets(
    'titlebar buttons minimize, maximize/restore, and close',
    (tester) async => runAsLinux(tester, () async {
      final gateway = FakeLocalGateway(imagePath: image);
      await mount(tester, gateway);
      expect(find.byKey(const ValueKey('window-titlebar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('window-minimize')));
      await tester.pumpAndSettle();
      expect(methods(), contains('minimize'));

      await tester.tap(find.byKey(const ValueKey('window-maximize')));
      await tester.pumpAndSettle();
      expect(methods(), contains('maximize'));
      expect(WindowController.instance.maximized.value, isTrue);
      expect(find.byIcon(Icons.filter_none), findsOneWidget);
      expect(find.byTooltip('Restore window'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('window-maximize')));
      await tester.pumpAndSettle();
      expect(WindowController.instance.maximized.value, isFalse);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byTooltip('Maximize'), findsOneWidget);

      final beforeDoubleTap = methods().where((m) => m == 'maximize').length;
      final bar = find.byKey(const ValueKey('window-titlebar'));
      await tester.tap(bar);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(
        methods().where((m) => m == 'maximize').length,
        beforeDoubleTap + 1,
      );
      expect(WindowController.instance.maximized.value, isTrue);

      // The window button only requests a close; runtime teardown is exercised
      // elsewhere, so keep this test focused on the frame contract.
      var prepared = false;
      WindowController.instance.confirmLibraryClose = () async => true;
      WindowController.instance.prepareClose = () async {
        prepared = true;
      };
      await tester.tap(find.byKey(const ValueKey('window-close')));
      await tester.pumpAndSettle();
      expect(prepared, isTrue);
      expect(methods(), contains('close'));
      await disposeApp(tester, gateway);
    }),
  );

  testWidgets(
    'Shift+F fullscreen hides the titlebar and restores it',
    (tester) async => runAsLinux(tester, () async {
      final gateway = FakeLocalGateway(imagePath: image, count: 1);
      await mount(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('photo-p0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('viewer-fullscreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('window-titlebar')), findsNothing);
      final enter = calls.where((call) => call.method == 'fullscreen').toList();
      expect(enter, isNotEmpty);
      expect(enter.last.arguments, isTrue);

      await tester.tap(find.byKey(const ValueKey('viewer-fullscreen-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-fullscreen')), findsNothing);
      expect(find.byKey(const ValueKey('window-titlebar')), findsOneWidget);
      final exit = calls.where((call) => call.method == 'fullscreen').toList();
      expect(exit.length, greaterThan(enter.length));
      expect(exit.last.arguments, isFalse);
      await disposeApp(tester, gateway);
    }),
  );
}
