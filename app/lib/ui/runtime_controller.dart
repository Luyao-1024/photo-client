import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/core_gateway.dart';

final coreGatewayProvider = Provider<CoreGateway>((ref) {
  throw StateError('PhotoClientApp must supply a CoreGateway.');
});

final runtimeProvider = NotifierProvider<RuntimeController, RuntimeViewState>(
  RuntimeController.new,
);

enum ConnectionPhase { connecting, ready, failed, stopped }

enum RuntimeProblem { initialization, eventStream, roundTrip, shutdown }

class RuntimeViewState {
  const RuntimeViewState({
    this.phase = ConnectionPhase.connecting,
    this.snapshot,
    this.sequence,
    this.runtimeStatus,
    this.problem,
    this.probing = false,
    this.reply,
  });

  final ConnectionPhase phase;
  final CoreSnapshot? snapshot;
  final int? sequence;
  final String? runtimeStatus;
  final RuntimeProblem? problem;
  final bool probing;
  final String? reply;

  RuntimeViewState copyWith({
    ConnectionPhase? phase,
    int? sequence,
    String? runtimeStatus,
    RuntimeProblem? problem,
    bool? probing,
    String? reply,
    bool clearProblem = false,
    bool clearReply = false,
  }) => RuntimeViewState(
    phase: phase ?? this.phase,
    snapshot: snapshot,
    sequence: sequence ?? this.sequence,
    runtimeStatus: runtimeStatus ?? this.runtimeStatus,
    problem: clearProblem ? null : problem ?? this.problem,
    probing: probing ?? this.probing,
    reply: clearReply ? null : reply ?? this.reply,
  );
}

class RuntimeController extends Notifier<RuntimeViewState> {
  late CoreGateway _gateway;
  StreamSubscription<CoreRuntimeEvent>? _subscription;
  Future<void>? _initializing;
  Future<void>? _closing;
  bool _disposed = false;
  bool _attempted = false;
  bool _stopping = false;
  int _generation = 0;

  @override
  RuntimeViewState build() {
    _gateway = ref.read(coreGatewayProvider);
    ref.onDispose(() {
      _disposed = true;
      unawaited(shutdown());
    });
    // Never mutate another provider or publish state during the build phase.
    scheduleMicrotask(initialize);
    return const RuntimeViewState();
  }

  Future<void> initialize() {
    if (_disposed || _stopping) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    state = const RuntimeViewState();
    try {
      await _subscription?.cancel();
      _subscription = null;
      if (_attempted) {
        await _gateway.shutdown();
        _attempted = false;
      }
      if (_disposed || _stopping) return;
      _attempted = true;
      final snapshot = await _gateway.initialize();
      if (_disposed || _stopping || generation != _generation) return;
      state = RuntimeViewState(
        phase: ConnectionPhase.ready,
        snapshot: snapshot,
        runtimeStatus: snapshot.status,
      );
      // Subscription follows initialize, matching the core snapshot barrier.
      // No fabricated event is emitted if the stream has not delivered one.
      _subscription = _gateway.watchRuntime().listen(
        (event) {
          if (_disposed || _stopping || generation != _generation) return;
          if (state.sequence != null && event.sequence <= state.sequence!) {
            return;
          }
          state = state.copyWith(
            sequence: event.sequence,
            runtimeStatus: event.status,
          );
        },
        onError: (Object error, StackTrace stack) {
          _streamFailed(generation);
        },
        onDone: () => _streamFailed(generation),
        cancelOnError: true,
      );
    } catch (_) {
      if (_disposed || _stopping || generation != _generation) return;
      state = const RuntimeViewState(
        phase: ConnectionPhase.failed,
        problem: RuntimeProblem.initialization,
      );
    }
  }

  void _streamFailed(int generation) {
    if (_disposed || _stopping || generation != _generation) return;
    state = state.copyWith(
      phase: ConnectionPhase.failed,
      problem: RuntimeProblem.eventStream,
      probing: false,
    );
  }

  Future<void> probe() async {
    if (_disposed ||
        _stopping ||
        state.phase != ConnectionPhase.ready ||
        state.probing) {
      return;
    }
    final generation = _generation;
    state = state.copyWith(probing: true, clearProblem: true, clearReply: true);
    try {
      final reply = await _gateway.roundTrip('photo-client:s01');
      if (!_disposed &&
          !_stopping &&
          generation == _generation &&
          state.phase == ConnectionPhase.ready) {
        state = state.copyWith(probing: false, reply: reply);
      }
    } catch (_) {
      if (!_disposed &&
          !_stopping &&
          generation == _generation &&
          state.phase == ConnectionPhase.ready) {
        state = state.copyWith(
          probing: false,
          problem: RuntimeProblem.roundTrip,
        );
      }
    }
  }

  /// Paused/inactive are deliberately excluded: mobile backgrounding is not exit.
  Future<void> shutdown() => _closing ??= _shutdown();

  Future<void> _shutdown() async {
    _stopping = true;
    ++_generation;
    if (!_disposed) {
      state = state.copyWith(phase: ConnectionPhase.stopped, probing: false);
    }
    // A late successful initialize must not create an orphaned native session.
    await _initializing;
    // The native session must go first: it publishes the terminal event that
    // lets the runtime stream task end. Cancelling the subscription first would
    // wait for a stream that only completes during that native shutdown.
    if (_attempted) {
      try {
        await _gateway.shutdown();
        _attempted = false;
      } catch (_) {
        if (!_disposed) {
          state = state.copyWith(problem: RuntimeProblem.shutdown);
        }
      }
    }
    try {
      await _subscription?.cancel();
      _subscription = null;
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(problem: RuntimeProblem.shutdown);
      }
    }
  }
}
