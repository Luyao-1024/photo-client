import 'dart:async';

import 'package:photo_client/services/cloud_sync_gateway.dart';
import 'package:photo_client/services/local_library_gateway.dart';
import 'package:photo_client/services/local_library_tools.dart';

import '../presentation_test.dart' show FakeGateway;

class FakeLocalGateway extends FakeGateway
    implements LocalLibraryGateway, CloudSyncGateway {
  FakeLocalGateway({required this.imagePath, int count = 0}) {
    photos = List.generate(count, (index) => photo(index));
  }
  final String imagePath;
  late List<LocalPhoto> photos;
  final changes = StreamController<void>.broadcast();
  int revision = 1;
  int listCalls = 0;
  int openCalls = 0;
  int scans = 0;
  int favorites = 0;
  int cancellationsRequested = 0;
  bool failOpen = false;
  bool failList = false;
  bool failFavorite = false;
  int trashCalls = 0;
  int restoreCalls = 0;
  int purgeCalls = 0;
  int emptyTrashCalls = 0;
  int addToAlbumCalls = 0;
  int renameCalls = 0;
  bool failTrash = false;
  Completer<LocalPhotoPage>? pendingPage;
  Completer<LocalScanResult>? pendingScan;
  List<String>? addedPaths;
  final limits = <int>[];
  final requestedSearches = <String>[];
  final requestedScopes = <SearchScope>[];
  final requestedKinds = <String?>[];
  final requestedFolders = <String?>[];
  final requestedTrashed = <bool>[];
  final requestedAdds = <(List<String>, String, bool)>[];
  final requestedRenames = <(String, String)>[];
  CloudStatus cloudState = const CloudStatus();
  Set<String> cloudBoundIds = {};
  CloudSyncReport cloudReport = const CloudSyncReport();
  bool failCloudLogin = false;
  bool failCloudSync = false;
  int cloudLoginCalls = 0;
  int cloudLogoutCalls = 0;
  int cloudSyncCalls = 0;
  int cloudSwitchCalls = 0;
  int cloudRemoveCalls = 0;
  int cloudScopeCalls = 0;
  (String, List<String>)? lastCloudScope;
  final cloudUploadCalls = <List<String>>[];
  final cloudSeenPasswords = <String>[];

  LocalPhoto photo(
    int index, {
    bool favorite = false,
    String state = 'active',
    String? parent,
    String? name,
    String mediaKind = 'image',
    String mimeType = 'image/jpeg',
    int? captureTimeMs,
  }) => LocalPhoto(
    id: 'p$index',
    path: imagePath,
    name: name ?? 'Photo $index.png',
    parent: parent ?? '/local/photos',
    sizeBytes: 68,
    modifiedMs: 1700000000000,
    contentVersion: 1,
    width: 1,
    height: 1,
    favorite: favorite,
    mediaKind: mediaKind,
    mimeType: mimeType,
    captureTimeMs: captureTimeMs,
    sortTimeMs: captureTimeMs ?? 1700000000000,
    state: state,
  );

  @override
  Future<LocalLibraryInfo> openLibrary() async {
    openCalls++;
    if (failOpen) throw StateError('PRIVATE database path');
    return LocalLibraryInfo(
      libraryId: 'local-test-library',
      count: photos.length,
      revision: revision,
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
    listCalls++;
    limits.add(limit);
    requestedSearches.add(search);
    requestedScopes.add(searchScope);
    requestedKinds.add(mediaKind);
    requestedFolders.add(folder);
    requestedTrashed.add(trashed);
    if (failList) throw StateError('PRIVATE SQL');
    final pending = pendingPage;
    if (pending != null) return pending.future;
    final needle = search.toLowerCase();
    final filtered = photos
        .where(
          (photo) =>
              (trashed ? photo.state == 'trashed' : photo.state == 'active') &&
              (!favoritesOnly || photo.favorite) &&
              (mediaKind == null || photo.mediaKind == mediaKind) &&
              (folder == null || photo.parent == folder) &&
              (needle.isEmpty ||
                  (searchScope == SearchScope.date
                      ? _dateKey(photo).contains(needle)
                      : photo.name.toLowerCase().contains(needle))),
        )
        .toList();
    final offset = cursor == null ? 0 : int.parse(cursor.split(':').last);
    if (cursor != null && int.parse(cursor.split(':').first) != revision) {
      throw StateError('Page invalidated');
    }
    final items = filtered.skip(offset).take(limit).toList();
    return LocalPhotoPage(
      items: items,
      total: filtered.length,
      revision: revision,
      nextCursor: offset + items.length < filtered.length
          ? '$revision:${offset + items.length}'
          : null,
    );
  }

  static String _dateKey(LocalPhoto photo) =>
      DateTime.fromMillisecondsSinceEpoch(
        photo.captureTimeMs ?? photo.modifiedMs,
      ).toIso8601String().substring(0, 10);

  @override
  Future<CloudStatus> cloudLogin({
    required String endpoint,
    required String username,
    required String password,
  }) async {
    cloudLoginCalls++;
    cloudSeenPasswords.add(password);
    if (failCloudLogin) throw StateError('AuthFailed');
    final accounts = [
      for (final account in cloudState.accounts)
        if (account.endpoint != endpoint || account.username != username)
          CloudAccount(
            accountId: account.accountId,
            endpoint: account.endpoint,
            username: account.username,
            userId: account.userId,
            active: false,
            signedIn: account.signedIn,
            lastSyncMs: account.lastSyncMs,
          ),
      CloudAccount(
        accountId: 'account-${cloudState.accounts.length + 1}',
        endpoint: endpoint,
        username: username,
        active: true,
        signedIn: true,
      ),
    ];
    final active = accounts.last;
    cloudState = CloudStatus(
      loggedIn: true,
      accountId: active.accountId,
      endpoint: endpoint,
      username: username,
      state: 'idle',
      pendingUploads: cloudState.pendingUploads,
      boundCount: cloudBoundIds.length,
      uploadScope: cloudState.uploadScope,
      uploadAlbums: cloudState.uploadAlbums,
      accounts: accounts,
    );
    return cloudState;
  }

  @override
  Future<CloudStatus> cloudLogout() async {
    cloudLogoutCalls++;
    cloudState = CloudStatus(
      accountId: cloudState.accountId,
      username: cloudState.username,
      endpoint: cloudState.endpoint,
      state: 'logged_out',
      boundCount: cloudBoundIds.length,
      uploadScope: cloudState.uploadScope,
      uploadAlbums: cloudState.uploadAlbums,
      accounts: [
        for (final account in cloudState.accounts)
          CloudAccount(
            accountId: account.accountId,
            endpoint: account.endpoint,
            username: account.username,
            userId: account.userId,
            active: account.active,
            signedIn: account.active ? false : account.signedIn,
            lastSyncMs: account.lastSyncMs,
          ),
      ],
    );
    return cloudState;
  }

  @override
  Future<CloudStatus> cloudStatus() async => cloudState;

  @override
  Future<CloudSyncReport> cloudSyncNow() async {
    cloudSyncCalls++;
    if (failCloudSync) throw StateError('Network');
    cloudState = CloudStatus(
      loggedIn: cloudState.loggedIn,
      accountId: cloudState.accountId,
      endpoint: cloudState.endpoint,
      username: cloudState.username,
      state: cloudReport.errorCode == null ? 'idle' : 'error',
      errorCode: cloudReport.errorCode,
      lastSyncMs: 1700000000000,
      pendingUploads: 0,
      pendingFavorites: 0,
      boundCount: cloudBoundIds.length,
      uploadScope: cloudState.uploadScope,
      uploadAlbums: cloudState.uploadAlbums,
      activity: CloudActivity(
        phase: cloudReport.errorCode == null ? 'idle' : 'error',
        downloaded: cloudReport.downloaded,
        downloadTotal: cloudReport.downloadTotal,
        uploaded: cloudReport.uploaded,
        uploadTotal: cloudReport.uploadTotal,
        favoritesApplied: cloudReport.favoritesApplied,
        favoritesUploaded: cloudReport.favoritesUploaded,
        favoriteTotal: cloudReport.favoriteTotal,
        skipped: cloudReport.skipped,
        failed: cloudReport.failed,
        errorCode: cloudReport.errorCode,
      ),
      accounts: cloudState.accounts,
    );
    return cloudReport;
  }

  @override
  Future<CloudStatus> cloudSwitchAccount(String accountId) async {
    cloudSwitchCalls++;
    CloudAccount? target;
    for (final account in cloudState.accounts) {
      if (account.accountId == accountId) {
        target = account;
        break;
      }
    }
    if (target == null) throw StateError('AccountNotFound');
    final accounts = [
      for (final account in cloudState.accounts)
        CloudAccount(
          accountId: account.accountId,
          endpoint: account.endpoint,
          username: account.username,
          userId: account.userId,
          active: account.accountId == accountId,
          signedIn: account.signedIn,
          lastSyncMs: account.lastSyncMs,
        ),
    ];
    cloudState = CloudStatus(
      loggedIn: target.signedIn,
      accountId: target.accountId,
      endpoint: target.endpoint,
      username: target.username,
      state: target.signedIn ? 'idle' : 'logged_out',
      pendingUploads: cloudState.pendingUploads,
      pendingFavorites: cloudState.pendingFavorites,
      boundCount: cloudBoundIds.length,
      uploadScope: cloudState.uploadScope,
      uploadAlbums: cloudState.uploadAlbums,
      accounts: accounts,
    );
    return cloudState;
  }

  @override
  Future<CloudStatus> cloudRemoveAccount(String accountId) async {
    cloudRemoveCalls++;
    final accounts = [
      for (final account in cloudState.accounts)
        if (account.accountId != accountId) account,
    ];
    final removedActive = cloudState.accountId == accountId;
    cloudState = CloudStatus(
      loggedIn: removedActive ? false : cloudState.loggedIn,
      accountId: removedActive ? null : cloudState.accountId,
      endpoint: removedActive ? null : cloudState.endpoint,
      username: removedActive ? null : cloudState.username,
      state: removedActive ? 'logged_out' : cloudState.state,
      pendingUploads: cloudState.pendingUploads,
      pendingFavorites: cloudState.pendingFavorites,
      boundCount: cloudBoundIds.length,
      uploadScope: removedActive ? 'none' : cloudState.uploadScope,
      uploadAlbums: removedActive ? const [] : cloudState.uploadAlbums,
      accounts: accounts,
    );
    return cloudState;
  }

  @override
  Future<CloudStatus> cloudSetUploadScope(
    String mode,
    List<String> albums,
  ) async {
    cloudScopeCalls++;
    lastCloudScope = (mode, List<String>.of(albums));
    cloudState = CloudStatus(
      loggedIn: cloudState.loggedIn,
      accountId: cloudState.accountId,
      endpoint: cloudState.endpoint,
      username: cloudState.username,
      state: cloudState.state,
      errorCode: cloudState.errorCode,
      lastSyncMs: cloudState.lastSyncMs,
      pendingUploads: cloudState.pendingUploads,
      pendingFavorites: cloudState.pendingFavorites,
      boundCount: cloudState.boundCount,
      uploadScope: mode,
      uploadAlbums: albums,
      syncing: cloudState.syncing,
      activity: cloudState.activity,
      accounts: cloudState.accounts,
    );
    return cloudState;
  }

  @override
  Future<CloudQueueResult> cloudQueueUpload(List<String> mediaIds) async {
    cloudUploadCalls.add(List<String>.of(mediaIds));
    final pending = mediaIds.where((id) => !cloudBoundIds.contains(id)).length;
    return CloudQueueResult(
      queued: pending,
      skipped: mediaIds.length - pending,
    );
  }

  @override
  Future<List<String>> cloudBoundMediaIds() async => cloudBoundIds.toList();

  @override
  Future<List<LocalAlbum>> listAlbums() async {
    final byParent = <String, List<LocalPhoto>>{};
    for (final photo in photos) {
      if (photo.state != 'active') continue;
      byParent.putIfAbsent(photo.parent, () => []).add(photo);
    }
    final albums = <LocalAlbum>[];
    for (final entry in byParent.entries) {
      albums.add(
        LocalAlbum(
          path: entry.key,
          name: entry.key.split('/').where((p) => p.isNotEmpty).last,
          count: entry.value.length,
          coverMediaId: entry.value.first.id,
        ),
      );
    }
    return albums;
  }

  @override
  Future<int> trashMedia(List<String> mediaIds) async {
    trashCalls++;
    if (failTrash) throw StateError('PRIVATE trash error');
    final ids = mediaIds.toSet();
    var moved = 0;
    photos = [
      for (final photo in photos)
        if (ids.contains(photo.id) && photo.state == 'active')
          (() {
            moved++;
            return _copy(photo, state: 'trashed');
          })()
        else
          photo,
    ];
    revision++;
    changes.add(null);
    return moved;
  }

  @override
  Future<int> restoreMedia(List<String> mediaIds) async {
    restoreCalls++;
    final ids = mediaIds.toSet();
    var restored = 0;
    photos = [
      for (final photo in photos)
        if (ids.contains(photo.id) && photo.state == 'trashed')
          (() {
            restored++;
            return _copy(photo, state: 'active');
          })()
        else
          photo,
    ];
    revision++;
    changes.add(null);
    return restored;
  }

  @override
  Future<int> purgeMedia(List<String> mediaIds) async {
    purgeCalls++;
    final ids = mediaIds.toSet();
    final before = photos.length;
    photos = [
      for (final photo in photos)
        if (!(ids.contains(photo.id) && photo.state == 'trashed')) photo,
    ];
    revision++;
    changes.add(null);
    return before - photos.length;
  }

  @override
  Future<int> emptyTrash() async {
    emptyTrashCalls++;
    final before = photos.length;
    photos = [
      for (final photo in photos)
        if (photo.state != 'trashed') photo,
    ];
    revision++;
    changes.add(null);
    return before - photos.length;
  }

  @override
  Future<int> addToAlbum(
    List<String> mediaIds,
    String targetFolder, {
    required bool moveFiles,
  }) async {
    addToAlbumCalls++;
    requestedAdds.add((mediaIds, targetFolder, moveFiles));
    final ids = mediaIds.toSet();
    var changed = 0;
    final next = <LocalPhoto>[];
    for (final photo in photos) {
      if (ids.contains(photo.id) && photo.state == 'active') {
        changed++;
        next.add(_copy(photo, parent: targetFolder));
      } else {
        next.add(photo);
      }
    }
    photos = next;
    revision++;
    changes.add(null);
    return changed;
  }

  @override
  Future<LocalPhoto> renameMedia(String mediaId, String name) async {
    renameCalls++;
    requestedRenames.add((mediaId, name));
    late LocalPhoto renamed;
    photos = [
      for (final photo in photos)
        if (photo.id == mediaId) renamed = _copy(photo, name: name) else photo,
    ];
    revision++;
    changes.add(null);
    return renamed;
  }

  final requestedEdits = <(String, EditOptions)>[];

  @override
  Future<LocalPhoto> saveEdited(String mediaId, EditOptions options) async {
    requestedEdits.add((mediaId, options));
    late LocalPhoto edited;
    photos = [
      for (final photo in photos)
        if (photo.id == mediaId)
          edited = LocalPhoto(
            id: photo.id,
            path: photo.path,
            name: photo.name,
            parent: photo.parent,
            sizeBytes: photo.sizeBytes,
            modifiedMs: photo.modifiedMs + 1,
            contentVersion: photo.contentVersion + 1,
            width: photo.width,
            height: photo.height,
            favorite: photo.favorite,
            mediaKind: photo.mediaKind,
            mimeType: photo.mimeType,
            orientation: photo.orientation,
            captureTimeMs: photo.captureTimeMs,
            sortTimeMs: photo.sortTimeMs,
            state: photo.state,
          )
        else
          photo,
    ];
    revision++;
    changes.add(null);
    return edited;
  }

  static LocalPhoto _copy(
    LocalPhoto photo, {
    bool? favorite,
    String? state,
    String? parent,
    String? name,
  }) => LocalPhoto(
    id: photo.id,
    path: photo.path,
    name: name ?? photo.name,
    parent: parent ?? photo.parent,
    sizeBytes: photo.sizeBytes,
    modifiedMs: photo.modifiedMs,
    contentVersion: photo.contentVersion,
    width: photo.width,
    height: photo.height,
    favorite: favorite ?? photo.favorite,
    mediaKind: photo.mediaKind,
    mimeType: photo.mimeType,
    orientation: photo.orientation,
    captureTimeMs: photo.captureTimeMs,
    sortTimeMs: photo.sortTimeMs,
    state: state ?? photo.state,
    trashedAtMs: photo.trashedAtMs,
  );

  @override
  Future<LocalScanResult> addPaths(List<String> paths) async {
    scans++;
    addedPaths = paths;
    final pending = pendingScan;
    if (pending != null) return pending.future;
    photos.add(photo(photos.length));
    revision++;
    changes.add(null);
    return const LocalScanResult(
      discovered: 1,
      skipped: 0,
      failed: 0,
      cancelled: false,
    );
  }

  @override
  Future<void> cancelScan() async {
    cancellationsRequested++;
  }

  final requestedSizeClasses = <int>[];

  @override
  Future<String> thumbnail(String mediaId, {int sizeClass = 512}) async {
    requestedSizeClasses.add(sizeClass);
    return imagePath;
  }

  @override
  Future<void> setFavorite(String mediaId, bool favorite) async {
    favorites++;
    if (failFavorite) throw StateError('PRIVATE write error');
    photos = [
      for (final photo in photos)
        photo.id == mediaId ? _copy(photo, favorite: favorite) : photo,
    ];
    revision++;
    changes.add(null);
  }

  @override
  Stream<void> watchLibrary() => changes.stream;
}

/// Renders list pages through the local-tools channel so viewer paths that
/// depend on metadata (editing, details) see the same data shape as native.
class FakeToolsGateway extends FakeLocalGateway implements LocalLibraryTools {
  FakeToolsGateway({required super.imagePath, super.count});

  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    switch (command['op']) {
      case 'preferences':
        return <String, Object?>{
          'theme': 'system',
          'transparency': 0.5,
          'backgroundBlur': 0.5,
          'followScroll': true,
          'reduceMotion': false,
          'autoPlayMotionPhoto': false,
          'dayColumns': 5,
          'thumbnailWorkers': 2,
          'logLevel': 'info',
          'order': 'date_desc',
          'cloudAutoSync': false,
        };
      case 'metadata':
        return <String, Object?>{'animated': false, 'hdr': false};
      case 'window':
        final page = await _query(command['filter'] as Map?);
        final start = command['start'] as int? ?? 0;
        final count = command['count'] as int? ?? page.total;
        return <String, Object?>{
          'items': [
            for (final photo in page.items.skip(start).take(count))
              _photoJson(photo),
          ],
          'total': page.total,
          'revision': page.revision,
          'groups': const <Object?>[],
        };
      case 'selection':
        final page = await _query(command['filter'] as Map?);
        return <String, Object?>{
          'items': [for (final photo in page.items) _photoJson(photo)],
        };
      case 'rank':
        final page = await _query(command['filter'] as Map?);
        final rank = page.items.indexWhere(
          (photo) => photo.id == command['id'],
        );
        return rank < 0 ? null : rank;
    }
    return null;
  }

  Future<LocalPhotoPage> _query(Map<dynamic, dynamic>? filter) => listPhotos(
    limit: 1 << 20,
    favoritesOnly: filter?['favorites_only'] == true,
    search: filter?['search'] as String? ?? '',
    searchScope: SearchScope.values.firstWhere(
      (scope) => scope.wire == filter?['search_scope'],
      orElse: () => SearchScope.all,
    ),
    folder: filter?['folder'] as String?,
    mediaKind: filter?['media_kind'] as String?,
    trashed: filter?['trashed'] == true,
  );

  static Map<String, Object?> _photoJson(LocalPhoto photo) => {
    'id': photo.id,
    'path': photo.path,
    'name': photo.name,
    'parent': photo.parent,
    'size_bytes': photo.sizeBytes,
    'modified_ms': photo.modifiedMs,
    'content_version': photo.contentVersion,
    'width': photo.width,
    'height': photo.height,
    'favorite': photo.favorite,
    'media_kind': photo.mediaKind,
    'mime_type': photo.mimeType,
    'orientation': photo.orientation,
    'capture_time_ms': photo.captureTimeMs,
    'sort_time_ms': photo.sortTimeMs,
    'state': photo.state,
    'trashed_at_ms': photo.trashedAtMs,
    'duration_ms': photo.durationMs,
    'motion_offset': photo.motionOffset,
  };
}

class FakePicker implements LocalSourcePicker {
  List<String> files = ['/chosen/photo.png'];
  String? directory = '/chosen/photos';
  int fileRequests = 0;
  int directoryRequests = 0;
  @override
  Future<List<String>> chooseFiles() async {
    fileRequests++;
    return files;
  }

  @override
  Future<String?> chooseDirectory() async {
    directoryRequests++;
    return directory;
  }
}
