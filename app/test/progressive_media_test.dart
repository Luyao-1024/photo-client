import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_client/ui/progressive_image.dart';
import 'package:photo_client/ui/local_video_stage.dart';
import 'package:photo_client/ui/local_animated_stage.dart';

class _Image extends ImageProvider<_Image> {
  final ready = Completer<ImageInfo>();
  @override
  Future<_Image> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Image key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(ready.future);
}

class _Video implements VideoPlaybackSession {
  final opened = Completer<void>(), frame = Completer<void>();
  final failures = StreamController<String>.broadcast();
  final completions = StreamController<bool>.broadcast();
  bool disposed = false;
  int plays = 0;
  @override
  Future<void> open(String path) => opened.future;
  @override
  Future<void> get firstFrame => frame.future;
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> toggle() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(failures.close());
    unawaited(completions.close());
  }

  @override
  Stream<String> get errors => failures.stream;
  @override
  Stream<bool> get completed => completions.stream;
  @override
  Stream<bool> get playback => const Stream.empty();
  @override
  bool get playing => plays > 0;
  @override
  Duration get position => Duration.zero;
  @override
  Widget buildVideo(GlobalKey<VideoState> key) =>
      const ColoredBox(key: ValueKey('video-frame'), color: Colors.blue);
}

ui.Image pixel() {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.red, BlendMode.src);
  return recorder.endRecording().toImageSync(2, 2);
}

Widget host(Widget child) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(body: SizedBox.expand(child: child)),
  ),
);
void main() {
  testWidgets('thumbnail remains until the original has a decoded frame', (
    tester,
  ) async {
    final image = _Image();
    await tester.pumpWidget(
      host(
        ProgressiveImage(image: image, placeholder: const Text('thumbnail')),
      ),
    );
    expect(find.text('thumbnail'), findsOneWidget);
    image.ready.complete(ImageInfo(image: pixel()));
    await tester.pump();
    expect(find.text('thumbnail'), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });
  testWidgets('a stale original cannot replace the next media placeholder', (
    tester,
  ) async {
    final old = _Image(), current = _Image();
    await tester.pumpWidget(
      host(
        ProgressiveImage(image: old, placeholder: const Text('old thumbnail')),
      ),
    );
    await tester.pumpWidget(
      host(
        ProgressiveImage(
          image: current,
          placeholder: const Text('new thumbnail'),
        ),
      ),
    );
    old.ready.complete(ImageInfo(image: pixel()));
    await tester.pump();
    expect(find.text('new thumbnail'), findsOneWidget);
    current.ready.complete(ImageInfo(image: pixel()));
    await tester.pump();
    await tester.pump();
    expect(find.text('new thumbnail'), findsNothing);
  });
  testWidgets(
    'animation waits on its first decoded frame and retains it while the next loads',
    (tester) async {
      final first = _Image(), second = _Image();
      await tester.pumpWidget(
        host(
          AnimatedImageStage(
            frames: const [
              AnimatedFrame(path: 'first', delayMs: 40),
              AnimatedFrame(path: 'second', delayMs: 40),
            ],
            placeholder: const Text('static thumbnail'),
            frameProvider: (frame) => frame.path == 'first' ? first : second,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('static thumbnail'), findsOneWidget);
      first.ready.complete(ImageInfo(image: pixel()));
      await tester.pump();
      await tester.pump();
      expect(find.text('static thumbnail'), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('static thumbnail'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      second.ready.complete(ImageInfo(image: pixel()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'video and still share the full stage with filmstrip controls inset',
    (tester) async {
      final video = _Video();
      await tester.pumpWidget(
        host(
          LocalVideoStage(
            path: 'video.mp4',
            bottomInset: 104,
            sessionFactory: () => video,
            placeholder: const ColoredBox(
              key: ValueKey('static image'),
              color: Colors.red,
            ),
          ),
        ),
      );
      final stage = tester.getRect(find.byType(LocalVideoStage));
      expect(tester.getRect(find.byKey(const ValueKey('static image'))), stage);
      expect(tester.getRect(find.byKey(const ValueKey('video-frame'))), stage);
      final controls = tester.widget<MaterialDesktopVideoControlsTheme>(
        find.byType(MaterialDesktopVideoControlsTheme),
      );
      expect(controls.normal.padding, const EdgeInsets.only(bottom: 104));
      expect(controls.fullscreen.padding, isNull);
      expect(video.plays, 0);
      video.opened.complete();
      await tester.pump();
      expect(find.byKey(const ValueKey('static image')), findsOneWidget);
      expect(video.plays, 0);
      video.frame.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('static image')), findsNothing);
      expect(tester.getRect(find.byKey(const ValueKey('video-frame'))), stage);
      expect(video.plays, 1);
      await tester.pumpWidget(const SizedBox());
      expect(video.disposed, isTrue);
    },
  );
  testWidgets('late first frames from an old video never reveal or start it', (
    tester,
  ) async {
    final old = _Video(), current = _Video();
    await tester.pumpWidget(
      host(
        LocalVideoStage(
          path: 'old.mp4',
          sessionFactory: () => old,
          placeholder: const Text('old still'),
        ),
      ),
    );
    old.opened.complete();
    await tester.pump();
    await tester.pumpWidget(
      host(
        LocalVideoStage(
          path: 'new.mp4',
          sessionFactory: () => current,
          placeholder: const Text('new still'),
        ),
      ),
    );
    current.opened.complete();
    old.frame.complete();
    await tester.pump();
    expect(old.plays, 0);
    expect(old.disposed, isTrue);
    expect(find.text('new still'), findsOneWidget);
    current.frame.complete();
    await tester.pump();
    await tester.pump();
    expect(current.plays, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
