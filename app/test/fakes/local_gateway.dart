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
  Completer<LocalPhotoPage>? pendingPage;
  Completer<LocalScanResult>? pendingScan;
  List<String>? addedPaths;
  final limits = <int>[];
  final requestedSearches = <String>[];

  LocalPhoto photo(int index, {bool favorite = false}) => LocalPhoto(
    id: 'p$index',
    path: imagePath,
    name: 'Photo $index.png',
    parent: '/local/photos',
    sizeBytes: 68,
    modifiedMs: 1700000000000,
    contentVersion: 1,
    width: 1,
    height: 1,
    favorite: favorite,
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
    String? folder,
  }) async {
    listCalls++;
    limits.add(limit);
    requestedSearches.add(search);
    if (failList) throw StateError('PRIVATE SQL');
    final pending = pendingPage;
    if (pending != null) return pending.future;
    final filtered = photos
        .where(
          (photo) =>
              (!favoritesOnly || photo.favorite) &&
              photo.name.toLowerCase().contains(search.toLowerCase()) &&
              (folder == null || photo.parent == folder),
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

  @override
  Future<String> thumbnail(String mediaId) async => imagePath;

  @override
  Future<void> setFavorite(String mediaId, bool favorite) async {
    favorites++;
    if (failFavorite) throw StateError('PRIVATE write error');
    photos = [
      for (final photo in photos)
        photo.id == mediaId ? photo.withFavorite(favorite) : photo,
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
