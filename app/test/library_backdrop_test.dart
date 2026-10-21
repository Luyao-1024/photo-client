import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/ui/glass_theme.dart';
import 'package:photo_client/ui/library_backdrop.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/local_photo_image.dart';
import 'package:photo_client/ui/photo_theme.dart';
import 'package:photo_client/ui/runtime_controller.dart';

import 'fakes/local_gateway.dart';

class _Library extends LocalLibraryController {
  _Library(this.initial);
  final LibraryViewState initial;
  @override
  LibraryViewState build() => initial;
  void show(LibraryViewState value) => state = value;
}

class _Gateway extends FakeLocalGateway {
  _Gateway() : super(imagePath: 'unused', count: 4);
  final requests = <String>[];
  final pending = <String, Completer<String>>{};
  @override
  Future<String> thumbnail(String id, {int sizeClass = 512}) {
    requests.add('$id:$sizeClass');
    return pending.putIfAbsent(id, Completer<String>.new).future;
  }
}

void main() {
  late Directory fixtures;
  final images = <String, String>{};
  setUpAll(() {
    fixtures = Directory.systemTemp.createTempSync('photo-background-');
    final variants = <String>[
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAALUlEQVR4nGM84WbEQEvARFPTRy0YtWDUglELRi0YtWDUglELRi0YtWDUAioCALcmAYBPXyeHAAAAAElFTkSuQmCC',
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAALUlEQVR4nGPUSLnEQEvARFPTRy0YtWDUglELRi0YtWDUglELRi0YtWDUAioCACGIAZ4VvB4TAAAAAElFTkSuQmCC',
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAALUlEQVR4nGM02hLFQEvARFPTRy0YtWDUglELRi0YtWDUglELRi0YtWDUAioCALZoAYCYcP5WAAAAAElFTkSuQmCC',
    ];
    var variant = 0;
    for (final id in ['p0', 'p1', 'p2', 'p3', 'off-page']) {
      final path = '${fixtures.path}/$id.png';
      File(
        path,
      ).writeAsBytesSync(base64Decode(variants[variant++ % variants.length]));
      images[id] = path;
    }
  });
  tearDownAll(() => fixtures.deleteSync(recursive: true));

  Future<void> mount(
    WidgetTester tester,
    _Gateway gateway,
    _Library library,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreGatewayProvider.overrideWithValue(gateway),
          localLibraryProvider.overrideWith(() => library),
        ],
        child: const MaterialApp(
          home: LibraryBackdrop(child: SizedBox.expand()),
        ),
      ),
    );
  }

  ImageProvider? displayed(WidgetTester tester) =>
      tester.widget<GlassBackdrop>(find.byType(GlassBackdrop)).image;
  String? displayedId(WidgetTester tester) {
    final image = displayed(tester) as ResizeImage?;
    return image?.imageProvider is LocalPhotoImage
        ? (image!.imageProvider as LocalPhotoImage).mediaId
        : null;
  }

  Future<void> complete(
    WidgetTester tester,
    _Gateway gateway,
    String id, {
    LocalPhoto? photo,
  }) async {
    final provider = ResizeImage(
      photo == null
          ? FileImage(File(images[id]!))
          : LocalPhotoImage(images[id]!, photo),
      width: 512,
    );
    await tester.runAsync(
      () =>
          precacheImage(provider, tester.element(find.byType(LibraryBackdrop))),
    );
    gateway.pending[id]!.complete(images[id]);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester, _Gateway gateway) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.changes.close();
    await gateway.events.close();
  }

  testWidgets('saved album cover is decoded before replacing the background', (
    tester,
  ) async {
    final gateway = _Gateway();
    final library = _Library(
      LibraryViewState(
        queryEpoch: 1,
        extent: 100,
        loading: false,
        folder: '/album',
        pages: {0: gateway.photos},
        albums: const [
          LocalAlbum(
            path: '/album',
            name: 'Album',
            count: 100,
            coverMediaId: 'off-page',
          ),
        ],
      ),
    );
    await mount(tester, gateway, library);
    expect(gateway.requests, ['off-page:512']);
    await complete(tester, gateway, 'off-page');
    final old = displayed(tester);
    expect(
      ((old as ResizeImage).imageProvider as FileImage).file.path,
      images['off-page'],
    );
    library.show(
      LibraryViewState(
        queryEpoch: 1,
        extent: 100,
        loading: false,
        folder: '/album',
        pages: {0: gateway.photos},
        albums: const [
          LocalAlbum(
            path: '/album',
            name: 'Album',
            count: 100,
            coverMediaId: 'p1',
          ),
        ],
      ),
    );
    await tester.pump();
    expect(displayed(tester), old);
    await complete(tester, gateway, 'p1', photo: gateway.photos[1]);
    expect(displayedId(tester), 'p1');
    expect(gateway.requests, ['off-page:512', 'p1:512']);
    await dispose(tester, gateway);
  });

  testWidgets(
    'slow stale and failed album loads retain the last complete photo',
    (tester) async {
      final gateway = _Gateway();
      final library = _Library(
        LibraryViewState(
          queryEpoch: 1,
          extent: 1,
          loading: false,
          pages: {
            0: [gateway.photos[0]],
          },
        ),
      );
      await mount(tester, gateway, library);
      await complete(tester, gateway, 'p0', photo: gateway.photos[0]);
      library.show(
        const LibraryViewState(queryEpoch: 1, extent: 1, loading: false),
      );
      await tester.pump();
      expect(gateway.requests, ['p0:512']);
      library.show(const LibraryViewState(queryEpoch: 2, loading: true));
      await tester.pump();
      expect(displayedId(tester), 'p0');
      library.show(
        LibraryViewState(
          queryEpoch: 2,
          extent: 1,
          loading: false,
          pages: {
            0: [gateway.photos[1]],
          },
        ),
      );
      await tester.pump();
      library.show(
        LibraryViewState(
          queryEpoch: 3,
          extent: 1,
          loading: false,
          pages: {
            0: [gateway.photos[2]],
          },
        ),
      );
      await tester.pump();
      await complete(tester, gateway, 'p1', photo: gateway.photos[1]);
      expect(displayedId(tester), 'p0');
      gateway.pending['p2']!.completeError(StateError('unavailable cover'));
      await tester.pumpAndSettle();
      expect(displayedId(tester), 'p0');
      library.show(
        LibraryViewState(
          queryEpoch: 4,
          extent: 1,
          loading: false,
          pages: {
            0: [gateway.photos[3]],
          },
        ),
      );
      await tester.pump();
      await complete(tester, gateway, 'p3', photo: gateway.photos[3]);
      expect(displayedId(tester), 'p3');
      library.show(
        const LibraryViewState(
          queryEpoch: 5,
          extent: 1,
          loading: false,
          trashed: true,
        ),
      );
      await tester.pump();
      expect(displayed(tester), isNull);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      await dispose(tester, gateway);
    },
  );

  Widget scene(
    ImageProvider image, {
    bool reduceMotion = false,
    bool highContrast = false,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduceMotion,
        highContrast: highContrast,
      ),
      child: GlassBackdrop(image: image, child: const SizedBox.expand()),
    ),
  );

  Future<void> warm(WidgetTester tester, ImageProvider image) =>
      tester.runAsync(
        () => precacheImage(image, tester.element(find.byType(GlassBackdrop))),
      );

  testWidgets(
    'crossfade keeps its old photo opaque and queues only the latest target',
    (tester) async {
      final a = FileImage(File(images['p0']!));
      final b = FileImage(File(images['p1']!));
      final c = FileImage(File(images['p2']!));
      await tester.pumpWidget(scene(a, highContrast: true));
      await warm(tester, a);
      await warm(tester, b);
      await warm(tester, c);
      await tester.pumpWidget(scene(a));
      await tester.pumpWidget(scene(b));
      await tester.pump(const Duration(milliseconds: 210));
      expect(find.byType(ImageFiltered), findsNWidgets(2));
      final outgoing = find.byWidgetPredicate(
        (widget) => widget is Image && widget.image == a,
      );
      expect(
        tester
            .widgetList<FadeTransition>(
              find.ancestor(
                of: outgoing,
                matching: find.byType(FadeTransition),
              ),
            )
            .every((fade) => fade.opacity.value == 1),
        isTrue,
      );
      final fade = find.descendant(
        of: find.byType(GlassBackdrop),
        matching: find.byType(FadeTransition),
      );
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpWidget(scene(c));
      expect(
        tester.widgetList<Image>(find.byType(Image)).map((w) => w.image),
        containsAll([a, b]),
      );
      expect(
        tester.widgetList<Image>(find.byType(Image)).map((w) => w.image),
        isNot(contains(c)),
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump(const Duration(milliseconds: 210));
      expect(find.byType(ImageFiltered), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(tester.widgetList<Image>(find.byType(Image)).map((w) => w.image), [
        c,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion switches immediately and high contrast omits the image',
    (tester) async {
      final a = FileImage(File(images['p0']!));
      final b = FileImage(File(images['p1']!));
      await tester.pumpWidget(scene(a, reduceMotion: true, highContrast: true));
      await warm(tester, a);
      await warm(tester, b);
      await tester.pumpWidget(scene(a, reduceMotion: true));
      await tester.pumpWidget(scene(b, reduceMotion: true));
      expect(tester.widgetList<Image>(find.byType(Image)).map((w) => w.image), [
        b,
      ]);
      expect(find.byType(ImageFiltered), findsOneWidget);
      await tester.pumpWidget(scene(b, highContrast: true));
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('album image covers the whole window in either neutral theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final image = FileImage(File(images['p0']!));
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: photoTheme(brightness),
          home: GlassBackdrop(image: image, child: const SizedBox.expand()),
        ),
      );
      await warm(tester, image);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(ImageFiltered)),
        const Rect.fromLTWH(0, 0, 1600, 900),
      );
      final scrims = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .where((box) => box.color.a > 0 && box.color.a < 1);
      expect(scrims, isNotEmpty);
      for (final scrim in scrims) {
        expect(scrim.color.r, scrim.color.g);
        expect(scrim.color.g, scrim.color.b);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
