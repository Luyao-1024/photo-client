import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/local_library_pane.dart';

import 'fakes/local_gateway.dart';

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-media-types-');
    image = '${fixtures.path}/pixel.png';
    await File(image).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.delete(recursive: true));

  for (final width in [1200.0, 640.0]) {
    testWidgets('motion media destination filters and resets at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      tester.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearLocaleTestValue();
      });
      final gateway = FakeToolsGateway(imagePath: image);
      gateway.photos = [
        gateway.photo(0),
        gateway.photo(1, motionOffset: 12),
        gateway.photo(2, mediaKind: 'video', mimeType: 'video/mp4'),
        gateway.photo(3, motionOffset: 0),
        gateway.photo(4, motionOffset: 24, state: 'trashed'),
      ];
      await tester.pumpWidget(PhotoClientApp(gateway: gateway));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('sidebar-photos'))),
      );

      void expectCover(String kind, String id) {
        final row = find.byKey(ValueKey('sidebar-media-$kind'));
        expect(
          find.descendant(
            of: row,
            matching: find.byKey(ValueKey('sidebar-cover-$id')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.byType(Icon)),
          findsNothing,
        );
      }

      expectCover('images', 'p0');
      expectCover('videos', 'p2');
      expectCover('motion', 'p1');

      Future<void> select(String key) async {
        final row = find.byKey(ValueKey('sidebar-$key'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
      }

      await select('media-motion');
      expect(gateway.requestedKinds.last, 'motion');
      expect(container.read(localLibraryProvider).mediaKind, 'motion');
      expect(container.read(localLibraryProvider).total, 1);
      expect(find.byKey(const ValueKey('photo-p1')), findsOneWidget);
      for (final id in ['p0', 'p2', 'p3', 'p4']) {
        expect(find.byKey(ValueKey('photo-$id')), findsNothing);
      }
      expect(
        find.descendant(
          of: find.byType(LocalLibraryPane),
          matching: find.text('Motion photos'),
        ),
        findsOneWidget,
      );
      if (width >= 700) {
        await select('media-types-header');
        expect(
          find.byKey(const ValueKey('sidebar-media-motion')),
          findsNothing,
        );
        expect(container.read(localLibraryProvider).mediaKind, 'motion');
        await select('media-types-header');
      }

      await select('media-images');
      expect(container.read(localLibraryProvider).total, 3);
      expect(find.byKey(const ValueKey('photo-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-p2')), findsNothing);
      await select('media-videos');
      expect(container.read(localLibraryProvider).total, 1);
      expect(find.byKey(const ValueKey('photo-p2')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-p1')), findsNothing);
      // Category covers remain global while the grid is scoped to videos.
      expectCover('images', 'p0');
      expectCover('motion', 'p1');
      await select('photos');
      expect(container.read(localLibraryProvider).mediaKind, isNull);
      expect(container.read(localLibraryProvider).total, 4);

      // The cover and count follow real library changes, including an empty
      // category. Empty covers stay neutral instead of becoming media icons.
      await gateway.trashMedia(['p1']);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final motionRow = find.byKey(const ValueKey('sidebar-media-motion'));
      expect(
        find.descendant(of: motionRow, matching: find.byType(Image)),
        findsNothing,
      );
      expect(
        find.descendant(of: motionRow, matching: find.byType(Icon)),
        findsNothing,
      );
      expectCover('images', 'p0');
      if (width >= 700) {
        expect(
          find.descendant(of: motionRow, matching: find.text('0')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await gateway.changes.close();
      await gateway.events.close();
    });
  }
}
