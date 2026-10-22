import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/window_controller.dart';
import 'package:photo_client/ui/glass_theme.dart';

import 'fakes/local_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('photo_client/window');
  late Directory fixtures;
  late String image;
  late List<MethodCall> calls;
  late bool maximized;
  final boundaryKey = GlobalKey();

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
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: PhotoClientApp(gateway: gateway),
      ),
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

  List<String> methods() => [for (final call in calls) call.method];

  testWidgets(
    'entire restored frame has transparent rounded corners and retains resize hits',
    (tester) async => runAsLinux(tester, () async {
      final gateway = FakeLocalGateway(imagePath: image);
      await mount(tester, gateway);
      Future<int> alphaAt(int x, int y) async {
        final alpha = await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final bitmap = await boundary.toImage(pixelRatio: 1);
          final bytes = await bitmap.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final alpha = bytes!.getUint8((y * bitmap.width + x) * 4 + 3);
          bitmap.dispose();
          return alpha;
        });
        return alpha!;
      }

      final clip = find.byKey(const ValueKey('window-clip'));
      expect(
        tester.widget<ClipRRect>(clip).borderRadius,
        BorderRadius.circular(GlassTheme.windowRadius),
      );
      for (final point in [
        const Offset(1, 1),
        const Offset(1098, 1),
        const Offset(1, 898),
        const Offset(1098, 898),
      ]) {
        expect(await alphaAt(point.dx.toInt(), point.dy.toInt()), 0);
      }
      expect(await alphaAt(30, 1), 255);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(const Offset(1, 1));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(methods(), contains('resize'));

      WindowController.instance.maximized.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<ClipRRect>(clip).borderRadius, BorderRadius.zero);
      expect(await alphaAt(1, 1), 255);
      WindowController.instance.maximized.value = false;
      WindowController.instance.fullscreen.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<ClipRRect>(clip).borderRadius, BorderRadius.zero);
      expect(find.byKey(const ValueKey('window-titlebar')), findsNothing);
      WindowController.instance.fullscreen.value = false;
      await tester.pumpAndSettle();
      expect(await alphaAt(1, 1), 0);
      await disposeApp(tester, gateway);
    }),
  );

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
      // The preview has no on-screen exit control.
      expect(
        find.byKey(const ValueKey('viewer-fullscreen-close')),
        findsNothing,
      );
      final enter = calls.where((call) => call.method == 'fullscreen').toList();
      expect(enter, isNotEmpty);
      expect(enter.last.arguments, isTrue);

      Future<void> reopen() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('viewer-fullscreen')), findsOneWidget);
      }

      Future<void> expectClosed() async {
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('viewer-fullscreen')), findsNothing);
        expect(find.byKey(const ValueKey('window-titlebar')), findsOneWidget);
        expect(
          calls.where((call) => call.method == 'fullscreen').last.arguments,
          isFalse,
        );
      }

      // A click anywhere on the preview leaves it.
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-fullscreen'))),
      );
      await expectClosed();

      // The viewer shortcuts work inside the preview: Escape, F, and the
      // Shift+F toggle that opened it all leave.
      await reopen();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await expectClosed();

      await reopen();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await expectClosed();

      await reopen();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await expectClosed();
      final exit = calls.where((call) => call.method == 'fullscreen').toList();
      expect(exit.length, greaterThan(enter.length));
      await disposeApp(tester, gateway);
    }),
  );
}
