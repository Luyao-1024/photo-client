import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/services/local_library_tools.dart';
import 'package:photo_client/ui/glass_surface.dart';
import 'package:photo_client/ui/mode_selector.dart';

import 'fakes/local_gateway.dart';

class _Gateway extends FakeLocalGateway implements LocalLibraryTools {
  _Gateway(String image) : super(imagePath: image, count: 3);
  final preferences = <String, Object?>{'order': 'date_desc'};
  final covers = <String, String>{};
  final coverWrites = <Map<String, Object?>>[];
  bool failCover = false;

  @override
  Future<List<LocalAlbum>> listAlbums() async => [
    for (final album in await super.listAlbums())
      LocalAlbum(
        path: album.path,
        name: album.name,
        count: album.count,
        coverMediaId: covers[album.path] ?? album.coverMediaId,
      ),
  ];

  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    switch (command['op']) {
      case 'preferences':
        return Map.of(preferences);
      case 'setPreference':
        preferences[command['key'] as String] = command['value'];
        return null;
      case 'albumCover':
        if (failCover) throw StateError('cover write failed');
        coverWrites.add(Map.of(command));
        covers[command['folder'] as String] = command['id'] as String;
        return null;
      case 'rank':
        return 0;
      case 'window':
      case 'selection':
        final filter = command['filter'] as Map;
        final page = await super.listPhotos(
          limit: 1000,
          folder: filter['folder'] as String?,
          favoritesOnly: filter['favorites_only'] as bool? ?? false,
          trashed: filter['trashed'] as bool? ?? false,
        );
        final items = page.items.toList();
        if ((filter['order'] as String).startsWith('name_')) {
          items.sort((a, b) => a.name.compareTo(b.name));
          if (filter['order'] == 'name_desc') {
            items.setAll(0, items.reversed.toList());
          }
        }
        return {
          'total': items.length,
          'revision': revision,
          'groups': <Object?>[],
          'items': [
            for (final photo
                in items
                    .skip(command['start'] as int? ?? 0)
                    .take(command['count'] as int? ?? 2000))
              {
                'id': photo.id,
                'path': photo.path,
                'name': photo.name,
                'parent': photo.parent,
                'size_bytes': photo.sizeBytes,
                'modified_ms': photo.modifiedMs,
                'content_version': photo.contentVersion,
                'favorite': photo.favorite,
                'media_kind': photo.mediaKind,
                'mime_type': photo.mimeType,
                'orientation': photo.orientation,
                'state': photo.state,
                'sort_time_ms': photo.sortTimeMs,
              },
          ],
        };
      default:
        throw UnsupportedError('${command['op']}');
    }
  }
}

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() {
    fixtures = Directory.systemTemp.createTempSync('photo-page-actions-');
    image = '${fixtures.path}/pixel.png';
    File(image).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      ),
    );
  });
  tearDownAll(() => fixtures.deleteSync(recursive: true));

  Future<void> mount(
    WidgetTester tester,
    _Gateway gateway, {
    double width = 1200,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester, _Gateway gateway) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await gateway.changes.close();
    await gateway.events.close();
  }

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const ValueKey('library-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('library-menu-$item')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'unframed heading and round controls keep selection usable at narrow widths',
    (tester) async {
      for (final width in [390.0, 1200.0]) {
        final gateway = _Gateway(image);
        await mount(tester, gateway, width: width);
        final lenses = find.descendant(
          of: find.byKey(const ValueKey('library-header')),
          matching: find.byType(GlassSurface),
        );
        expect(lenses, findsNWidgets(2));
        for (final element in lenses.evaluate()) {
          expect(
            tester.getSize(find.byWidget(element.widget)),
            const Size(48, 48),
          );
        }
        expect(tester.getSize(find.byType(ModeSelector)), const Size(216, 48));
        final search = find.byKey(const ValueKey('library-search'));
        final options = find.byKey(const ValueKey('library-options'));
        expect(
          tester.getRect(search).right,
          lessThan(tester.getRect(options).left),
        );
        expect(
          tester.widget<IconButton>(search).style!.shape!.resolve({}),
          isA<CircleBorder>(),
        );
        await menu(tester, 'select');
        expect(find.byKey(const ValueKey('exit-selection')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('photo-p1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('viewer')), findsNothing);
        expect(find.byKey(const ValueKey('selection-count')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('exit-selection')));
        await tester.pumpAndSettle();
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
        await dispose(tester, gateway);
      }
    },
  );

  testWidgets('page sorting persists and changes the photo order', (
    tester,
  ) async {
    final gateway = _Gateway(image);
    await mount(tester, gateway);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('photo-p0'))).dx,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('photo-p2'))).dx),
    );
    await menu(tester, 'sort');
    await tester.tap(find.byKey(const ValueKey('library-sort-name_desc')));
    await tester.pumpAndSettle();
    expect(gateway.preferences['order'], 'name_desc');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('photo-p2'))).dx,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('photo-p0'))).dx),
    );
    await menu(tester, 'sort');
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('library-sort-name_desc')),
          )
          .selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await dispose(tester, gateway);
  });

  testWidgets(
    'cover action selects a real album photo and supports cancellation and retry',
    (tester) async {
      final gateway = _Gateway(image);
      await mount(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('library-options')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem>(
              find.byKey(const ValueKey('library-menu-cover')),
            )
            .enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sidebar-album-/local/photos')),
      );
      await tester.pumpAndSettle();
      await menu(tester, 'cover');
      await tester.tap(find.byKey(const ValueKey('cancel-cover-selection')));
      await tester.pumpAndSettle();
      expect(gateway.coverWrites, isEmpty);
      await menu(tester, 'cover');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cancel-cover-selection')),
        findsNothing,
      );
      expect(gateway.coverWrites, isEmpty);
      await menu(tester, 'cover');
      gateway.failCover = true;
      await tester.tap(find.byKey(const ValueKey('photo-p1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cancel-cover-selection')),
        findsOneWidget,
      );
      expect(gateway.coverWrites, isEmpty);
      gateway.failCover = false;
      await tester.tap(find.byKey(const ValueKey('photo-p1')));
      await tester.pumpAndSettle();
      expect(gateway.coverWrites.single, {
        'op': 'albumCover',
        'folder': '/local/photos',
        'id': 'p1',
      });
      expect(
        find.byKey(const ValueKey('cancel-cover-selection')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('viewer')), findsNothing);
      expect(gateway.covers['/local/photos'], 'p1');
      expect(tester.takeException(), isNull);
      await dispose(tester, gateway);
    },
  );
}
