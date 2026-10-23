import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pulls the phone page content down with the finger.
///
/// With [onRefresh] set, releasing past the threshold refreshes. Without it,
/// the content still follows the drag and springs back, but nothing happens.
class MobilePullRefresh extends StatefulWidget {
  const MobilePullRefresh({
    super.key,
    this.onRefresh,
    this.onPullDown,
    this.onPullUp,
    required this.child,
  });

  /// Null keeps the pull-and-settle feel without refreshing.
  final Future<void> Function()? onRefresh;

  /// Fired once per gesture when the content has visibly moved down.
  final VoidCallback? onPullDown;

  /// Fired once per gesture when the finger drags up, so revealed chrome can
  /// retract even when the list itself has nothing left to scroll.
  final VoidCallback? onPullUp;
  final Widget child;

  @override
  State<MobilePullRefresh> createState() => _MobilePullRefreshState();
}

class _MobilePullRefreshState extends State<MobilePullRefresh> {
  static const _triggerPull = 60.0;
  static const _maxPull = 130.0;
  static const _resistance = 0.55;

  double _pull = 0;
  bool _dragging = false;
  bool _refreshing = false;
  bool _revealNotified = false;
  bool _hideNotified = false;

  void _setPull(double value) {
    final next = value.clamp(0.0, _maxPull);
    if (next == _pull) return;
    setState(() => _pull = next);
  }

  void _notifyPullUp() {
    if (_hideNotified) return;
    _hideNotified = true;
    widget.onPullUp?.call();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_refreshing ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _hideNotified = false;
        _dragging = notification.metrics.extentBefore <= 0.5;
      }
      return false;
    }
    if (notification is OverscrollNotification) {
      if (notification.dragDetails == null) return false;
      if (notification.overscroll > 0) {
        _notifyPullUp();
        return false;
      }
      if (notification.metrics.extentBefore > 0.5) return false;
      _dragging = true;
      // Rubber band: the further the page has already travelled, the less
      // each additional finger movement moves it.
      final remaining = 1 - _pull / _maxPull;
      final gain = _resistance * remaining.clamp(.06, 1.0);
      _setPull(_pull - notification.overscroll * gain);
      if (!_revealNotified && _pull >= 12) {
        _revealNotified = true;
        widget.onPullDown?.call();
      }
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta > 0 && notification.dragDetails != null) _notifyPullUp();
      // Scrolling the list back up should retract the revealed page first.
      if (_pull > 0 && delta > 0) {
        _setPull(math.max(0, _pull - delta));
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      _dragging = false;
      _revealNotified = false;
      if (_pull > 0) {
        if (widget.onRefresh != null && _pull >= _triggerPull) {
          _refresh();
        } else {
          _setPull(0);
        }
      }
      return false;
    }
    return false;
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefresh;
    if (_refreshing || refresh == null) return;
    setState(() {
      _refreshing = true;
      _dragging = false;
      _pull = 0;
    });
    try {
      await refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ClipRect(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _pull),
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, offset, child) =>
              Transform.translate(offset: Offset(0, offset), child: child),
          child: widget.child,
        ),
      ),
    );
  }
}
