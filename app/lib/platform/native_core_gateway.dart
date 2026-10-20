import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../services/core_gateway.dart';
import '../services/local_library_gateway.dart';
import '../src/rust/api/bootstrap.dart' as native;
import '../src/rust/api/local_library.dart' as native_library;
import '../src/rust/frb_generated.dart';

/// The only presentation adapter that knows the generated FFI API or native path.
final class NativeCoreGateway implements CoreGateway, LocalLibraryGateway {
  NativeCoreGateway({
    this.expectedDigestOverride,
    this.protocolOverride,
    this.dataRoot,
  });

  /// Used only by the real-window rejection checks, never by product settings.
  final String? expectedDigestOverride;
  final int? protocolOverride;

  /// Isolated library root for acceptance runs; `null` keeps the platform default.
  final String? dataRoot;
  static Future<void>? _bindingInitialization;
  CoreSnapshot? _snapshot;

  static Future<void> _initializeBinding() async {
    if (!Platform.isLinux) {
      throw UnsupportedError('PlatformPlanned');
    }
    final directory = File(Platform.resolvedExecutable).parent.path;
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        '$directory/lib/libphoto_bridge.so',
      ),
    );
  }

  @override
  Future<CoreSnapshot> initialize() async {
    final existing = _snapshot;
    if (existing != null) return existing;
    final binding = _bindingInitialization ??= _initializeBinding();
    try {
      await binding;
    } catch (_) {
      if (identical(_bindingInitialization, binding)) {
        _bindingInitialization = null;
      }
      rethrow;
    }
    const profile = String.fromEnvironment('PHOTO_PROFILE_JSON');
    const digest = String.fromEnvironment('PHOTO_PROFILE_DIGEST');
    const protocolText = String.fromEnvironment(
      'PHOTO_BRIDGE_PROTOCOL_VERSION',
      defaultValue: '1',
    );
    if (profile.isEmpty || digest.isEmpty) {
      throw StateError('BuildProfileMissing');
    }
    final result = await native.initialize(
      profileJson: profile,
      expectedDigest: expectedDigestOverride ?? digest,
      bridgeProtocolVersion: protocolOverride ?? int.parse(protocolText),
    );
    return _snapshot = CoreSnapshot(
      profileId: result.profileId,
      profileDigest: result.profileDigest,
      bridgeProtocolVersion: result.bridgeProtocolVersion,
      sessionId: result.sessionId,
      status: result.status,
    );
  }

  @override
  Stream<CoreRuntimeEvent> watchRuntime() {
    if (_snapshot == null) throw StateError('NotInitialized');
    return native.watchRuntime().map(
      (event) => CoreRuntimeEvent(
        sequence: event.sequence.toInt(),
        status: event.status,
      ),
    );
  }

  @override
  Future<String> roundTrip(String message) =>
      native.roundTrip(message: message);

  @override
  Future<void> shutdown() async {
    if (_snapshot == null) return;
    // Native shutdown also closes the open local library and its workers.
    await native.shutdown();
    _snapshot = null;
  }

  @override
  Future<LocalLibraryInfo> openLibrary() async {
    final info = await native_library.openLibrary(dataRoot: dataRoot);
    return LocalLibraryInfo(
      libraryId: info.libraryId,
      count: info.count.toInt(),
      revision: info.revision.toInt(),
    );
  }

  @override
  Future<LocalPhotoPage> listPhotos({
    String? cursor,
    int limit = 100,
    bool favoritesOnly = false,
    String search = '',
    String? folder,
  }) async {
    final page = await native_library.listPhotos(
      cursor: cursor,
      limit: limit,
      favoritesOnly: favoritesOnly,
      search: search,
      folder: folder,
    );
    return LocalPhotoPage(
      items: [
        for (final photo in page.items)
          LocalPhoto(
            id: photo.id,
            path: photo.path,
            name: photo.name,
            parent: photo.parent,
            sizeBytes: photo.sizeBytes.toInt(),
            modifiedMs: photo.modifiedMs.toInt(),
            contentVersion: photo.contentVersion.toInt(),
            width: photo.width,
            height: photo.height,
            favorite: photo.favorite,
          ),
      ],
      nextCursor: page.nextCursor,
      total: page.total.toInt(),
      revision: page.revision.toInt(),
    );
  }

  @override
  Future<LocalScanResult> addPaths(List<String> paths) async {
    final result = await native_library.addPaths(paths: paths);
    return LocalScanResult(
      discovered: result.discovered.toInt(),
      skipped: result.skipped.toInt(),
      failed: result.failed.toInt(),
      cancelled: result.cancelled,
    );
  }

  @override
  Future<void> cancelScan() => native_library.cancelScan();

  @override
  Future<String> thumbnail(String mediaId, {int sizeClass = 512}) =>
      native_library.thumbnail(mediaId: mediaId, sizeClass: sizeClass);

  @override
  Future<void> setFavorite(String mediaId, bool favorite) =>
      native_library.setFavorite(mediaId: mediaId, favorite: favorite);

  @override
  Stream<void> watchLibrary() {
    if (_snapshot == null) throw StateError('NotInitialized');
    // The native runtime stream carries library_changed among lifecycle events.
    return native
        .watchRuntime()
        .where((event) => event.status == 'library_changed')
        .map((_) {});
  }
}
