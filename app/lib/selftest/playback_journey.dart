part of 'local_journey.dart';

/// Native codec/texture/callback regression, independent of the full UX matrix.
extension PlaybackLifecycleJourney on LocalJourney {
  Future<void> _playbackLifecycleJourney({
    int cycles = 6,
    bool hoverChecks = false,
  }) async {
    final controller = _container!.read(localLibraryProvider.notifier);
    await _step('playback-fixtures', () async {
      if (options.sources.isEmpty) {
        throw JourneyFailure('a test source is required');
      }
      await _library!.addPaths(options.sources);
      await controller.refresh(force: true);
    });
    final videos = await _library!.listPhotos(mediaKind: 'video', limit: 1);
    final motions = await _library!.listPhotos(mediaKind: 'motion', limit: 1);
    if (videos.items.isEmpty || motions.items.isEmpty) {
      throw JourneyFailure(
        'the source must contain a video and a motion photo',
      );
    }

    Future<void> open(LocalPhoto photo, String? kind) async {
      await controller.showDestination(kind: kind);
      await _waitFor(
        () => !_state.loading,
        reason: 'playback query did not settle',
      );
      await _waitForElement(
        'photo-${photo.id}',
        reason: 'the playback tile is missing',
      );
      await _tapKey('photo-${photo.id}');
      await _waitForElement(
        'viewer',
        reason: 'the playback viewer did not open',
      );
    }

    for (var cycle = 0; cycle < cycles; cycle++) {
      await _step('native-video-cycle-$cycle', () async {
        await open(videos.items.first, hoverChecks ? null : 'video');
        await _uxWaitVideoPlaying(
          'viewer-video',
          true,
          'native video did not play',
        );
        await _uxWaitUntil(
          () =>
              (_uxVideoState('viewer-video')?.position ?? Duration.zero) >
              const Duration(milliseconds: 100),
          reason: 'native video did not advance',
        );
        if (hoverChecks) await _playbackHoverChecks();
        await _tapKey('viewer-close');
        await _uxWaitGone('viewer', 'the video viewer did not close');
      });
      await _step('native-motion-cycle-$cycle', () async {
        await open(motions.items.first, 'motion');
        await _waitForElement(
          'viewer-motion-toggle',
          reason: 'motion Play is missing',
        );
        await _tapKey('viewer-motion-toggle');
        await _uxWaitVideoPlaying(
          'viewer-motion-video',
          true,
          'native motion did not play',
        );
        await _uxWaitGone(
          'viewer-motion-video',
          'native motion did not finish',
        );
        await _waitForElement(
          'viewer-motion-toggle',
          reason: 'the still photo did not return',
        );
        await _tapKey('viewer-close');
        await _uxWaitGone('viewer', 'the motion viewer did not close');
      });
    }

    await _step('native-exit-during-playback', () async {
      await open(videos.items.first, 'video');
      await _uxWaitVideoPlaying(
        'viewer-video',
        true,
        'the exit fixture did not play',
      );
      final libraries = File('/proc/self/maps')
          .readAsLinesSync()
          .where((line) => line.contains('/libmpv.so'))
          .map((line) => line.trim().split(RegExp(r'\s+')).last)
          .toSet();
      facts['mpv_libraries'] = libraries.toList();
      if (libraries.length != 1) {
        throw JourneyFailure('multiple libmpv copies were loaded: $libraries');
      }
      facts['video_cycles'] = cycles;
      facts['motion_cycles'] = cycles;
      facts['native_exit_during_playback'] = true;
    });
  }

  double _playbackAlpha(String key) {
    final render = _elementByKey(ValueKey(key))?.findRenderObject();
    return render is RenderAnimatedOpacity ? render.opacity.value : -1;
  }

  Future<void> _playbackHoverChecks() => _step(
    'native-hover-regions',
    () async {
      await _waitFor(
        () => _playbackAlpha('viewer-filmstrip-fade') == 0,
        reason: 'the playing video did not hide its strip',
      );
      final strip = _uxRectOf(
        _elementByKey(const ValueKey('viewer-filmstrip-hover'))!,
      )!;
      final stage = _uxRectOf(_elementByKey(const ValueKey('viewer-video'))!)!;
      await _input!.moveTo(strip.center, _devicePixelRatio);
      await _waitFor(
        () => _playbackAlpha('viewer-filmstrip-fade') == 1,
        reason: 'hovering the hidden strip did not reveal it',
      );
      if (_playbackAlpha('video-controls-fade') != 0) {
        throw JourneyFailure('the strip hover also revealed playback controls');
      }
      var decoded = 0;
      void visit(Element element) {
        if (element is RenderObjectElement &&
            element.renderObject is RenderImage) {
          final rect = _uxRectOf(element);
          if (rect != null && rect.overlaps(strip)) {
            if ((element.renderObject as RenderImage).image == null) {
              throw JourneyFailure(
                'the revealed strip contains an undecoded frame',
              );
            }
            decoded++;
          }
        }
        element.visitChildren(visit);
      }

      visit(_elementByKey(const ValueKey('viewer-filmstrip'))!);
      if (decoded < 2) {
        throw JourneyFailure(
          'the hover fixture needs multiple visible thumbnails',
        );
      }
      facts['hover_strip_decoded_frames'] = decoded;
      await _input!.moveTo(stage.center, _devicePixelRatio);
      await _waitFor(
        () => _playbackAlpha('viewer-filmstrip-fade') == 0,
        reason: 'the strip did not fade away after hover',
      );
      // Default seek-container centre: 104px inset + 56px buttons - 16px
      // translation + half of the 36px seek container.
      await _input!.moveTo(
        stage.bottomCenter - const Offset(0, 162),
        _devicePixelRatio,
      );
      await _waitFor(
        () => _playbackAlpha('video-controls-fade') == 1,
        reason: 'the seek bar hover did not reveal playback controls',
      );
      if (_playbackAlpha('viewer-filmstrip-fade') != 0) {
        throw JourneyFailure('seek hover also revealed the filmstrip');
      }
      await _input!.moveTo(
        stage.bottomCenter - const Offset(0, 4),
        _devicePixelRatio,
      );
      await _waitFor(
        () =>
            _playbackAlpha('video-controls-fade') == 0 &&
            _playbackAlpha('viewer-filmstrip-fade') == 0,
        reason: 'the photo footer activated one of the playback overlays',
      );
      facts['hover_regions_independent'] = true;
    },
  );
}
