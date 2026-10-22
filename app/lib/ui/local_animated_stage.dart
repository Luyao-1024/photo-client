import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

/// One decoded frame of an animated image, kept in the thumbnail cache.
class AnimatedFrame {
  const AnimatedFrame({required this.path, required this.delayMs});

  final String path;
  final int delayMs;

  factory AnimatedFrame.fromJson(Map<String, dynamic> data) => AnimatedFrame(
    path: data['path'] as String,
    delayMs: (data['delay_ms'] as num).toInt(),
  );
}

/// Plays the frames of an animated image.
///
/// The pre-refactor client decoded every frame of an animated image and
/// played them back in the viewer. The frames arrive as cached files, so they
/// are streamed one by one and the animation loops like the original.
class AnimatedImageStage extends StatefulWidget {
  const AnimatedImageStage({
    super.key,
    required this.frames,
    this.placeholder = const SizedBox.shrink(),
    this.frameProvider,
  });

  final List<AnimatedFrame> frames;
  final Widget placeholder;
  final ImageProvider Function(AnimatedFrame)? frameProvider;

  @override
  State<AnimatedImageStage> createState() => AnimatedImageStageState();
}

class AnimatedImageStageState extends State<AnimatedImageStage> {
  int _index = 0;
  bool _firstFrameReady = false;
  bool get firstFrameReady => _firstFrameReady;
  int get frameIndex => _index;
  Timer? _timer;
  bool _tickerEnabled = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.valuesOf(context);
    _tickerEnabled = mode.enabled || mode.forceFrames;
    if (!_tickerEnabled) {
      _timer?.cancel();
    } else if (_firstFrameReady && _timer?.isActive != true) {
      _schedule();
    }
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(AnimatedImageStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      _index = 0;
      _firstFrameReady = false;
      _timer?.cancel();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (widget.frames.isEmpty || !_tickerEnabled) return;
    final delay = widget.frames[_index].delayMs.clamp(16, 5000);
    _timer = Timer(Duration(milliseconds: delay), _advance);
  }

  void _advance() {
    if (!mounted || !_tickerEnabled || widget.frames.isEmpty) return;
    setState(() => _index = (_index + 1) % widget.frames.length);
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.frames.isEmpty) {
      return const SizedBox.shrink();
    }
    final frame = widget.frames[_index];
    return Image(
      image: widget.frameProvider?.call(frame) ?? FileImage(File(frame.path)),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, synchronous) {
        if (frame != null || synchronous) {
          _firstFrameReady = true;
          if (_tickerEnabled && _timer?.isActive != true) {
            final index = _index;
            final frames = widget.frames;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  identical(frames, widget.frames) &&
                  index == _index &&
                  _timer?.isActive != true) {
                _schedule();
              }
            });
          }
          return child;
        }
        return _index == 0 ? widget.placeholder : child;
      },
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const Icon(
        Icons.broken_image_outlined,
        size: 48,
        color: Colors.white70,
      ),
    );
  }
}
