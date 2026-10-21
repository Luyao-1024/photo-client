import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud_sync_gateway.dart';
import 'local_library_controller.dart';
import 'runtime_controller.dart';

final cloudSyncProvider = NotifierProvider<CloudSyncController, CloudSyncState>(
  CloudSyncController.new,
);

class CloudSyncState {
  const CloudSyncState({
    this.available = false,
    this.loading = true,
    this.busy = false,
    this.status = const CloudStatus(),
    this.boundIds = const <String>{},
    this.errorCode,
    this.report,
  });

  /// False when the active gateway does not implement cloud sync at all.
  final bool available;
  final bool loading, busy;
  final CloudStatus status;
  final Set<String> boundIds;
  final String? errorCode;
  final CloudSyncReport? report;

  bool get loggedIn => status.loggedIn;
  bool isBound(String mediaId) => boundIds.contains(mediaId);

  CloudSyncState copyWith({
    bool? available,
    bool? loading,
    bool? busy,
    CloudStatus? status,
    Set<String>? boundIds,
    String? errorCode,
    bool clearError = false,
    CloudSyncReport? report,
  }) => CloudSyncState(
    available: available ?? this.available,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    status: status ?? this.status,
    boundIds: boundIds ?? this.boundIds,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    report: report ?? this.report,
  );
}

/// Owns cloud login state and the bound-photo set. Syncs once after startup
/// and once after login; there is no background polling.
class CloudSyncController extends Notifier<CloudSyncState> {
  CloudSyncGateway? _gateway;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _loading;

  @override
  CloudSyncState build() {
    final gateway = ref.read(coreGatewayProvider);
    _gateway = gateway is CloudSyncGateway ? gateway as CloudSyncGateway : null;
    ref.onDispose(() => _disposed = true);
    ref.listen<ConnectionPhase>(runtimeProvider.select((view) => view.phase), (
      previous,
      next,
    ) {
      if (next == ConnectionPhase.ready) {
        _startIfReady();
      } else {
        _started = false;
      }
    }, fireImmediately: true);
    ref.listen<bool>(
      localLibraryProvider.select(
        (library) => library.info != null && !library.loading,
      ),
      (previous, next) {
        if (next) _startIfReady();
      },
      fireImmediately: true,
    );
    if (_gateway == null) {
      return const CloudSyncState(available: false, loading: false);
    }
    return const CloudSyncState(available: true);
  }

  /// Startup sync waits for the catalog, not just the runtime: cloud RPCs
  /// reach the same library actor and would otherwise see `LibraryNotOpen`.
  void _startIfReady() {
    if (_started || _gateway == null || _disposed) return;
    if (ref.read(runtimeProvider).phase != ConnectionPhase.ready) return;
    if (ref.read(localLibraryProvider).info == null) return;
    _started = true;
    scheduleMicrotask(() => unawaited(_startup()));
  }

  Future<void> _startup() async {
    await load();
    if (_disposed || !state.loggedIn) return;
    await syncNow();
  }

  Future<void> load() => _loading ??= _load().whenComplete(() {
    _loading = null;
  });

  Future<void> _load() async {
    final gateway = _gateway;
    if (gateway == null || _disposed) return;
    try {
      final status = await gateway.cloudStatus();
      final bound = await gateway.cloudBoundMediaIds();
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        clearError: true,
      );
    } catch (error) {
      if (_disposed) return;
      state = state.copyWith(loading: false, errorCode: cloudErrorCode(error));
    }
  }

  Future<String?> login({
    required String endpoint,
    required String username,
    required String password,
  }) async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy) return 'Internal';
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await gateway.cloudLogin(
        endpoint: endpoint,
        username: username,
        password: password,
      );
      final bound = await gateway.cloudBoundMediaIds();
      if (_disposed) return null;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        clearError: true,
      );
      // The native login already ran one downlink; refresh the grid so those
      // photos appear without waiting for another round trip.
      await _refreshLibrary();
      return null;
    } catch (error) {
      final code = cloudErrorCode(error);
      if (!_disposed) {
        state = state.copyWith(busy: false, errorCode: code);
      }
      return code;
    }
  }

  Future<String?> logout() async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy) return 'Internal';
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await gateway.cloudLogout();
      if (_disposed) return null;
      state = state.copyWith(busy: false, status: status, clearError: true);
      await _refreshLibrary();
      return null;
    } catch (error) {
      final code = cloudErrorCode(error);
      if (!_disposed) {
        state = state.copyWith(busy: false, errorCode: code);
      }
      return code;
    }
  }

  Future<CloudSyncReport?> syncNow() async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy || !state.loggedIn) {
      return null;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final report = await gateway.cloudSyncNow();
      final status = await gateway.cloudStatus();
      final bound = await gateway.cloudBoundMediaIds();
      if (_disposed) return report;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        report: report,
        clearError: report.errorCode == null,
        errorCode: report.errorCode,
      );
      await _refreshLibrary();
      return report;
    } catch (error) {
      final code = cloudErrorCode(error);
      if (!_disposed) {
        state = state.copyWith(busy: false, errorCode: code);
      }
      return null;
    }
  }

  Future<CloudQueueResult?> queueUpload(List<String> mediaIds) async {
    final gateway = _gateway;
    if (gateway == null ||
        _disposed ||
        state.busy ||
        !state.loggedIn ||
        mediaIds.isEmpty) {
      return null;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await gateway.cloudQueueUpload(mediaIds);
      final status = await gateway.cloudStatus();
      if (_disposed) return result;
      state = state.copyWith(busy: false, status: status, clearError: true);
      return result;
    } catch (error) {
      final code = cloudErrorCode(error);
      if (!_disposed) {
        state = state.copyWith(busy: false, errorCode: code);
      }
      return null;
    }
  }

  Future<void> _refreshLibrary() async {
    try {
      await ref.read(localLibraryProvider.notifier).refresh(force: true);
    } catch (_) {
      // The library may still be loading; the next event refresh reconciles it.
    }
  }
}
