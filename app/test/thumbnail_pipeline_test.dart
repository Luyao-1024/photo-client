import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/services/thumbnail_pipeline.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/ui/thumbnail_progress.dart';
import 'package:photo_client/ui/photos_grid.dart';
import 'package:photo_client/ui/local_media_tile.dart';

import 'fakes/local_gateway.dart';

class _Native extends FakeLocalGateway implements ThumbnailPipelineGateway {
  _Native({super.count = 3}) : super(imagePath: 'unused');
  String? embeddedPath = 'embedded.jpg';
  final commands = <Map<String, Object?>>[];
  final pending = <String, Completer<String>>{};
  @override
  Future<Object?> thumbnailCommand(Map<String, Object?> command) async {
    commands.add(command);
    if (command['op'] == 'thumbnailRequest') {
      final token = command['token']! as String;
      return pending.putIfAbsent(token, Completer<String>.new).future;
    }
    if (command['op'] == 'thumbnailEmbedded') return embeddedPath;
    return null;
  }

  List<Map<String, Object?>> ops(String name) =>
      commands.where((c) => c['op'] == name).toList();
}

void main() {
  test('cover sizing accounts for crop aspect ratio without exceeding native classes', () {
    const photo = LocalPhoto(
      id: 'portrait',
      path: 'fixture.jpg',
      name: 'portrait',
      parent: 'fixture',
      sizeBytes: 1,
      modifiedMs: 0,
      contentVersion: 1,
      width: 1200,
      height: 2700,
      favorite: false,
    );
    expect(thumbnailSizeClassForCover(200, photo), 512);
    expect(thumbnailSizeClassForCover(80, photo), 256);
    expect(thumbnailSizeClassForCover(2000, photo), 1024);
  });
  test(
    'album-cover requests cancel through the same native scheduler',
    () async {
      final gateway = _Native();
      final cover = MediaThumbnailHandle(gateway, 'p0', 256);
      expect(gateway.ops('thumbnailRequest').single['tier'], 1);
      cover.release();
      cover.release();
      expect(gateway.ops('thumbnailCancel'), hasLength(1));
      gateway.pending.values.single.complete('cached.jpg');
      await cover.future;
      ThumbnailPool.forGateway(gateway).clear();
    },
  );
  testWidgets('pending batches drain on the next frame', (tester) async {
    final gateway = _Native(count: 32);
    final pool = ThumbnailPool.forGateway(gateway);
    final handles = [
      for (final photo in gateway.photos) pool.acquire(photo, 256),
    ];
    expect(gateway.ops('thumbnailRequest'), hasLength(24));
    await tester.pump();
    expect(gateway.ops('thumbnailRequest'), hasLength(32));
    for (final pending in gateway.pending.values) {
      pending.complete('cached.jpg');
    }
    await tester.pump();
    for (final handle in handles) {
      handle.release();
    }
    pool.clear();
  });

  test(
    'grid and viewer share one request and only the last observer cancels',
    () async {
      final gateway = _Native();
      final pool = ThumbnailPool.forGateway(gateway);
      final a = pool.acquire(gateway.photos[0], 256);
      final b = pool.acquire(gateway.photos[0], 256);
      expect(gateway.ops('thumbnailRequest'), hasLength(1));
      a.release();
      expect(gateway.ops('thumbnailCancel'), isEmpty);
      b.release();
      expect(gateway.ops('thumbnailCancel'), hasLength(1));
      gateway.pending.values.single.complete('orphan.jpg');
      await b.future;
      final c = pool.acquire(gateway.photos[0], 256);
      expect(gateway.ops('thumbnailRequest'), hasLength(2));
      gateway.pending.values.last.complete('current.jpg');
      await c.future;
      expect(c.path, 'current.jpg');
      c.release();
      pool.clear();
    },
  );
  test(
    'completed paths are immediately available after a tile is recycled',
    () async {
      final gateway = _Native();
      final pool = ThumbnailPool.forGateway(gateway);
      final a = pool.acquire(gateway.photos[0], 256);
      gateway.pending.values.single.complete('ready.jpg');
      await a.future;
      a.release();
      final b = pool.acquire(gateway.photos[0], 256);
      expect(b.path, 'ready.jpg');
      expect(gateway.ops('thumbnailRequest'), hasLength(1));
      b.release();
      pool.clear();
    },
  );
  test('visible observers promote a pending background request', () async {
    final gateway = _Native();
    final pool = ThumbnailPool.forGateway(gateway);
    final background = pool.acquire(gateway.photos[0], 512, priority: 1);
    final visible = pool.acquire(gateway.photos[0], 512);
    expect(gateway.ops('thumbnailRequest'), hasLength(1));
    expect(gateway.ops('thumbnailPromote'), hasLength(1));
    gateway.pending.values.single.complete('ready.jpg');
    await visible.future;
    background.release();
    visible.release();
    pool.clear();
  });
  test(
    'retry invalidates a bad disk cache before asking for it again',
    () async {
      final gateway = _Native();
      final pool = ThumbnailPool.forGateway(gateway);
      final a = pool.acquire(gateway.photos[0], 256);
      gateway.pending.values.single.complete('bad.jpg');
      await a.future;
      await a.invalidate();
      a.release();
      final b = pool.acquire(gateway.photos[0], 256);
      expect(gateway.ops('thumbnailInvalidate'), hasLength(1));
      expect(gateway.ops('thumbnailRequest'), hasLength(2));
      gateway.pending.values.last.complete('repaired.jpg');
      await b.future;
      b.release();
      pool.clear();
    },
  );
  test(
    'EXIF placeholders are shared and do not complete full thumbnails',
    () async {
      final gateway = _Native();
      final pool = ThumbnailPool.forGateway(gateway);
      final a = pool.acquire(gateway.photos[0], 256);
      final b = pool.acquire(gateway.photos[0], 512);
      expect(await a.placeholder, 'embedded.jpg');
      expect(await b.placeholder, 'embedded.jpg');
      expect(gateway.ops('thumbnailEmbedded'), hasLength(1));
      expect(a.path, isNull);
      for (final pending in gateway.pending.values) {
        pending.complete('ready.jpg');
      }
      await Future.wait([a.future, b.future]);
      a.release();
      b.release();
      pool.clear();
    },
  );
  testWidgets(
    'prewarm follows the most recent viewport without issuing requests every frame',
    (tester) async {
      final gateway = _Native();
      final pool = ThumbnailPool.forGateway(gateway);
      pool.viewport('old', 256);
      pool.viewport('current', 512);
      expect(gateway.ops('thumbnailViewport'), isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.ops('thumbnailViewport'), [
        {'op': 'thumbnailViewport', 'id': 'current', 'size': 512},
      ]);
      pool.viewport('current', 512);
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.ops('thumbnailViewport'), hasLength(1));
      pool.clear();
    },
  );
  testWidgets(
    'dense grid requests are limited to 24 per frame and recycled queued tiles never submit',
    (tester) async {
      final gateway = _Native(count: 32);
      final pool = ThumbnailPool.forGateway(gateway);
      final handles = [
        for (final photo in gateway.photos) pool.acquire(photo, 256),
      ];
      expect(gateway.ops('thumbnailRequest'), hasLength(24));
      for (final handle in handles.skip(24)) {
        handle.release();
      }
      await tester.pump();
      expect(gateway.ops('thumbnailRequest'), hasLength(24));
      expect(gateway.ops('thumbnailCancel'), isEmpty);
      for (final pending in gateway.pending.values) {
        pending.complete('cached.jpg');
      }
      await tester.pump();
      for (final handle in handles.take(24)) {
        handle.release();
      }
      pool.clear();
    },
  );
  for (final legacyTile in [false, true]) {
    testWidgets(
      'recycled ${legacyTile ? "compact" : "photo"} tiles release pending native work',
      (tester) async {
        final first = _Native()..embeddedPath = null;
        final second = _Native()..embeddedPath = null;
        Widget host(_Native gateway) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 128,
              height: 128,
              child: legacyTile
                  ? LocalMediaTile(
                      key: const ValueKey('tile'),
                      photo: gateway.photos[0],
                      gateway: gateway,
                      onOpen: () {},
                    )
                  : PhotoTile(
                      key: const ValueKey('tile'),
                      photo: gateway.photos[0],
                      gateway: gateway,
                      selected: false,
                      multiSelect: false,
                      onOpen: () {},
                      onSelectToggle: () {},
                      onEnterSelection: () {},
                      onToggleFavorite: () {},
                      onShowDetails: () {},
                    ),
            ),
          ),
        );
        await tester.pumpWidget(host(first));
        await tester.pump();
        expect(first.ops('thumbnailRequest'), hasLength(1));
        await tester.pumpWidget(host(second));
        await tester.pump();
        expect(first.ops('thumbnailCancel'), hasLength(1));
        expect(second.ops('thumbnailRequest'), hasLength(1));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(second.ops('thumbnailCancel'), hasLength(1));
        for (final gateway in [first, second]) {
          for (final pending in gateway.pending.values) {
            pending.complete('unused.jpg');
          }
          ThumbnailPool.forGateway(gateway).clear();
        }
        await tester.pump();
      },
    );
  }
  testWidgets('generation progress updates and disappears when complete', (
    tester,
  ) async {
    Widget host(int ready) => ProviderScope(
      key: ValueKey(ready),
      overrides: [
        thumbnailProgressProvider.overrideWith(
          (ref) => Stream.value({'total': 3, 'ready': ready, 'failed': 0}),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: ThumbnailProgress())),
    );
    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();
    expect(find.text('Thumbnails 1/3'), findsOneWidget);
    await tester.pumpWidget(host(3));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thumbnail-generation-progress')),
      findsNothing,
    );
  });
}
