import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/ui/local_video_stage.dart';
import 'package:photo_client/ui/runtime_controller.dart';

import 'fakes/local_gateway.dart';
import 'helpers/filmstrip_frames.dart';

class _Video implements VideoPlaybackSession {
  final completions = StreamController<bool>.broadcast();
  final playbackChanges = StreamController<bool>.broadcast();
  bool disposed = false;
  int plays = 0;
  @override
  Future<void> open(String path) async {}
  @override
  Future<void> get firstFrame async {}
  @override
  Future<void> play() async {
    plays++;
    playbackChanges.add(true);
  }

  @override
  Future<void> toggle() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await completions.close();
    await playbackChanges.close();
  }

  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Stream<bool> get completed => completions.stream;
  @override
  Stream<bool> get playback => playbackChanges.stream;
  @override
  bool get playing => plays > 0;
  @override
  Duration get position => Duration.zero;
  @override
  Widget buildVideo(GlobalKey<VideoState> key) =>
      const ColoredBox(color: Colors.blue);
}

class _Gateway extends FakeToolsGateway {
  _Gateway({required super.imagePath, this.autoPlay = false});
  final bool autoPlay;
  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    if (command['op'] == 'metadata') {
      final photo = photos.firstWhere((photo) => photo.id == command['id']);
      return {
        'motion_offset': photo.motionOffset,
        'animated': false,
        'hdr': false,
      };
    }
    if (command['op'] == 'motionVideo') return 'motion.mp4';
    final result = await super.localCommand(command);
    if (command['op'] == 'preferences') {
      return {...result as Map, 'autoPlayMotionPhoto': autoPlay};
    }
    return result;
  }
}

void main() {
  late Directory fixtures;
  late String image;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-viewer-playback-');
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
    _Gateway gateway,
    List<_Video> sessions, {
    void Function(FakeLocalGateway gateway)? configure,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });
    gateway.photos = [
      gateway.photo(0, motionOffset: 12),
      gateway.photo(
        1,
        mediaKind: 'video',
        mimeType: 'video/mp4',
        width: 1600,
        height: 900,
      ),
      gateway.photo(2),
    ];
    configure?.call(gateway);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreGatewayProvider.overrideWithValue(gateway),
          videoSessionFactoryProvider.overrideWithValue(() {
            final session = _Video();
            sessions.add(session);
            return session;
          }),
        ],
        child: PhotoClientApp(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await gateway.changes.close();
      await gateway.events.close();
    });
  }

  void expectPlaybackLayout(WidgetTester tester) {
    final controls = tester.widget<MaterialDesktopVideoControlsTheme>(
      find.byType(MaterialDesktopVideoControlsTheme),
    );
    expect(controls.normal.padding, const EdgeInsets.only(bottom: 104));
    final scheme = Theme.of(tester.element(find.byType(LocalVideoStage)))
        .colorScheme;
    for (final theme in [controls.normal, controls.fullscreen]) {
      expect(theme.seekBarPositionColor, scheme.primary);
      expect(theme.seekBarThumbColor, scheme.primary);
      expect(theme.seekBarPositionColor, isNot(const Color(0xffff0000)));
      expect(
        theme.bottomButtonBar.whereType<MaterialDesktopFullscreenButton>(),
        isEmpty,
      );
    }
    expect(controls.fullscreen.padding, isNull);
  }

  double filmstripOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .descendant(
              of: find.byKey(const ValueKey('viewer-filmstrip-fade')),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  for (final autoPlay in [false, true]) {
    testWidgets(
      'motion completion restores the same photo and allows replay (autoplay=$autoPlay)',
      (tester) async {
        final sessions = <_Video>[];
        final gateway = _Gateway(imagePath: image, autoPlay: autoPlay);
        await mount(tester, gateway, sessions);
        await tester.tap(find.byKey(const ValueKey('photo-p0')));
        await tester.pumpAndSettle();
        final strip = tester.getRect(
          find.byKey(const ValueKey('viewer-filmstrip')),
        );
        await waitForFilmstripFrames(tester);
        await tester.pumpAndSettle();
        if (!autoPlay) {
          expect(
            tester.widget(find.byKey(const ValueKey('viewer-motion-toggle'))),
            isA<IconButton>(),
          );
          // The motion control lives in the header, immediately left of the
          // favorite action.
          final motion = tester.getRect(
            find.byKey(const ValueKey('viewer-motion-toggle')),
          );
          final favorite = tester.getRect(
            find.byKey(const ValueKey('viewer-favorite')),
          );
          expect(motion.right, lessThanOrEqualTo(favorite.left));
          expect(motion.center.dy, closeTo(favorite.center.dy, .01));
          expect(find.text('Play motion photo'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('viewer-motion-toggle')));
          await tester.pumpAndSettle();
        }
        for (var replay = 0; replay < 2; replay++) {
          expect(
            find.byKey(const ValueKey('viewer-motion-video')),
            findsOneWidget,
          );
          expect(sessions.last.plays, 1);
          expect(
            find.byKey(const ValueKey('viewer-motion-toggle')),
            findsNothing,
          );
          expect(find.text('Show photo'), findsNothing);
          expectPlaybackLayout(tester);
          expect(filmstripOpacity(tester), 0);
          expect(
            tester.getRect(find.byKey(const ValueKey('viewer-filmstrip'))),
            strip,
          );
          sessions.last.completions.add(false);
          await tester.pump();
          expect(
            find.byKey(const ValueKey('viewer-motion-video')),
            findsOneWidget,
          );
          sessions.last.completions.add(true);
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(filmstripOpacity(tester), allOf(greaterThan(0), lessThan(1)));
          await tester.pumpAndSettle();
          expect(filmstripOpacity(tester), 1);
          expect(
            find.byKey(const ValueKey('viewer-motion-video')),
            findsNothing,
          );
          expect(find.byType(InteractiveViewer), findsOneWidget);
          expect(find.byKey(const ValueKey('viewer')), findsOneWidget);
          expect(find.text('1 / 3'), findsOneWidget);
          expect(sessions.last.disposed, isTrue);
          expect(
            tester.widget(find.byKey(const ValueKey('viewer-motion-toggle'))),
            isA<IconButton>(),
          );
          expect(
            tester.getRect(find.byKey(const ValueKey('viewer-filmstrip'))),
            strip,
          );
          if (replay == 0) {
            await tester.tap(find.byKey(const ValueKey('viewer-details')));
            await tester.pumpAndSettle();
            expect(
              tester.widget(
                find.byKey(const ValueKey('viewer-details-motion-toggle')),
              ),
              isA<IconButton>(),
            );
            await tester.tap(
              find.byKey(const ValueKey('viewer-details-motion-toggle')),
            );
            await tester.pumpAndSettle();
          }
        }
        expect(sessions, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('long-pressing with ${kind.name} plays while held', (
      tester,
    ) async {
      final sessions = <_Video>[];
      await mount(tester, _Gateway(imagePath: image), sessions);
      await tester.tap(find.byKey(const ValueKey('photo-p0')));
      await tester.pumpAndSettle();
      await waitForFilmstripFrames(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-motion-video')), findsNothing);

      final hold = await tester.startGesture(
        tester.getCenter(find.byType(InteractiveViewer)),
        kind: kind,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-motion-video')), findsOneWidget);
      expect(sessions.single.plays, 1);

      await hold.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-motion-video')), findsNothing);
      expect(
        find.byKey(const ValueKey('viewer-motion-toggle')),
        findsOneWidget,
      );
      expect(sessions.single.disposed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('video shares the blurred fill and framed stage of stills', (
    tester,
  ) async {
    final sessions = <_Video>[];
    await mount(tester, _Gateway(imagePath: image), sessions);
    await tester.tap(find.byKey(const ValueKey('photo-p1')));
    await tester.pumpAndSettle();
    // Let the filmstrip finish decoding so later tests share warm caches.
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();

    final viewport = tester.getRect(
      find.byKey(const ValueKey('viewer-stage-switcher')),
    );
    final frame = tester.getRect(
      find.byKey(const ValueKey('viewer-photo-frame')),
    );
    // The 16:9 video spans the viewport width and leaves fill above/below.
    expect(frame.width / frame.height, closeTo(16 / 9, .01));
    expect(frame.width, closeTo(viewport.width, 1));
    expect(frame.height, lessThan(viewport.height));
    expect(tester.getRect(find.byType(LocalVideoStage)), frame);
    expect(
      find.byKey(const ValueKey('viewer-video-fill-blur')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('viewer-video-fill-scrim')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(LocalVideoStage),
        matching: find.byKey(const ValueKey('viewer-video-fill-blur')),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video-to-video switching cross-fades without key collisions', (
    tester,
  ) async {
    final sessions = <_Video>[];
    await mount(
      tester,
      _Gateway(imagePath: image),
      sessions,
      configure: (gateway) {
        gateway.photos = [
          for (var index = 0; index < 2; index++)
            gateway.photo(
              index,
              mediaKind: 'video',
              mimeType: 'video/mp4',
              width: 1600,
              height: 900,
            ),
        ];
      },
    );
    await tester.tap(find.byKey(const ValueKey('photo-p0')));
    await tester.pumpAndSettle();
    await waitForFilmstripFrames(tester);
    await tester.pumpAndSettle();
    expect(sessions, hasLength(1));

    // Both stages hold a video while fading, so each needs its own GlobalKey.
    await tester.tap(find.byKey(const ValueKey('viewer-next')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byType(LocalVideoStage), findsOneWidget);
    expect(sessions, hasLength(2));
    expect(sessions.first.disposed, isTrue);
  });

  testWidgets(
    'ordinary video shares the playback layout and stays in its viewer after completion',
    (tester) async {
      final sessions = <_Video>[];
      await mount(tester, _Gateway(imagePath: image), sessions);
      await tester.tap(find.byKey(const ValueKey('photo-p1')));
      await tester.pumpAndSettle();
      await waitForFilmstripFrames(tester);
      await tester.pumpAndSettle();
      expectPlaybackLayout(tester);
      expect(filmstripOpacity(tester), 0);
      final stage = tester.getRect(find.byType(LocalVideoStage));
      await tester.tap(find.byKey(const ValueKey('viewer-immersive')));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      final immersiveControls = tester
          .widget<MaterialDesktopVideoControlsTheme>(
            find.byType(MaterialDesktopVideoControlsTheme),
          );
      expect(immersiveControls.normal.padding, EdgeInsets.zero);
      expect(tester.getRect(find.byType(LocalVideoStage)), stage);
      expect(sessions, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expectPlaybackLayout(tester);
      expect(sessions, hasLength(1));
      sessions.single.completions.add(true);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(filmstripOpacity(tester), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(filmstripOpacity(tester), 1);
      // Replaying the same video hides the strip with a fade again.
      sessions.single.completions.add(false);
      sessions.single.playbackChanges.add(true);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(filmstripOpacity(tester), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(filmstripOpacity(tester), 0);
      expect(find.byKey(const ValueKey('viewer-video')), findsOneWidget);
      expect(sessions.single.disposed, isFalse);
      await tester.tap(find.byKey(const ValueKey('viewer-next')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalVideoStage), findsNothing);
      expect(sessions.single.disposed, isTrue);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
