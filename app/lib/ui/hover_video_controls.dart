import 'package:flutter/material.dart';

/// Reveal playback chrome only when the pointer approaches its bottom bar.
/// The video itself stays mounted and fully visible while chrome fades.
class HoverVideoControls extends StatefulWidget {
  const HoverVideoControls({
    super.key,
    required this.bottomInset,
    required this.child,
    this.buttonBarHeight = 56,
    this.seekBarHeight = 36,
    this.seekBarOffset = 16,
    this.horizontalMargin = const EdgeInsets.symmetric(horizontal: 16),
  });
  final double bottomInset;
  final Widget child;
  final double buttonBarHeight, seekBarHeight, seekBarOffset;
  final EdgeInsets horizontalMargin;

  @override
  State<HoverVideoControls> createState() => _HoverVideoControlsState();
}

class _HoverVideoControlsState extends State<HoverVideoControls> {
  bool _visible = false, _dragging = false;

  void _show(bool value) {
    if (_visible != value) setState(() => _visible = value);
  }

  void _hover(Offset position, Size size) {
    final bottom = size.height - widget.bottomInset;
    final seekBottom = bottom - widget.buttonBarHeight + widget.seekBarOffset;
    final seek = Rect.fromLTRB(
      widget.horizontalMargin.left,
      seekBottom - widget.seekBarHeight,
      size.width - widget.horizontalMargin.right,
      seekBottom,
    );
    // Hidden chrome can only be activated over the seek bar. Once revealed,
    // keep its playback/volume buttons usable until the pointer leaves them.
    final hit = _visible
        ? Rect.fromLTRB(seek.left, seek.top, seek.right, bottom)
        : seek;
    _show(hit.contains(position));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MouseRegion(
      // A newly mounted video must not reveal controls under a stationary
      // pointer left over from clicking Play. Wait for an actual hover move.
      onHover: (event) => _hover(event.localPosition, constraints.biggest),
      onExit: (_) {
        if (!_dragging) _show(false);
      },
      child: Listener(
        onPointerDown: (_) => _dragging = _visible,
        onPointerUp: (event) {
          _dragging = false;
          _hover(event.localPosition, constraints.biggest);
        },
        onPointerCancel: (_) {
          _dragging = false;
          _show(false);
        },
        child: IgnorePointer(
          ignoring: !_visible,
          child: ExcludeFocus(
            excluding: !_visible,
            child: AnimatedOpacity(
              key: const ValueKey('video-controls-fade'),
              opacity: _visible ? 1 : 0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}
