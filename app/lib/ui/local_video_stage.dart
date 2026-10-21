import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'strings.dart';
import '../services/window_controller.dart';

/// File-only playback. Each displayed item owns and disposes its player.
class LocalVideoStage extends StatefulWidget {
  const LocalVideoStage({super.key, required this.path, this.bottomInset = 0});
  final String path;
  final double bottomInset;
  @override
  State<LocalVideoStage> createState() => LocalVideoStageState();
}

class LocalVideoStageState extends State<LocalVideoStage> {
  final _view = GlobalKey<VideoState>();
  Future<void> enterFullscreen() =>
      _view.currentState?.enterFullscreen() ?? Future<void>.value();
  Player? _player;
  VideoController? _video;
  String? _error;
  StreamSubscription<String>? _errors;
  String? get error => _error;
  bool get playing => _player?.state.playing ?? false;
  Duration get position => _player?.state.position ?? Duration.zero;
  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    try {
      // The video texture plugin links this SONAME. Reuse that exact loaded
      // module: opening a second absolute copy gives mpv foreign handles.
      MediaKit.ensureInitialized(
        libmpv: Platform.isLinux ? 'libmpv.so.2' : null,
      );
      final player = Player(
        configuration: const PlayerConfiguration(title: 'PhotoViewer'),
      );
      _player = player;
      _video = VideoController(player);
      _errors = player.stream.error.listen((_) {
        if (mounted) setState(() => _error = 'playback');
      });
      unawaited(
        player.open(Media(Uri.file(widget.path).toString())).catchError((
          Object error,
        ) {
          if (mounted) setState(() => _error = 'playback');
        }),
      );
    } catch (_) {
      _error = 'unavailable';
    }
  }

  void togglePlayback() {
    unawaited(_player?.playOrPause() ?? Future<void>.value());
  }

  @override
  void dispose() {
    unawaited(_errors?.cancel() ?? Future<void>.value());
    unawaited(_player?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (_error != null || _video == null) {
      return Center(
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
              onPressed: () {
                unawaited(_errors?.cancel() ?? Future<void>.value());
                unawaited(_player?.dispose() ?? Future<void>.value());
                setState(() {
                  _error = null;
                  _open();
                });
              },
              child: Text(strings.retry),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomInset),
      child: Video(
        key: _view,
        controller: _video!,
        fit: BoxFit.contain,
        onEnterFullscreen: () => WindowController.instance.setFullscreen(true),
        onExitFullscreen: () => WindowController.instance.setFullscreen(false),
      ),
    );
  }
}
