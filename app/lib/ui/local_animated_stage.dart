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
  const AnimatedImageStage({super.key, required this.frames});

  final List<AnimatedFrame> frames;

  @override
  State<AnimatedImageStage> createState() => _AnimatedImageStageState();
}

class _AnimatedImageStageState extends State<AnimatedImageStage> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(AnimatedImageStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      _index = 0;
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (widget.frames.isEmpty) return;
    final delay = widget.frames[_index].delayMs.clamp(16, 5000);
    _timer = Timer(Duration(milliseconds: delay), _advance);
  }

  void _advance() {
    if (!mounted || widget.frames.isEmpty) return;
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
    return Image.file(
      File(frame.path),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const Icon(
        Icons.broken_image_outlined,
        size: 48,
        color: Colors.white70,
      ),
    );
  }
}
