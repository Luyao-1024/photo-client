import '../services/media_metadata_cache.dart';
import '../services/thumbnail_pipeline.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import '../services/local_library_tools.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../services/cloud_sync_gateway.dart';
import '../services/core_gateway.dart';
import '../services/local_library_gateway.dart';
import '../src/rust/api/bootstrap.dart' as native;
import '../src/rust/api/cloud_sync.dart' as native_cloud;
import '../src/rust/api/local_library.dart' as native_library;
import '../src/rust/frb_generated.dart';

/// The only presentation adapter that knows the generated FFI API or native path.
final class NativeCoreGateway
    implements
        CoreGateway,
        LocalLibraryGateway,
        LocalLibraryTools,
        ThumbnailPipelineGateway,
        CloudSyncGateway {
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
  int? _thumbnailCacheEpoch;

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
    ThumbnailPool.forGateway(this).clear();
    MediaMetadataCache.clear(this);
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
    SearchScope searchScope = SearchScope.all,
    String? folder,
    String? mediaKind,
    bool trashed = false,
  }) async {
    final page = await native_library.listPhotos(
      cursor: cursor,
      limit: limit,
      favoritesOnly: favoritesOnly,
      search: search,
      searchScope: searchScope.wire,
      folder: folder,
      mediaKind: mediaKind,
      trashed: trashed,
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
            mediaKind: photo.mediaKind,
            mimeType: photo.mimeType,
            orientation: photo.orientation,
            captureTimeMs: photo.captureTimeMs?.toInt(),
            sortTimeMs: photo.sortTimeMs.toInt(),
            state: photo.state,
            trashedAtMs: photo.trashedAtMs?.toInt(),
            durationMs: photo.durationMs?.toInt(),
            motionOffset: photo.motionOffset?.toInt(),
          ),
      ],
      nextCursor: page.nextCursor,
      total: page.total.toInt(),
      revision: page.revision.toInt(),
    );
  }

  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    await native_library.openLibrary(dataRoot: dataRoot);
    final result = jsonDecode(
      await native_library.libraryTools(command: jsonEncode(command)),
    );
    if (command['op'] == 'clearCache') {
      _thumbnailCacheEpoch = null;
      ThumbnailPool.forGateway(this).clear(rebuild: true);
    }
    return result;
  }

  @override
  Future<List<LocalAlbum>> listAlbums() async {
    final albums = await native_library.listAlbums();
    return [
      for (final album in albums)
        LocalAlbum(
          path: album.path,
          name: album.name,
          count: album.count.toInt(),
          coverMediaId: album.coverMediaId,
          managed: album.managed,
        ),
    ];
  }

  @override
  Future<int> trashMedia(List<String> mediaIds) async =>
      (await native_library.trashMedia(mediaIds: mediaIds)).toInt();

  @override
  Future<int> restoreMedia(List<String> mediaIds) async =>
      (await native_library.restoreMedia(mediaIds: mediaIds)).toInt();

  @override
  Future<int> purgeMedia(List<String> mediaIds) async =>
      (await native_library.purgeMedia(mediaIds: mediaIds)).toInt();

  @override
  Future<int> emptyTrash() async => (await native_library.emptyTrash()).toInt();

  @override
  Future<int> addToAlbum(
    List<String> mediaIds,
    String targetFolder, {
    required bool moveFiles,
  }) async => (await native_library.addToAlbum(
    mediaIds: mediaIds,
    targetFolder: targetFolder,
    moveFiles: moveFiles,
  )).toInt();

  @override
  Future<LocalPhoto> renameMedia(String mediaId, String name) async {
    final photo = await native_library.renameMedia(
      mediaId: mediaId,
      name: name,
    );
    return LocalPhoto(
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
      mediaKind: photo.mediaKind,
      mimeType: photo.mimeType,
      orientation: photo.orientation,
      captureTimeMs: photo.captureTimeMs?.toInt(),
      sortTimeMs: photo.sortTimeMs.toInt(),
      state: photo.state,
      trashedAtMs: photo.trashedAtMs?.toInt(),
    );
  }

  @override
  Future<LocalPhoto> saveEdited(String mediaId, EditOptions options) async {
    final photo = await native_library.saveEdited(
      mediaId: mediaId,
      request: native_library.EditRequest(
        rotationDegrees: options.rotationDegrees,
        flipHorizontal: options.flipHorizontal,
        flipVertical: options.flipVertical,
        brightness: options.brightness,
        contrast: options.contrast,
        saturation: options.saturation,
        cropX: options.crop?.x,
        cropY: options.crop?.y,
        cropWidth: options.crop?.width,
        cropHeight: options.crop?.height,
        saveCopy: options.saveCopy,
        expectedContentVersion: options.expectedContentVersion == null
            ? null
            : BigInt.from(options.expectedContentVersion!),
      ),
    );
    return LocalPhoto(
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
      mediaKind: photo.mediaKind,
      mimeType: photo.mimeType,
      orientation: photo.orientation,
      captureTimeMs: photo.captureTimeMs?.toInt(),
      sortTimeMs: photo.sortTimeMs.toInt(),
      state: photo.state,
      trashedAtMs: photo.trashedAtMs?.toInt(),
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
  Future<Object?> thumbnailCommand(Map<String, Object?> command) async {
    final result = jsonDecode(
      await native_library.libraryTools(command: jsonEncode(command)),
    );
    if (command['op'] == 'thumbnailStats' && result is Map) {
      final epoch = result['cache_epoch'] as int?;
      if (_thumbnailCacheEpoch != null && epoch != _thumbnailCacheEpoch) {
        ThumbnailPool.forGateway(this).clear();
      }
      _thumbnailCacheEpoch = epoch;
    }
    return result;
  }

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

  CloudAccount _cloudAccount(native_cloud.CloudAccountView account) =>
      CloudAccount(
        accountId: account.accountId,
        endpoint: account.endpoint,
        username: account.username,
        userId: account.userId,
        active: account.active,
        signedIn: account.signedIn,
        lastSyncMs: account.lastSyncMs?.toInt(),
      );

  CloudActivity _cloudActivity(native_cloud.CloudActivityView activity) =>
      CloudActivity(
        phase: activity.phase,
        syncing: activity.syncing,
        startedAtMs: activity.startedAtMs?.toInt(),
        downloaded: activity.downloaded,
        downloadTotal: activity.downloadTotal,
        uploaded: activity.uploaded,
        uploadTotal: activity.uploadTotal,
        favoritesApplied: activity.favoritesApplied,
        favoritesUploaded: activity.favoritesUploaded,
        favoriteTotal: activity.favoriteTotal,
        skipped: activity.skipped,
        failed: activity.failed,
        errorCode: activity.errorCode,
      );

  CloudStatus _cloudStatus(native_cloud.CloudStatusView status) => CloudStatus(
    loggedIn: status.loggedIn,
    accountId: status.accountId,
    endpoint: status.endpoint,
    username: status.username,
    userId: status.userId,
    tokenExpiresAtMs: status.tokenExpiresAtMs?.toInt(),
    lastSyncMs: status.lastSyncMs?.toInt(),
    state: status.state,
    errorCode: status.errorCode,
    pendingUploads: status.pendingUploads,
    failedUploads: status.failedUploads,
    pendingFavorites: status.pendingFavorites,
    boundCount: status.boundCount,
    uploadScope: status.uploadScope,
    uploadAlbums: status.uploadAlbums,
    syncing: status.syncing,
    activity: _cloudActivity(status.activity),
    accounts: [for (final account in status.accounts) _cloudAccount(account)],
  );

  @override
  Future<CloudStatus> cloudLogin({
    required String endpoint,
    required String username,
    required String password,
  }) async => _cloudStatus(
    await native_cloud.cloudLogin(
      endpoint: endpoint,
      username: username,
      password: password,
    ),
  );

  @override
  Future<CloudStatus> cloudLogout() async =>
      _cloudStatus(await native_cloud.cloudLogout());

  @override
  Future<CloudStatus> cloudStatus() async =>
      _cloudStatus(await native_cloud.cloudStatus());

  @override
  Future<CloudSyncReport> cloudSyncNow() async {
    final report = await native_cloud.cloudSyncNow();
    return CloudSyncReport(
      downloaded: report.downloaded,
      downloadTotal: report.downloadTotal,
      uploaded: report.uploaded,
      uploadTotal: report.uploadTotal,
      favoritesApplied: report.favoritesApplied,
      favoritesUploaded: report.favoritesUploaded,
      favoriteTotal: report.favoriteTotal,
      skipped: report.skipped,
      failed: report.failed,
      state: report.state,
      errorCode: report.errorCode,
    );
  }

  @override
  Future<CloudQueueResult> cloudQueueUpload(List<String> mediaIds) async {
    final result = await native_cloud.cloudQueueUpload(mediaIds: mediaIds);
    return CloudQueueResult(
      queued: result.queued,
      skipped: result.skipped,
      rejected: result.rejected,
    );
  }

  @override
  Future<List<String>> cloudBoundMediaIds() =>
      native_cloud.cloudBoundMediaIds();

  @override
  Future<CloudStatus> cloudSwitchAccount(String accountId) async =>
      _cloudStatus(await native_cloud.cloudSwitchAccount(accountId: accountId));

  @override
  Future<CloudStatus> cloudRemoveAccount(String accountId) async =>
      _cloudStatus(await native_cloud.cloudRemoveAccount(accountId: accountId));

  @override
  Future<CloudStatus> cloudSetUploadScope(
    String mode,
    List<String> albums,
  ) async => _cloudStatus(
    await native_cloud.cloudSetUploadScope(mode: mode, albums: albums),
  );
}
