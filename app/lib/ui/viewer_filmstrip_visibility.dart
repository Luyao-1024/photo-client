import 'dart:async';

import 'package:flutter/material.dart';

/// Keep the strip mounted while hidden so its decoded frames can be prepared
/// before one shared fade. A slow frame cannot keep navigation hidden forever.
/// Hovering its own bounds reveals it during desktop playback.
class ViewerFilmstripVisibility extends StatefulWidget {
  const ViewerFilmstripVisibility({
    super.key,
    required this.ready,
    required this.playbackActive,
    required this.child,
  });
  final Future<void> ready;
  final bool playbackActive;
  final Widget child;

  @override
  State<ViewerFilmstripVisibility> createState() =>
      _ViewerFilmstripVisibilityState();
}

class _ViewerFilmstripVisibilityState extends State<ViewerFilmstripVisibility> {
  bool _ready = false, _hovered = false;
  Timer? _deadline;

  @override
  void initState() {
    super.initState();
    _deadline = Timer(const Duration(milliseconds: 400), _reveal);
    _prepare();
  }

  @override
  void didUpdateWidget(ViewerFilmstripVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ready != widget.ready) {
      // Once visible, incoming thumbnail work must not hide the whole strip.
      _prepare();
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  void _reveal() {
    if (!mounted || _ready) return;
    _deadline?.cancel();
    setState(() => _ready = true);
  }

  void _prepare() {
    final future = widget.ready;
    void finish() {
      if (mounted && identical(future, widget.ready)) {
        _reveal();
      }
    }

    future.then((_) => finish(), onError: (Object _, StackTrace _) => finish());
  }

  @override
  Widget build(BuildContext context) {
    final show = _ready && (!widget.playbackActive || _hovered);
    return MouseRegion(
      key: const ValueKey('viewer-filmstrip-hover'),
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          key: const ValueKey('viewer-filmstrip-fade'),
          opacity: show ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          curve: Curves.easeInOut,
          child: widget.child,
        ),
      ),
    );
  }
}
