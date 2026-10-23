import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import '../services/local_library_tools.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';

final sourcePickerProvider = Provider<LocalSourcePicker?>((ref) => null);
final localLibraryProvider =
    NotifierProvider<LocalLibraryController, LibraryViewState>(
      LocalLibraryController.new,
    );

enum LibraryProblem { load, nextPage, picker, scan, cancel, favorite, events }

class LibraryDateGroup {
  const LibraryDateGroup(this.time, this.count);
  final int time, count;
}

class LibraryViewState {
  const LibraryViewState({
    this.info,
    this.pages = const {},
    this.groups = const [],
    this.total = 0,
    this.extent = 0,
    this.revision = 0,
    this.queryEpoch = 0,
    this.anchorRank = 0,
    this.loading = true,
    this.loadingNext = false,
    this.hasNext = false,
    this.favoritesOnly = false,
    this.search = '',
    this.searchScope = SearchScope.all,
    this.folder,
    this.mediaKind,
    this.trashed = false,
    this.albums = const [],
    this.scanning = false,
    this.scanVisible = false,
    this.backgroundScanning = false,
    this.selecting = false,
    this.cancelRequested = false,
    this.favoritePending = const {},
    this.scanResult,
    this.problem,
  });
  final LocalLibraryInfo? info;
  final Map<int, List<LocalPhoto>> pages;
  final List<LibraryDateGroup> groups;
  final int total, extent, revision, queryEpoch;
  final int anchorRank;
  final bool loading, loadingNext, hasNext, favoritesOnly, scanning, selecting;

  /// Whether the running scan may be announced to the user.
  ///
  /// Only indexing a newly added directory earns that attention: every other
  /// scan keeps the library current without interrupting anyone.
  final bool scanVisible;

  /// A sweep the user never asked for: it refreshes the library on its own
  /// and stays invisible.
  final bool backgroundScanning;
  final bool cancelRequested;
  final String search;
  final SearchScope searchScope;
  final String? folder;
  final String? mediaKind;
  final bool trashed;
  final List<LocalAlbum> albums;
  final Set<String> favoritePending;
  final LocalScanResult? scanResult;
  final LibraryProblem? problem;

  LocalPhoto? photoAt(int index) {
    final page = pages[index ~/ LocalLibraryController.pageSize];
    final offset = index % LocalLibraryController.pageSize;
    return page != null && offset < page.length ? page[offset] : null;
  }

  int? indexOf(String id) {
    for (final entry in pages.entries) {
      final index = entry.value.indexWhere((photo) => photo.id == id);
      if (index >= 0) {
        return entry.key * LocalLibraryController.pageSize + index;
      }
    }
    return null;
  }

  LibraryViewState copyWith({
    LocalLibraryInfo? info,
    Map<int, List<LocalPhoto>>? pages,
    List<LibraryDateGroup>? groups,
    int? total,
    int? extent,
    int? revision,
    int? queryEpoch,
    int? anchorRank,
    bool? loading,
    bool? loadingNext,
    bool? hasNext,
    bool? favoritesOnly,
    String? search,
    SearchScope? searchScope,
    String? folder,
    bool clearFolder = false,
    String? mediaKind,
    bool clearMediaKind = false,
    bool? trashed,
    List<LocalAlbum>? albums,
    bool? scanning,
    bool? scanVisible,
    bool? backgroundScanning,
    bool? selecting,
    bool? cancelRequested,
    Set<String>? favoritePending,
    LocalScanResult? scanResult,
    LibraryProblem? problem,
    bool clearProblem = false,
    bool clearScanResult = false,
  }) => LibraryViewState(
    info: info ?? this.info,
    pages: pages ?? this.pages,
    groups: groups ?? this.groups,
    total: total ?? this.total,
    extent: extent ?? this.extent,
    revision: revision ?? this.revision,
    queryEpoch: queryEpoch ?? this.queryEpoch,
    anchorRank: anchorRank ?? this.anchorRank,
    loading: loading ?? this.loading,
    loadingNext: loadingNext ?? this.loadingNext,
    hasNext: hasNext ?? this.hasNext,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    search: search ?? this.search,
    searchScope: searchScope ?? this.searchScope,
    folder: clearFolder ? null : folder ?? this.folder,
    mediaKind: clearMediaKind ? null : mediaKind ?? this.mediaKind,
    trashed: trashed ?? this.trashed,
    albums: albums ?? this.albums,
    scanning: scanning ?? this.scanning,
    scanVisible: scanVisible ?? this.scanVisible,
    backgroundScanning: backgroundScanning ?? this.backgroundScanning,
    selecting: selecting ?? this.selecting,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    favoritePending: favoritePending ?? this.favoritePending,
    scanResult: clearScanResult ? null : scanResult ?? this.scanResult,
    problem: clearProblem ? null : problem ?? this.problem,
  );
}

class LocalLibraryController extends Notifier<LibraryViewState> {
  static const pageSize = 100;
  static const maxCachedPages = 8;
  late LocalLibraryGateway _gateway;
  StreamSubscription<void>? _events;
  Timer? _invalidationTimer;
  Timer? _searchTimer;
  bool _disposed = false;
  bool _eventsFailed = false;
  bool _started = false;
  int _generation = 0;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  final _cursors = <int, String?>{0: null};
  final _requests = <int, Future<void>>{};
  final _recent = <int>{};
  int _scanGeneration = 0;
  int _viewportIndex = 0;
  List<String> _lastPaths = [];
  bool get indexed => _gateway is LocalLibraryTools;
  void noteViewport(int index) {
    _viewportIndex = index;
  }

  @override
  LibraryViewState build() {
    _gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    ref.onDispose(() {
      _disposed = true;
      ++_generation;
      _invalidationTimer?.cancel();
      _searchTimer?.cancel();
      final subscription = _events;
      if (subscription != null) unawaited(_cancelEvents(subscription));
    });
    // The catalog lives in the same native session as the runtime, so opening
    // it before `initialize()` resolves fails with NotInitialized. Gate the
    // first read on the runtime reporting ready instead of racing it.
    ref.listen(runtimeProvider, (previous, next) {
      if (next.phase == ConnectionPhase.ready && !_started) {
        _started = true;
        scheduleMicrotask(refresh);
      }
      if (previous?.runtimeStatus != next.runtimeStatus) {
        final status = next.runtimeStatus;
        if (status == 'local_scan_started') {
          state = state.copyWith(scanning: true, clearScanResult: true);
        }
        if (status == 'local_scan_finished') {
          state = state.copyWith(
            scanning: false,
            scanVisible: false,
            cancelRequested: false,
          );
        }
        if (status == 'local_scan_failed') {
          state = state.copyWith(scanning: false, problem: LibraryProblem.scan);
        }
        // Background sweeps keep the library current behind the scenes. They
        // never raise the user's attention and never show progress.
        if (status == 'local_background_scan_started') {
          state = state.copyWith(backgroundScanning: true);
        }
        if (status == 'local_background_scan_finished' ||
            status == 'local_background_scan_failed') {
          state = state.copyWith(backgroundScanning: false);
        }
      }
    }, fireImmediately: true);
    ref.listen(presentationProvider.select((value) => value.order), (
      before,
      after,
    ) {
      if (before != null && before != after) {
        ++_generation;
        state = state.copyWith(
          queryEpoch: state.queryEpoch + 1,
          pages: {},
          extent: 0,
        );
        unawaited(refresh());
      }
    });
    return const LibraryViewState();
  }

  Map<String, Object?> filterFor(LibraryViewState query) => {
    'favorites_only': query.favoritesOnly,
    'search': query.search,
    'search_scope': query.searchScope.wire,
    'folder': query.folder,
    'media_kind': query.mediaKind,
    'trashed': query.trashed,
    'order': ref.read(presentationProvider).order,
  };
  Future<Object?> localCommand(Map<String, Object?> command) async {
    final gateway = _gateway;
    if (gateway is! LocalLibraryTools) return null;
    return (gateway as LocalLibraryTools).localCommand(command);
  }

  Future<LocalPhotoPage> _queryPage(
    LibraryViewState query,
    int index, {
    bool groups = false,
  }) async {
    if (!indexed) {
      return _gateway.listPhotos(
        cursor: _cursors[index],
        limit: pageSize,
        favoritesOnly: query.favoritesOnly,
        search: query.search,
        searchScope: query.searchScope,
        folder: query.folder,
        mediaKind: query.mediaKind,
        trashed: query.trashed,
      );
    }
    final data = await localCommand({
      'op': 'window',
      'filter': filterFor(query),
      'start': index * pageSize,
      'count': pageSize,
      'groups': groups,
    }) as Map;
    _queriedGroups = groups
        ? [
            for (final row in data['groups'] as List)
              LibraryDateGroup((row as List)[0] as int, row[1] as int),
          ]
        : _queriedGroups;
    final items = [
      for (final item in data['items'] as List)
        LocalPhoto.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
    return LocalPhotoPage(
      items: items,
      total: data['total'] as int,
      revision: data['revision'] as int,
      nextCursor: (index + 1) * pageSize < (data['total'] as int)
          ? 'indexed'
          : null,
    );
  }

  List<LibraryDateGroup> _queriedGroups = [];
  Future<List<LocalPhoto>> selectQuery({int limit = 2000}) async {
    final query = state;
    if (indexed) {
      final data = await localCommand({
        'op': 'selection',
        'filter': filterFor(query),
      }) as Map;
      return [
        for (final item in data['items'] as List)
          LocalPhoto.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    }
    final selected = <LocalPhoto>[];
    String? cursor;
    do {
      final page = await _gateway.listPhotos(
        cursor: cursor,
        limit: pageSize,
        favoritesOnly: query.favoritesOnly,
        search: query.search,
        searchScope: query.searchScope,
        folder: query.folder,
        mediaKind: query.mediaKind,
        trashed: query.trashed,
      );
      selected.addAll(page.items.take(limit - selected.length));
      cursor = page.nextCursor;
    } while (cursor != null && selected.length < limit);
    return selected;
  }

  Future<void> showDestination({
    bool favorites = false,
    String? folder,
    String? kind,
    bool trash = false,
  }) async {
    _searchTimer?.cancel();
    _changeQuery(
      search: '',
      favoritesOnly: favorites,
      folder: folder,
      clearFolder: folder == null,
      mediaKind: kind,
      clearMediaKind: kind == null,
      trashed: trash,
    );
  }

  Future<void> _cancelEvents(StreamSubscription<void> events) async {
    try {
      await events.cancel();
    } catch (_) {
      /* Native shutdown owns final release. */
    }
  }

  void _invalidate() {
    if (_disposed) return;
    // Throttle rather than debounce: a long scan still shows progressive updates.
    _invalidationTimer ??= Timer(const Duration(milliseconds: 300), () {
      _invalidationTimer = null;
      unawaited(refresh());
    });
  }

  /// [force] awaits any in-flight refresh and then reads again, so callers that
  /// just finished a write never observe a snapshot taken before their commit.
  Future<void> refresh({bool force = false}) async {
    if (_disposed) return;
    final inFlight = _refreshing;
    if (inFlight != null) {
      if (!force) {
        _refreshAgain = true;
        return inFlight;
      }
      await inFlight.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          // A wedged native call must not freeze every later refresh.
          _refreshing = null;
        },
      );
      if (_disposed) return;
    }
    final pending = _refreshing = _refresh().whenComplete(() {
      _refreshing = null;
      if (!_disposed && _refreshAgain) {
        _refreshAgain = false;
        _invalidate();
      }
    });
    await pending;
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    final query = state;
    state = state.copyWith(
      loading: true,
      loadingNext: false,
      clearProblem: true,
    );
    try {
      final info = await _gateway.openLibrary();
      if (_disposed) return;
      if (_eventsFailed) {
        final oldSubscription = _events;
        _events = null;
        // Cancelling a native stream can wait for its Rust task; a refresh must
        // never freeze on that, so the release happens in the background.
        if (oldSubscription != null) unawaited(_cancelEvents(oldSubscription));
        if (_disposed) return;
        _eventsFailed = false;
      }
      _events ??= _gateway.watchLibrary().listen(
        (_) => _invalidate(),
        onError: (Object error, StackTrace stack) {
          if (!_disposed) {
            _eventsFailed = true;
            state = state.copyWith(problem: LibraryProblem.events);
          }
        },
        onDone: () {
          if (!_disposed) {
            _eventsFailed = true;
            state = state.copyWith(problem: LibraryProblem.events);
          }
        },
      );
      var anchorRank = _viewportIndex;
      var pageIndex = indexed ? (_viewportIndex ~/ pageSize) : 0;
      if (indexed && _viewportIndex > 0) {
        final anchor = query.photoAt(_viewportIndex);
        if (anchor != null) {
          final rank = await localCommand({
            'op': 'rank',
            'filter': filterFor(query),
            'id': anchor.id,
          }) as int?;
          if (rank != null) {
            pageIndex = rank ~/ pageSize;
            anchorRank = rank;
          }
        }
      }
      var page = await _queryPage(query, pageIndex, groups: true);
      if (pageIndex * pageSize >= page.total && pageIndex > 0) {
        pageIndex = 0;
        page = await _queryPage(query, 0, groups: true);
      }
      // The sidebar keeps physical albums available in every destination,
      // including Trash; listAlbums only counts active media either way.
      final albums = await _gateway.listAlbums();
      if (_disposed || generation != _generation) return;
      if (page.revision < state.revision) {
        // A newer snapshot is already published; an older in-flight read must
        // not clobber totals/pages. Re-read instead.
        _invalidate();
        return;
      }
      _cursors
        ..clear()
        ..[0] = null;
      if (page.nextCursor != null) _cursors[1] = page.nextCursor;
      _requests.clear();
      _recent
        ..clear()
        ..add(pageIndex);
      state = state.copyWith(
        info: info,
        anchorRank: anchorRank,
        pages: {pageIndex: List.unmodifiable(page.items)},
        groups: indexed ? List.unmodifiable(_queriedGroups) : const [],
        total: page.total,
        extent: indexed ? page.total : page.items.length,
        revision: page.revision,
        loading: false,
        hasNext: page.nextCursor != null,
        albums: albums,
      );
    } catch (error) {
      debugPrint('LOCAL_LIBRARY_LOAD_FAILED: $error');
      if (!_disposed && generation == _generation) {
        state = state.copyWith(loading: false, problem: LibraryProblem.load);
      }
    }
  }

  void setSearch(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 300), () {
      if (!_disposed && state.search != value.trim()) {
        _changeQuery(search: value.trim());
      }
    });
  }

  void clearSearch() {
    _searchTimer?.cancel();
    if (state.search.isNotEmpty) _changeQuery(search: '');
  }

  void setSearchScope(SearchScope value) {
    if (state.searchScope == value) return;
    _changeQuery(searchScope: value);
  }

  void setFavorites(bool value) {
    if (state.favoritesOnly == value) return;
    _changeQuery(favoritesOnly: value);
  }

  void setFolder(String? folder) {
    if (state.folder == folder) return;
    _changeQuery(folder: folder, clearFolder: folder == null);
  }

  void setMediaKind(String? mediaKind) {
    if (state.mediaKind == mediaKind) return;
    _changeQuery(mediaKind: mediaKind, clearMediaKind: mediaKind == null);
  }

  void setTrashed(bool value) {
    if (state.trashed == value) return;
    _changeQuery(trashed: value);
  }

  void _changeQuery({
    String? search,
    SearchScope? searchScope,
    bool? favoritesOnly,
    String? folder,
    bool clearFolder = false,
    String? mediaKind,
    bool clearMediaKind = false,
    bool? trashed,
  }) {
    ++_generation;
    _viewportIndex = 0;
    _cursors
      ..clear()
      ..[0] = null;
    _recent.clear();
    _requests.clear();
    state = state.copyWith(
      search: search,
      searchScope: searchScope,
      favoritesOnly: favoritesOnly,
      folder: folder,
      clearFolder: clearFolder,
      mediaKind: mediaKind,
      clearMediaKind: clearMediaKind,
      trashed: trashed,
      pages: {},
      groups: const [],
      extent: 0,
      hasNext: false,
      loading: true,
      queryEpoch: state.queryEpoch + 1,
      clearProblem: true,
    );
    unawaited(refresh());
  }

  Future<void> loadNext() async {
    if (indexed || _disposed || state.loading || !state.hasNext) return;
    await ensurePage((state.extent / pageSize).ceil());
  }

  Future<void> ensurePage(int pageIndex) {
    if (pageIndex < 0 ||
        (indexed && pageIndex * pageSize >= state.total) ||
        _disposed ||
        state.loading ||
        (!indexed && !_cursors.containsKey(pageIndex))) {
      return Future<void>.value();
    }
    if (state.pages.containsKey(pageIndex)) {
      _recent
        ..remove(pageIndex)
        ..add(pageIndex);
      return Future<void>.value();
    }
    final generation = _generation;
    return _requests[pageIndex] ??= _loadPage(pageIndex).whenComplete(() {
      if (generation == _generation) _requests.remove(pageIndex);
    });
  }

  Future<void> _loadPage(int pageIndex) async {
    final generation = _generation;
    final query = state;
    state = state.copyWith(loadingNext: true, clearProblem: true);
    try {
      final page = await _queryPage(query, pageIndex);
      if (_disposed || generation != _generation) return;
      if (page.revision != state.revision) {
        _invalidate();
        return;
      }
      if (page.nextCursor != null) _cursors[pageIndex + 1] = page.nextCursor;
      final pages = Map<int, List<LocalPhoto>>.of(state.pages);
      pages[pageIndex] = List.unmodifiable(page.items);
      _recent
        ..remove(pageIndex)
        ..add(pageIndex);
      while (_recent.length > maxCachedPages) {
        pages.remove(_recent.first);
        _recent.remove(_recent.first);
      }
      final frontier = pageIndex * pageSize + page.items.length;
      state = state.copyWith(
        pages: Map.unmodifiable(pages),
        total: page.total,
        extent: indexed
            ? page.total
            : (frontier > state.extent ? frontier : state.extent),
        hasNext: frontier >= state.extent
            ? page.nextCursor != null
            : state.hasNext,
        loadingNext: false,
      );
    } catch (_) {
      if (!_disposed && generation == _generation) {
        state = state.copyWith(
          loadingNext: false,
          problem: LibraryProblem.nextPage,
        );
      }
    }
  }

  Future<LocalPhoto?> photoAt(int index) async {
    if (index < 0 || index >= state.total) return null;
    await ensurePage(index ~/ pageSize);
    if (_disposed) return null;
    return state.photoAt(index);
  }

  Future<void> importSources(
    LocalSourcePicker picker, {
    required bool directory,
  }) async {
    if (_disposed || state.scanning || state.selecting) return;
    state = state.copyWith(selecting: true, clearProblem: true);
    List<String> paths;
    try {
      if (directory) {
        final path = await picker.chooseDirectory();
        paths = path == null ? [] : [path];
      } else {
        paths = await picker.chooseFiles();
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          selecting: false,
          problem: LibraryProblem.picker,
        );
      }
      return;
    }
    if (_disposed) return;
    if (paths.isEmpty) {
      state = state.copyWith(selecting: false);
      return;
    }
    // Indexing a newly added directory is the one scan a user waits for;
    // picking individual files keeps the library current on its own.
    await scanPaths(paths, visible: directory);
  }

  Future<void> scanPaths(List<String> paths, {required bool visible}) async {
    if (_disposed || state.scanning) return;
    _lastPaths = List.of(paths);
    ++_scanGeneration;
    state = state.copyWith(
      selecting: false,
      scanning: true,
      scanVisible: visible,
      cancelRequested: false,
      clearScanResult: true,
    );
    try {
      final result = await _gateway.addPaths(paths);
      if (_disposed) return;
      state = state.copyWith(
        scanning: false,
        scanVisible: false,
        cancelRequested: false,
        scanResult: result,
      );
      await refresh(force: true);
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          scanning: false,
          scanVisible: false,
          cancelRequested: false,
          problem: LibraryProblem.scan,
        );
      }
    }
  }

  Future<void> retryScan() => _lastPaths.isEmpty
      ? rescanSources()
      : scanPaths(_lastPaths, visible: false);
  Future<void> rescanSources() async {
    final data = await localCommand({'op': 'sources'}) as List?;
    if (data == null) return;
    final paths = [
      for (final source in data)
        if ((source as Map)['enabled'] == true && source['kind'] != 'managed')
          source['path'] as String,
    ];
    // A rescan of known sources is maintenance: it never interrupts the user.
    if (paths.isNotEmpty) await scanPaths(paths, visible: false);
  }

  Future<void> cancelScan() async {
    if (_disposed || !state.scanning || state.cancelRequested) return;
    final generation = _scanGeneration;
    state = state.copyWith(cancelRequested: true, clearProblem: true);
    try {
      await _gateway.cancelScan();
      // An acknowledgement is not scan completion; addPaths owns the result.
    } catch (_) {
      if (!_disposed && state.scanning && generation == _scanGeneration) {
        state = state.copyWith(
          cancelRequested: false,
          problem: LibraryProblem.cancel,
        );
      }
    }
  }

  Future<void> setFavorite(LocalPhoto photo) async {
    if (_disposed || state.favoritePending.contains(photo.id)) return;
    state = state.copyWith(
      favoritePending: {...state.favoritePending, photo.id},
      clearProblem: state.problem == LibraryProblem.favorite,
    );
    try {
      await _gateway.setFavorite(photo.id, !photo.favorite);
      if (_disposed) return;
      final pages = <int, List<LocalPhoto>>{
        for (final entry in state.pages.entries)
          entry.key: [
            for (final item in entry.value)
              item.id == photo.id ? item.withFavorite(!photo.favorite) : item,
          ],
      };
      state = state.copyWith(
        pages: pages,
        favoritePending: {...state.favoritePending}..remove(photo.id),
      );
      if (state.favoritesOnly) _invalidate();
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          favoritePending: {...state.favoritePending}..remove(photo.id),
          problem: LibraryProblem.favorite,
        );
      }
    }
  }

  Future<int> trashPhotos(Iterable<String> mediaIds) async {
    final ids = mediaIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    final count = await _gateway.trashMedia(ids);
    await refresh(force: true);
    return count;
  }

  Future<int> restorePhotos(Iterable<String> mediaIds) async {
    final ids = mediaIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    final count = await _gateway.restoreMedia(ids);
    await refresh(force: true);
    return count;
  }

  Future<int> purgePhotos(Iterable<String> mediaIds) async {
    final ids = mediaIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    final count = await _gateway.purgeMedia(ids);
    await refresh(force: true);
    return count;
  }

  Future<int> emptyTrash() async {
    final count = await _gateway.emptyTrash();
    await refresh(force: true);
    return count;
  }

  Future<int> addPhotosToAlbum(
    Iterable<String> mediaIds,
    String targetFolder, {
    required bool moveFiles,
  }) async {
    final ids = mediaIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    final count = await _gateway.addToAlbum(
      ids,
      targetFolder,
      moveFiles: moveFiles,
    );
    await refresh(force: true);
    return count;
  }

  Future<LocalPhoto> saveEdited(String mediaId, EditOptions options) async {
    final photo = await _gateway.saveEdited(mediaId, options);
    await refresh(force: true);
    return photo;
  }

  Future<LocalPhoto> renamePhoto(String mediaId, String name) async {
    final photo = await _gateway.renameMedia(mediaId, name);
    await refresh(force: true);
    return photo;
  }
}
