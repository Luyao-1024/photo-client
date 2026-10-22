import 'dart:async';

import 'package:flutter/gestures.dart';
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
    this.touchAutoHide,
  });
  final double bottomInset;
  final Widget child;
  final double buttonBarHeight, seekBarHeight, seekBarOffset;
  final EdgeInsets horizontalMargin;

  /// Idle timeout after a touch reveals the chrome. Touch screens have no
  /// hover-driven timer, so the host supplies the same duration the desktop
  /// controls use. Null keeps the desktop behavior.
  final Duration? touchAutoHide;

  @override
  State<HoverVideoControls> createState() => _HoverVideoControlsState();
}

class _HoverVideoControlsState extends State<HoverVideoControls> {
  bool _visible = false, _dragging = false;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show(bool value) {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (value) _restartTouchTimer();
    if (_visible != value) setState(() => _visible = value);
  }

  void _restartTouchTimer() {
    final duration = widget.touchAutoHide;
    _hideTimer?.cancel();
    _hideTimer = duration == null
        ? null
        : Timer(duration, () {
            _hideTimer = null;
            _show(false);
          });
  }

  Rect _seekBar(Size size) {
    final bottom = size.height - widget.bottomInset;
    final seekBottom = bottom - widget.buttonBarHeight + widget.seekBarOffset;
    return Rect.fromLTRB(
      widget.horizontalMargin.left,
      seekBottom - widget.seekBarHeight,
      size.width - widget.horizontalMargin.right,
      seekBottom,
    );
  }

  void _hover(Offset position, Size size) {
    final bottom = size.height - widget.bottomInset;
    final seek = _seekBar(size);
    // Hidden chrome can only be activated over the seek bar. Once revealed,
    // keep its playback/volume buttons usable until the pointer leaves them.
    final hit = _visible
        ? Rect.fromLTRB(seek.left, seek.top, seek.right, bottom)
        : seek;
    _show(hit.contains(position));
  }

  Rect _controls(Size size) {
    final bottom = size.height - widget.bottomInset;
    final seek = _seekBar(size);
    return Rect.fromLTRB(seek.left, seek.top, seek.right, bottom);
  }

  /// Touch screens have no hover, so a tap anywhere on the video reveals the
  /// chrome. Once visible, taps on the controls keep it around while taps on
  /// the picture dismiss it.
  void _touch(Offset position, Size size) {
    if (!_visible) {
      _show(true);
    } else if (_controls(size).contains(position)) {
      _restartTouchTimer();
    } else {
      _show(false);
    }
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
        // The hidden child is wrapped in IgnorePointer, so the listener must
        // remain hit-testable on its own to receive the first touch.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _dragging = _visible;
          if (event.kind == PointerDeviceKind.touch &&
              _controls(constraints.biggest).contains(event.localPosition)) {
            // Do not time out mid-drag on a seek or volume control.
            _hideTimer?.cancel();
            _hideTimer = null;
          }
        },
        onPointerUp: (event) {
          _dragging = false;
          if (event.kind == PointerDeviceKind.touch) {
            _touch(event.localPosition, constraints.biggest);
          } else {
            _hover(event.localPosition, constraints.biggest);
          }
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
