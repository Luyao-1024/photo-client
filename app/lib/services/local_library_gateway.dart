/// Native local-library contract. Paths are resolved by the platform/core adapter.
abstract interface class LocalLibraryGateway {
  Future<LocalLibraryInfo> openLibrary();
  Future<LocalPhotoPage> listPhotos({
    String? cursor,
    int limit = 100,
    bool favoritesOnly = false,
    String search = '',
    String? folder,
  });
  Future<LocalScanResult> addPaths(List<String> paths);
  Future<void> cancelScan();
  Future<String> thumbnail(String mediaId, {int sizeClass = 512});
  Future<void> setFavorite(String mediaId, bool favorite);
  Stream<void> watchLibrary();
}

abstract interface class LocalSourcePicker {
  Future<List<String>> chooseFiles();
  Future<String?> chooseDirectory();
}

/// Cache classes owned by the native thumbnail cache; UI must not invent keys.
const List<int> kThumbnailSizeClasses = [256, 512, 1024];

/// Smallest cached class that still covers the requested device pixels.
int thumbnailSizeClassFor(double devicePixels) {
  for (final sizeClass in kThumbnailSizeClasses) {
    if (devicePixels <= sizeClass) return sizeClass;
  }
  return kThumbnailSizeClasses.last;
}

class LocalLibraryInfo {
  const LocalLibraryInfo({
    required this.libraryId,
    required this.count,
    required this.revision,
  });
  final String libraryId;
  final int count;
  final int revision;
}

class LocalPhoto {
  const LocalPhoto({
    required this.id,
    required this.path,
    required this.name,
    required this.parent,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.contentVersion,
    this.width,
    this.height,
    required this.favorite,
  });
  final String id;
  final String path;
  final String name;
  final String parent;
  final int sizeBytes;
  final int modifiedMs;
  final int contentVersion;
  final int? width;
  final int? height;
  final bool favorite;

  LocalPhoto withFavorite(bool value) => LocalPhoto(
    id: id,
    path: path,
    name: name,
    parent: parent,
    sizeBytes: sizeBytes,
    modifiedMs: modifiedMs,
    contentVersion: contentVersion,
    width: width,
    height: height,
    favorite: value,
  );
}

class LocalPhotoPage {
  const LocalPhotoPage({
    required this.items,
    this.nextCursor,
    required this.total,
    required this.revision,
  });
  final List<LocalPhoto> items;
  final String? nextCursor;
  final int total;
  final int revision;
}

class LocalScanResult {
  const LocalScanResult({
    required this.discovered,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });
  final int discovered;
  final int skipped;
  final int failed;
  final bool cancelled;
}
