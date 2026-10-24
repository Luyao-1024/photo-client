import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'strings.dart';
import 'hover_video_controls.dart';
import '../services/window_controller.dart';
import '../services/video_playback_lifecycle.dart';

/// Playback readiness is explicit so the viewer never substitutes an unpaintable
/// video texture for its static image. The factory also permits codec-free tests.
abstract interface class VideoPlaybackSession {
  Future<void> open(String path);
  Future<void> get firstFrame;
  Future<void> play();
  Future<void> toggle();
  Future<void> dispose();
  Stream<String> get errors;
  Stream<bool> get completed;
  Stream<bool> get playback;
  bool get playing;
  Duration get position;
  Widget buildVideo(
    GlobalKey<VideoState> key, {
    ValueChanged<bool>? onControlsVisibilityChanged,
  });
}

typedef VideoSessionFactory = VideoPlaybackSession Function();

final videoSessionFactoryProvider = Provider<VideoSessionFactory>(
  (ref) => _NativeVideoSession.new,
);

class _NativeVideoSession implements VideoPlaybackSession {
  _NativeVideoSession() {
    MediaKit.ensureInitialized(
      libmpv: Platform.isLinux ? linuxMpvLibraryPath() : null,
    );
    player = Player(
      configuration: const PlayerConfiguration(title: 'PhotoViewer'),
    );
    controller = VideoController(
      player,
      configuration: Platform.isAndroid
          // mediacodec_embed bypasses mpv's renderer, so it ignores the
          // container rotation while the surface is already sized for the
          // rotated frame: portrait clips arrive stretched sideways. The gpu
          // VO applies the display matrix before the frame reaches the surface.
          ? const VideoControllerConfiguration(vo: 'gpu', hwdec: 'mediacodec')
          : const VideoControllerConfiguration(hwdec: 'auto'),
    );
  }
  late final Player player;
  late final VideoController controller;
  final _closed = Completer<void>();
  @override
  Future<void> open(String path) =>
      player.open(Media(Uri.file(path).toString()), play: false);
  @override
  Future<void> get firstFrame async {
    await Future.any([controller.waitUntilFirstFrameRendered, _closed.future]);
    if (_closed.isCompleted || !Platform.isLinux) return;
    // Linux registers an initial 1x1 texture before any video pixels exist.
    // media_kit counts that resize as a first frame; keep the still until the
    // output has real dimensions as well.
    final sized = Completer<void>();
    void check() {
      final rect = controller.rect.value;
      if (rect != null &&
          rect.width > 0 &&
          rect.height > 0 &&
          (rect.width > 1 ||
              rect.height > 1 ||
              (player.state.width == 1 && player.state.height == 1)) &&
          !sized.isCompleted) {
        sized.complete();
      }
    }

    controller.rect.addListener(check);
    check();
    try {
      await Future.any([sized.future, _closed.future]);
    } finally {
      controller.rect.removeListener(check);
    }
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> toggle() => player.playOrPause();
  @override
  Future<void> dispose() {
    if (!_closed.isCompleted) _closed.complete();
    return player.dispose();
  }

  @override
  Stream<String> get errors => player.stream.error;
  @override
  Stream<bool> get completed => player.stream.completed;
  @override
  Stream<bool> get playback => player.stream.playing;
  @override
  bool get playing => player.state.playing;
  @override
  Duration get position => player.state.position;
  @override
  Widget buildVideo(
    GlobalKey<VideoState> key, {
    ValueChanged<bool>? onControlsVisibilityChanged,
  }) => Video(
    key: key,
    controller: controller,
    fit: BoxFit.contain,
    // media_kit caches its controls subtree. Update only that subtree when
    // immersive mode changes the inset, keeping the video texture mounted.
    controls: (state) => Builder(
      builder: (context) {
        final theme = MaterialDesktopVideoControlsTheme.of(context);
        final style = isFullscreen(context) ? theme.fullscreen : theme.normal;
        final bottomInset = style.padding?.bottom ?? 0.0;
        return KeyedSubtree(
          key: ValueKey((bottomInset, theme.normal.seekBarPositionColor)),
          child: HoverVideoControls(
            bottomInset: bottomInset,
            touchAutoHide: Platform.isAndroid
                ? const Duration(seconds: 3)
                : null,
            onVisibilityChanged: onControlsVisibilityChanged,
            buttonBarHeight: style.bottomButtonBar.isEmpty
                ? 0
                : style.buttonBarHeight,
            seekBarHeight: style.seekBarContainerHeight,
            seekBarOffset: style.bottomButtonBar.isEmpty ? 0 : 16,
            horizontalMargin: style.seekBarMargin,
            child: MaterialDesktopVideoControls(state),
          ),
        );
      },
    ),
    onEnterFullscreen: () => WindowController.instance.setFullscreen(true),
    onExitFullscreen: () => WindowController.instance.setFullscreen(false),
  );
}

class LocalVideoStage extends ConsumerStatefulWidget {
  const LocalVideoStage({
    super.key,
    required this.path,
    this.bottomInset = 0,
    this.placeholder = const SizedBox.shrink(),
    this.sessionFactory,
    this.onCompleted,
    this.onPlaybackActiveChanged,
    this.onControlsVisibilityChanged,
  });
  final String path;

  /// Keep playback controls above the viewer filmstrip without shrinking the
  /// video surface or changing its fit relative to the still placeholder.
  final double bottomInset;
  final Widget placeholder;
  final VideoSessionFactory? sessionFactory;
  final VoidCallback? onCompleted;
  final ValueChanged<bool>? onPlaybackActiveChanged;

  /// Lets the viewer yield horizontal drags to visible seek/volume controls.
  final ValueChanged<bool>? onControlsVisibilityChanged;
  @override
  ConsumerState<LocalVideoStage> createState() => LocalVideoStageState();
}

class LocalVideoStageState extends ConsumerState<LocalVideoStage> {
  late final VideoPlaybackLifecycle _lifecycle;
  final _view = GlobalKey<VideoState>();
  VideoPlaybackSession? _session;
  StreamSubscription<String>? _errors;
  StreamSubscription<bool>? _completion;
  StreamSubscription<bool>? _playback;
  String? _error;
  bool _ready = false;
  bool _completionHandled = false;
  int _generation = 0;
  String? get error => _error;
  bool get firstFrameReady => _ready;
  bool get playing => _session?.playing ?? false;
  Duration get position => _session?.position ?? Duration.zero;
  Future<void> enterFullscreen() =>
      _view.currentState?.enterFullscreen() ?? Future.value();
  @override
  void initState() {
    super.initState();
    _lifecycle = ref.read(videoPlaybackLifecycleProvider);
    _open();
  }

  @override
  void didUpdateWidget(LocalVideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.sessionFactory != widget.sessionFactory) {
      _release();
      _open();
    }
  }

  bool _current(int generation, VideoPlaybackSession session) =>
      mounted && generation == _generation && identical(session, _session);
  void _open() {
    final generation = ++_generation;
    _ready = false;
    _completionHandled = false;
    _error = null;
    try {
      if (!_lifecycle.acceptingSessions) return;
      final factory =
          widget.sessionFactory ??
          ref.read<VideoSessionFactory>(videoSessionFactoryProvider);
      final session = factory();
      _session = session;
      _lifecycle.register(session, () async {
        if (identical(session, _session)) {
          _generation++;
          _session = null;
          await _errors?.cancel();
          await _completion?.cancel();
          await _playback?.cancel();
          _errors = null;
          _completion = null;
          _playback = null;
        }
        await session.dispose();
      });
      _errors = session.errors.listen((_) {
        if (_current(generation, session)) {
          setState(() => _error = 'playback');
          widget.onPlaybackActiveChanged?.call(false);
        }
      });
      _playback = session.playback.listen((playing) {
        if (playing && _current(generation, session)) {
          widget.onPlaybackActiveChanged?.call(true);
        }
      });
      _completion = session.completed.listen((completed) {
        if (!completed) _completionHandled = false;
        if (completed &&
            _current(generation, session) &&
            _ready &&
            _error == null &&
            !_completionHandled) {
          _completionHandled = true;
          unawaited(_finish(session, generation));
        }
      });
      unawaited(_prepare(session, generation, widget.path));
    } catch (_) {
      _error = 'unavailable';
    }
  }

  Future<void> _finish(VideoPlaybackSession session, int generation) async {
    widget.onPlaybackActiveChanged?.call(false);
    final view = _view.currentState;
    if (widget.onCompleted != null && view != null && view.isFullscreen()) {
      await view.exitFullscreen();
    }
    if (_current(generation, session)) widget.onCompleted?.call();
  }

  Future<void> _prepare(
    VideoPlaybackSession session,
    int generation,
    String path,
  ) async {
    try {
      await session.open(path);
      if (!_current(generation, session)) return;
      await session.firstFrame;
      if (!_current(generation, session) || _error != null) return;
      setState(() => _ready = true);
      // Reveal the first video frame before playback/audio starts.
      await WidgetsBinding.instance.endOfFrame;
      if (_current(generation, session) && _error == null) await session.play();
    } catch (_) {
      if (_current(generation, session)) setState(() => _error = 'playback');
    }
  }

  void togglePlayback() {
    if (_ready) unawaited(_session?.toggle() ?? Future.value());
  }

  void _release() {
    _generation++;
    unawaited(_errors?.cancel() ?? Future.value());
    _errors = null;
    unawaited(_completion?.cancel() ?? Future.value());
    _completion = null;
    unawaited(_playback?.cancel() ?? Future.value());
    _playback = null;
    final old = _session;
    _session = null;
    if (old != null) unawaited(_lifecycle.release(old));
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final touch = Platform.isAndroid;
    MaterialDesktopVideoControlsThemeData controls({double? bottomInset}) =>
        MaterialDesktopVideoControlsThemeData(
          padding: bottomInset == null
              ? null
              : EdgeInsets.only(bottom: bottomInset),
          // Touch screens emit no hover, so media_kit's desktop chrome would
          // never reveal itself. Keep it mounted and let HoverVideoControls
          // fade it in and run the idle timer.
          visibleOnMount: touch,
          controlsHoverDuration: touch
              ? const Duration(days: 365)
              : const Duration(seconds: 3),
          // A single library video has no playlist, and touch devices already
          // own volume; keep only transport and position on phones.
          bottomButtonBar: touch
              ? const [
                  MaterialDesktopPlayOrPauseButton(),
                  MaterialDesktopPositionIndicator(),
                  Spacer(),
                ]
              : const [
                  MaterialDesktopSkipPreviousButton(),
                  MaterialDesktopPlayOrPauseButton(),
                  MaterialDesktopSkipNextButton(),
                  MaterialDesktopVolumeButton(),
                  MaterialDesktopPositionIndicator(),
                  Spacer(),
                ],
          seekBarPositionColor: scheme.primary,
          seekBarThumbColor: scheme.primary,
          seekBarColor: scheme.onSurface.withValues(alpha: .20),
          seekBarHoverColor: scheme.onSurface.withValues(alpha: .28),
          seekBarBufferColor: scheme.onSurface.withValues(alpha: .38),
          volumeBarActiveColor: scheme.primary,
          volumeBarThumbColor: scheme.primary,
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_session != null)
          LayoutBuilder(
            builder: (context, constraints) {
              // The desktop chrome always lays out two button bars around the
              // seek bar. A short 16:9 stage (portrait phones) cannot also
              // clear a filmstrip-sized inset, so shrink the gap instead of
              // overflowing.
              final chrome = controls();
              final extent =
                  chrome.buttonBarHeight * 2 + chrome.seekBarContainerHeight;
              final available = math.max(0.0, constraints.maxHeight - extent);
              final inset = math.min(widget.bottomInset, available);
              return MaterialDesktopVideoControlsTheme(
                normal: controls(bottomInset: inset),
                fullscreen: controls(),
                child: _session!.buildVideo(
                  _view,
                  onControlsVisibilityChanged:
                      widget.onControlsVisibilityChanged,
                ),
              );
            },
          ),
        if (!_ready || _error != null) widget.placeholder,
        if (_error != null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(
                  strings.pick(
                    '无法播放此视频，请检查文件和解码器。',
                    'This video could not play. Check the file and codecs.',
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _release();
                    _open();
                  }),
                  child: Text(strings.retry),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
