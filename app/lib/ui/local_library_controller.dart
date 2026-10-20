import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'runtime_controller.dart';

final sourcePickerProvider = Provider<LocalSourcePicker?>((ref) => null);
final localLibraryProvider =
    NotifierProvider<LocalLibraryController, LibraryViewState>(
      LocalLibraryController.new,
    );

enum LibraryProblem { load, nextPage, picker, scan, cancel, favorite, events }

class LibraryViewState {
  const LibraryViewState({
    this.info,
    this.pages = const {},
    this.total = 0,
    this.extent = 0,
    this.revision = 0,
    this.queryEpoch = 0,
    this.loading = true,
    this.loadingNext = false,
    this.hasNext = false,
    this.favoritesOnly = false,
    this.search = '',
    this.folder,
    this.scanning = false,
    this.selecting = false,
    this.cancelRequested = false,
    this.favoritePending = const {},
    this.scanResult,
    this.problem,
  });
  final LocalLibraryInfo? info;
  final Map<int, List<LocalPhoto>> pages;
  final int total, extent, revision, queryEpoch;
  final bool loading, loadingNext, hasNext, favoritesOnly, scanning, selecting;
  final bool cancelRequested;
  final String search;
  final String? folder;
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
    int? total,
    int? extent,
    int? revision,
    int? queryEpoch,
    bool? loading,
    bool? loadingNext,
    bool? hasNext,
    bool? favoritesOnly,
    String? search,
    String? folder,
    bool clearFolder = false,
    bool? scanning,
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
    total: total ?? this.total,
    extent: extent ?? this.extent,
    revision: revision ?? this.revision,
    queryEpoch: queryEpoch ?? this.queryEpoch,
    loading: loading ?? this.loading,
    loadingNext: loadingNext ?? this.loadingNext,
    hasNext: hasNext ?? this.hasNext,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    search: search ?? this.search,
    folder: clearFolder ? null : folder ?? this.folder,
    scanning: scanning ?? this.scanning,
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
  int _generation = 0;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  final _cursors = <int, String?>{0: null};
  final _requests = <int, Future<void>>{};
  final _recent = <int>{};
  int _scanGeneration = 0;

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
    scheduleMicrotask(refresh);
    return const LibraryViewState();
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

  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    if (_refreshing != null) {
      _refreshAgain = true;
      return _refreshing!;
    }
    return _refreshing = _refresh().whenComplete(() {
      _refreshing = null;
      if (!_disposed && _refreshAgain) {
        _refreshAgain = false;
        _invalidate();
      }
    });
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
        if (oldSubscription != null) await _cancelEvents(oldSubscription);
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
      final page = await _gateway.listPhotos(
        limit: pageSize,
        favoritesOnly: query.favoritesOnly,
        search: query.search,
        folder: query.folder,
      );
      if (_disposed || generation != _generation) return;
      _cursors
        ..clear()
        ..[0] = null;
      if (page.nextCursor != null) _cursors[1] = page.nextCursor;
      _requests.clear();
      _recent
        ..clear()
        ..add(0);
      state = state.copyWith(
        info: info,
        pages: {0: List.unmodifiable(page.items)},
        total: page.total,
        extent: page.items.length,
        revision: page.revision,
        loading: false,
        hasNext: page.nextCursor != null,
        queryEpoch: state.queryEpoch + 1,
      );
    } catch (_) {
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

  void setFavorites(bool value) {
    if (state.favoritesOnly == value) return;
    _changeQuery(favoritesOnly: value);
  }

  void setFolder(String? folder) =>
      _changeQuery(folder: folder, clearFolder: folder == null);

  void _changeQuery({
    String? search,
    bool? favoritesOnly,
    String? folder,
    bool clearFolder = false,
  }) {
    ++_generation;
    _cursors
      ..clear()
      ..[0] = null;
    _recent.clear();
    _requests.clear();
    state = state.copyWith(
      search: search,
      favoritesOnly: favoritesOnly,
      folder: folder,
      clearFolder: clearFolder,
      pages: {},
      extent: 0,
      hasNext: false,
      loading: true,
      queryEpoch: state.queryEpoch + 1,
      clearProblem: true,
    );
    unawaited(refresh());
  }

  Future<void> loadNext() async {
    if (_disposed || state.loading || !state.hasNext) return;
    await ensurePage((state.extent / pageSize).ceil());
  }

  Future<void> ensurePage(int pageIndex) {
    if (_disposed || state.loading || !_cursors.containsKey(pageIndex)) {
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
      final page = await _gateway.listPhotos(
        cursor: _cursors[pageIndex],
        limit: pageSize,
        favoritesOnly: query.favoritesOnly,
        search: query.search,
        folder: query.folder,
      );
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
        extent: frontier > state.extent ? frontier : state.extent,
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
    ++_scanGeneration;
    state = state.copyWith(
      selecting: false,
      scanning: true,
      cancelRequested: false,
      clearScanResult: true,
    );
    try {
      final result = await _gateway.addPaths(paths);
      if (_disposed) return;
      state = state.copyWith(
        scanning: false,
        cancelRequested: false,
        scanResult: result,
      );
      await refresh();
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          scanning: false,
          cancelRequested: false,
          problem: LibraryProblem.scan,
        );
      }
    }
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
}
