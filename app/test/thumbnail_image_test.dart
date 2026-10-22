import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/thumbnail_image.dart';

import 'fakes/local_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late String path;
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('photo-decoded-cache-');
    path = '${scratch.path}/image.png';
    File(path).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAALUlEQVR4nGM84WbEQEvARFPTRy0YtWDUglELRi0YtWDUglELRi0YtWDUAioCALcmAYBPXyeHAAAAAElFTkSuQmCC',
      ),
    );
  });
  tearDown(() {
    ThumbnailImage.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDownAll(() => scratch.deleteSync(recursive: true));
  Future<ImageStreamCompleter> resolve(ThumbnailImage provider) async {
    final ready = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronous) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    await ready.future;
    stream.removeListener(listener);
    return stream.completer!;
  }

  testWidgets(
    'a decoded thumbnail survives viewer-original global cache eviction',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: path, count: 1);
      final provider = ThumbnailImage.file(path, gateway.photos.single);
      final first = await tester.runAsync(() => resolve(provider));
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final second = await tester.runAsync(
        () => resolve(ThumbnailImage.file(path, gateway.photos.single)),
      );
      expect(identical(first, second), isTrue);
    },
  );
  testWidgets(
    'a prewarmed decoded image promotes into foreground without disk decoding',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: path, count: 1);
      final background = ThumbnailImage.file(
        path,
        gateway.photos.single,
        width: 128,
        use: ThumbnailUse.background,
      );
      final first = await tester.runAsync(() => resolve(background));
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final foreground = ThumbnailImage.file(
        path,
        gateway.photos.single,
        width: 128,
      );
      final second = await tester.runAsync(() => resolve(foreground));
      expect(identical(first, second), isTrue);
      expect(ThumbnailImage.counts[ThumbnailUse.background], 0);
      expect(ThumbnailImage.counts[ThumbnailUse.foreground], 1);
    },
  );
  testWidgets(
    'background cache churn cannot evict foreground decoded thumbnails',
    (tester) async {
      final gateway = FakeLocalGateway(imagePath: path, count: 72);
      final foreground = ThumbnailImage.file(path, gateway.photos.first);
      final first = await tester.runAsync(() => resolve(foreground));
      await tester.runAsync(() async {
        for (final photo in gateway.photos) {
          await resolve(
            ThumbnailImage.file(path, photo, use: ThumbnailUse.background),
          );
        }
      });
      expect(ThumbnailImage.counts[ThumbnailUse.foreground], 1);
      expect(ThumbnailImage.counts[ThumbnailUse.background], 64);
      final again = await tester.runAsync(() => resolve(foreground));
      expect(identical(first, again), isTrue);
    },
  );
}
