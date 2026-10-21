import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef BackdropViewport = ({int queryEpoch, int? rank});

final backdropViewportProvider =
    NotifierProvider<BackdropViewportController, BackdropViewport?>(
      BackdropViewportController.new,
    );

/// Publish a recent viewport during long scrolls and the final one after rest.
/// Tracking never updates the library DTO or triggers thumbnail work per frame.
class BackdropViewportController extends Notifier<BackdropViewport?> {
  static const sampleInterval = Duration(milliseconds: 1200);
  static const settleDelay = Duration(milliseconds: 300);
  Timer? _sample, _settle;
  BackdropViewport? _pending;

  @override
  BackdropViewport? build() {
    ref.onDispose(_cancel);
    return null;
  }

  void track({required int queryEpoch, int? rank}) {
    if (_pending != null && _pending!.queryEpoch != queryEpoch) _cancel();
    _pending = (queryEpoch: queryEpoch, rank: rank);
    _settle?.cancel();
    _settle = Timer(settleDelay, () {
      _sample?.cancel();
      _sample = _settle = null;
      _publish();
    });
    _sample ??= Timer(sampleInterval, () {
      _sample = null;
      _publish();
    });
  }

  void _publish() {
    if (_pending != null && _pending != state) state = _pending;
  }

  void _cancel() {
    _sample?.cancel();
    _settle?.cancel();
    _sample = _settle = null;
    _pending = null;
  }

  void reset() {
    _cancel();
    state = null;
  }
}
