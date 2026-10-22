import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'strings.dart';
import '../services/window_controller.dart';

/// Playback readiness is explicit so the viewer never substitutes an unpaintable
/// video texture for its static image. The factory also permits codec-free tests.
abstract interface class VideoPlaybackSession {
  Future<void> open(String path);
  Future<void> get firstFrame;
  Future<void> play();
  Future<void> toggle();
  Future<void> dispose();
  Stream<String> get errors;
  bool get playing;
  Duration get position;
  Widget buildVideo(GlobalKey<VideoState> key);
}

typedef VideoSessionFactory = VideoPlaybackSession Function();

class _NativeVideoSession implements VideoPlaybackSession {
  _NativeVideoSession() {
    MediaKit.ensureInitialized(libmpv: Platform.isLinux ? 'libmpv.so.2' : null);
    player = Player(
      configuration: const PlayerConfiguration(title: 'PhotoViewer'),
    );
    controller = VideoController(player);
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
  bool get playing => player.state.playing;
  @override
  Duration get position => player.state.position;
  @override
  Widget buildVideo(GlobalKey<VideoState> key) => Video(
    key: key,
    controller: controller,
    fit: BoxFit.contain,
    onEnterFullscreen: () => WindowController.instance.setFullscreen(true),
    onExitFullscreen: () => WindowController.instance.setFullscreen(false),
  );
}

class LocalVideoStage extends StatefulWidget {
  const LocalVideoStage({
    super.key,
    required this.path,
    this.bottomInset = 0,
    this.placeholder = const SizedBox.shrink(),
    this.sessionFactory,
  });
  final String path;
  final double bottomInset;
  final Widget placeholder;
  final VideoSessionFactory? sessionFactory;
  @override
  State<LocalVideoStage> createState() => LocalVideoStageState();
}

class LocalVideoStageState extends State<LocalVideoStage> {
  final _view = GlobalKey<VideoState>();
  VideoPlaybackSession? _session;
  StreamSubscription<String>? _errors;
  String? _error;
  bool _ready = false;
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
    _error = null;
    try {
      final session = (widget.sessionFactory ?? _NativeVideoSession.new)();
      _session = session;
      _errors = session.errors.listen((_) {
        if (_current(generation, session)) setState(() => _error = 'playback');
      });
      unawaited(_prepare(session, generation, widget.path));
    } catch (_) {
      _error = 'unavailable';
    }
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
    final old = _session;
    _session = null;
    unawaited(old?.dispose() ?? Future.value());
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_session != null)
          Padding(
            padding: EdgeInsets.only(bottom: widget.bottomInset),
            child: _session!.buildVideo(_view),
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
