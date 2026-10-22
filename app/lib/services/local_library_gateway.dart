/// Native local-library contract. Paths are resolved by the platform/core adapter.
enum SearchScope { all, name, date }

extension SearchScopeWire on SearchScope {
  String get wire => name;
}

abstract interface class LocalLibraryGateway {
  Future<LocalLibraryInfo> openLibrary();
  Future<LocalPhotoPage> listPhotos({
    String? cursor,
    int limit = 100,
    bool favoritesOnly = false,
    String search = '',
    SearchScope searchScope = SearchScope.all,
    String? folder,
    String? mediaKind,
    bool trashed = false,
  });
  Future<List<LocalAlbum>> listAlbums();
  Future<int> trashMedia(List<String> mediaIds);
  Future<int> restoreMedia(List<String> mediaIds);
  Future<int> purgeMedia(List<String> mediaIds);
  Future<int> emptyTrash();
  Future<int> addToAlbum(
    List<String> mediaIds,
    String targetFolder, {
    required bool moveFiles,
  });
  Future<LocalPhoto> renameMedia(String mediaId, String name);
  Future<LocalPhoto> saveEdited(String mediaId, EditOptions options);
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

/// A square cover crops the longer axis. Account for the source aspect ratio
/// so a portrait's short edge still covers the tile's physical pixels.
int thumbnailSizeClassForCover(double devicePixels, LocalPhoto photo) {
  final width = photo.width, height = photo.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return thumbnailSizeClassFor(devicePixels);
  }
  return thumbnailSizeClassFor(
    devicePixels * (width > height ? width / height : height / width),
  );
}

/// Bucket decode targets so a one-pixel resize reuses decoded thumbnails.
int thumbnailDecodeWidth(double pixels) =>
    (((pixels.ceil() + 63) ~/ 64) * 64).clamp(64, 1024);

class LocalAlbum {
  const LocalAlbum({
    required this.path,
    required this.name,
    required this.count,
    this.coverMediaId,
  });
  final String path;
  final String name;
  final int count;
  final String? coverMediaId;
}

/// A pixel crop rectangle in the rotated image's coordinate space.
class CropBox {
  const CropBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final int x;
  final int y;
  final int width;
  final int height;
}

/// Editor adjustments; all values are the same ranges the UI exposes.
class EditOptions {
  const EditOptions({
    this.rotationDegrees = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.crop,
    this.saveCopy = false,
    this.expectedContentVersion,
  });

  /// Clockwise 0 / 90 / 180 / 270.
  final int rotationDegrees;
  final bool flipHorizontal, flipVertical;

  /// -100..100, 0 keeps the original.
  final int brightness;
  final int contrast;
  final int saturation;
  final CropBox? crop;

  /// Write a new sibling file instead of overwriting the original.
  final bool saveCopy;
  final int? expectedContentVersion;

  bool get isIdentity =>
      rotationDegrees % 360 == 0 &&
      !flipHorizontal &&
      !flipVertical &&
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      crop == null;

  EditOptions copyWith({
    int? rotationDegrees,
    bool? flipHorizontal,
    bool? flipVertical,
    int? brightness,
    int? contrast,
    int? saturation,
    CropBox? crop,
    bool clearCrop = false,
    bool? saveCopy,
    int? expectedContentVersion,
  }) => EditOptions(
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    flipVertical: flipVertical ?? this.flipVertical,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    crop: clearCrop ? null : crop ?? this.crop,
    saveCopy: saveCopy ?? this.saveCopy,
    expectedContentVersion:
        expectedContentVersion ?? this.expectedContentVersion,
  );
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
    this.mediaKind = 'image',
    this.mimeType = 'image/jpeg',
    this.orientation = 1,
    this.captureTimeMs,
    this.sortTimeMs,
    this.state = 'active',
    this.trashedAtMs,
    this.durationMs,
    this.motionOffset,
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
  final String mediaKind;
  final String mimeType;
  final int orientation;
  final int? captureTimeMs;
  final int? sortTimeMs;
  final String state;
  final int? trashedAtMs;
  final int? durationMs, motionOffset;

  factory LocalPhoto.fromJson(Map<String, dynamic> data) => LocalPhoto(
    id: data['id'] as String,
    path: data['path'] as String,
    name: data['name'] as String,
    parent: data['parent'] as String,
    sizeBytes: data['size_bytes'] as int,
    modifiedMs: data['modified_ms'] as int,
    contentVersion: data['content_version'] as int,
    width: data['width'] as int?,
    height: data['height'] as int?,
    favorite: data['favorite'] as bool,
    mediaKind: data['media_kind'] as String,
    mimeType: data['mime_type'] as String,
    orientation: data['orientation'] as int,
    captureTimeMs: data['capture_time_ms'] as int?,
    sortTimeMs: data['sort_time_ms'] as int?,
    state: data['state'] as String,
    trashedAtMs: data['trashed_at_ms'] as int?,
    durationMs: data['duration_ms'] as int?,
    motionOffset: data['motion_offset'] as int?,
  );

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
    mediaKind: mediaKind,
    mimeType: mimeType,
    orientation: orientation,
    captureTimeMs: captureTimeMs,
    sortTimeMs: sortTimeMs,
    state: state,
    trashedAtMs: trashedAtMs,
    durationMs: durationMs,
    motionOffset: motionOffset,
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
