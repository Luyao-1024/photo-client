import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud_sync_gateway.dart';
import '../services/local_library_tools.dart';
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
    this.syncRunning = false,
    this.autoSync = false,
    this.status = const CloudStatus(),
    this.boundIds = const <String>{},
    this.protectedIds = const <String>{},
    this.errorCode,
    this.report,
  });

  /// False when the active gateway does not implement cloud sync at all.
  final bool available;
  final bool loading, busy;

  /// A sweep is in flight before the first polled status reports it.
  final bool syncRunning;

  /// Whether the app syncs on its own at startup. Off by default: signing in
  /// establishes a session, it does not start a download.
  final bool autoSync;
  final CloudStatus status;

  /// Bound photos of the active account.
  final Set<String> boundIds;

  /// Bound photos of every saved account; they stay read-only.
  final Set<String> protectedIds;
  final String? errorCode;
  final CloudSyncReport? report;

  bool get loggedIn => status.loggedIn;
  bool isBound(String mediaId) => boundIds.contains(mediaId);
  bool isProtected(String mediaId) => protectedIds.contains(mediaId);

  CloudSyncState copyWith({
    bool? available,
    bool? loading,
    bool? busy,
    bool? syncRunning,
    bool? autoSync,
    CloudStatus? status,
    Set<String>? boundIds,
    Set<String>? protectedIds,
    String? errorCode,
    bool clearError = false,
    CloudSyncReport? report,
  }) => CloudSyncState(
    available: available ?? this.available,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    syncRunning: syncRunning ?? this.syncRunning,
    autoSync: autoSync ?? this.autoSync,
    status: status ?? this.status,
    boundIds: boundIds ?? this.boundIds,
    protectedIds: protectedIds ?? this.protectedIds,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    report: report ?? this.report,
  );
}

/// Owns cloud login state and the bound-photo set. Signing in only establishes
/// the session; every sweep is either user-initiated or allowed by the auto
/// sync switch. There is no background polling.
class CloudSyncController extends Notifier<CloudSyncState> {
  CloudSyncGateway? _gateway;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _loading;
  Timer? _statusTicker;

  @override
  CloudSyncState build() {
    final gateway = ref.read(coreGatewayProvider);
    _gateway = gateway is CloudSyncGateway ? gateway as CloudSyncGateway : null;
    ref.onDispose(() {
      _disposed = true;
      _statusTicker?.cancel();
      _statusTicker = null;
    });
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
    // A signed-in account does not download by itself: the startup sweep only
    // runs when the user turned auto sync on.
    if (!state.autoSync) return;
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
      final protected = await gateway.cloudProtectedMediaIds();
      final autoSync = await _readAutoSync();
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        protectedIds: protected.toSet(),
        autoSync: autoSync,
        clearError: true,
      );
    } catch (error) {
      if (_disposed) return;
      state = state.copyWith(loading: false, errorCode: cloudErrorCode(error));
    }
  }

  /// Read the stored auto sync switch. A gateway without the local tools
  /// channel keeps the default: no automatic sweep.
  Future<bool> _readAutoSync() async {
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is! LocalLibraryTools) return false;
    try {
      final data = await (gateway as LocalLibraryTools).localCommand({
        'op': 'preferences',
      });
      if (data is Map && data['cloudAutoSync'] == true) return true;
    } catch (_) {
      // A missing or unreadable preference means the default, not a failure.
    }
    return false;
  }

  /// Turn automatic syncing on or off. Enabling it sweeps right away and at
  /// each app start; disabling it leaves only explicit syncs.
  Future<void> setAutoSync(bool value) async {
    if (_disposed) return;
    state = state.copyWith(autoSync: value);
    if (value && state.loggedIn && !state.busy) {
      unawaited(syncNow());
    }
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is! LocalLibraryTools) return;
    try {
      await (gateway as LocalLibraryTools).localCommand({
        'op': 'setPreference',
        'key': 'cloudAutoSync',
        'value': value,
      });
    } catch (_) {
      // The switch still applies to this session when it cannot be stored.
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
      final protected = await gateway.cloudProtectedMediaIds();
      if (_disposed) return null;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        protectedIds: protected.toSet(),
        clearError: true,
      );
      // Signing in answers with the session, not with a download. The grid is
      // refreshed so anything already on disk is shown under this account.
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

  /// Only one account synchronizes at a time. Switching keeps every account's
  /// saved credentials, scope and progress.
  Future<String?> switchAccount(String accountId) async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy) return 'Internal';
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await gateway.cloudSwitchAccount(accountId);
      final bound = await gateway.cloudBoundMediaIds();
      final protected = await gateway.cloudProtectedMediaIds();
      if (_disposed) return null;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        protectedIds: protected.toSet(),
        clearError: true,
      );
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

  Future<String?> removeAccount(String accountId) async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy) return 'Internal';
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await gateway.cloudRemoveAccount(accountId);
      final bound = await gateway.cloudBoundMediaIds();
      final protected = await gateway.cloudProtectedMediaIds();
      if (_disposed) return null;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        protectedIds: protected.toSet(),
        clearError: true,
      );
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

  /// Persist which local albums the active account uploads automatically.
  /// An empty selection means receive-only, matching the pre-refactor client.
  Future<String?> setUploadScope(String mode, List<String> albums) async {
    final gateway = _gateway;
    if (gateway == null || _disposed || state.busy) return 'Internal';
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await gateway.cloudSetUploadScope(mode, albums);
      if (_disposed) return null;
      state = state.copyWith(busy: false, status: status, clearError: true);
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
    state = state.copyWith(busy: true, syncRunning: true, clearError: true);
    // A sweep can run for a long time. The status is refreshed while it runs
    // so the interface shows that syncing is under way and how far it got
    // instead of a button that only spins.
    _startStatusTicker();
    try {
      final report = await gateway.cloudSyncNow();
      final status = await gateway.cloudStatus();
      final bound = await gateway.cloudBoundMediaIds();
      final protected = await gateway.cloudProtectedMediaIds();
      if (_disposed) return report;
      state = state.copyWith(
        busy: false,
        loading: false,
        status: status,
        boundIds: bound.toSet(),
        protectedIds: protected.toSet(),
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
    } finally {
      _stopStatusTicker();
      if (!_disposed) state = state.copyWith(syncRunning: false);
    }
  }

  void _startStatusTicker() {
    _statusTicker?.cancel();
    _statusTicker = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refreshStatus());
    });
  }

  void _stopStatusTicker() {
    _statusTicker?.cancel();
    _statusTicker = null;
  }

  /// Read the live status without touching the busy state: the native side
  /// answers this while a sweep is running, which is what makes the syncing
  /// label and the counters live.
  Future<void> _refreshStatus() async {
    final gateway = _gateway;
    if (gateway == null || _disposed) return;
    try {
      final status = await gateway.cloudStatus();
      if (_disposed) return;
      state = state.copyWith(status: status);
    } catch (_) {
      // A failed status read never disturbs the sweep it observes.
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
