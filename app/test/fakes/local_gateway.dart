import 'dart:async';

import 'package:photo_client/services/local_library_gateway.dart';

import '../presentation_test.dart' show FakeGateway;

class FakeLocalGateway extends FakeGateway implements LocalLibraryGateway {
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
