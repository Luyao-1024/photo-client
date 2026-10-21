import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_photo_viewer.dart';
import 'mode_selector.dart';
import 'photos_grid.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';

/// The Photos page: glass header (search + selection chrome), a quiet two-line
/// overview, a date-sectioned square-tile grid, and the floating Year/Month/Day
/// capsule. See photoViewer/docs/modules/ui-design.md "Photos Page".
class LocalLibraryPane extends ConsumerStatefulWidget {
  const LocalLibraryPane({
    super.key,
    this.onOpenSettings,
    this.onRequestSearch,
    this.trashMode = false,
    this.searchMode = false,
  });

  /// Supplied by the shell once Settings owns source management; null keeps
  /// the empty-state button honestly disabled.
  final VoidCallback? onOpenSettings;

  /// Asks the shell to switch to the dedicated search destination. When null
  /// the pane falls back to an inline search field.
  final VoidCallback? onRequestSearch;
  final bool trashMode;
  final bool searchMode;

  @override
  ConsumerState<LocalLibraryPane> createState() => _LocalLibraryPaneState();
}

class _LocalLibraryPaneState extends ConsumerState<LocalLibraryPane> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _scheduledPages = <int>{};
  late final FocusNode _searchFocus = FocusNode(onKeyEvent: _onSearchKey);
  int _epoch = -1;
  bool _searchOpen = false;
  GroupMode _mode = GroupMode.day;
  bool _selectionMode = false;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
  }

  void _nearEnd() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 600) {
      unawaited(ref.read(localLibraryProvider.notifier).loadNext());
    }
  }

  /// Lazily (re)request the pages around a tile that is actually being built,
  /// i.e. visible or within the viewport cache extent. The one-page lookahead
  /// fills evicted holes adjacent to visible content and chains inward as the
  /// reloaded tiles rebuild, without ever touching the whole extent per build.
  void _ensureNear(int index) {
    final page = index ~/ LocalLibraryController.pageSize;
    for (final candidate in [page - 1, page, page + 1]) {
      if (candidate < 0 || !_scheduledPages.add(candidate)) continue;
      scheduleMicrotask(() async {
        if (!mounted) return;
        await ref.read(localLibraryProvider.notifier).ensurePage(candidate);
        if (!mounted) return;
        final state = ref.read(localLibraryProvider);
        if (state.pages.containsKey(candidate)) {
          // Loaded: drop the marker so a later eviction can request again.
          _scheduledPages.remove(candidate);
        } else if (state.problem == null) {
          // No-op (e.g. no cursor yet): allow a later build to retry.
          _scheduledPages.remove(candidate);
        }
        // A failed load keeps the marker: never retry-loop a broken page.
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LocalLibraryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchMode && !oldWidget.searchMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openSearch() {
    final request = widget.onRequestSearch;
    if (request != null) {
      request();
      return;
    }
    setState(() {
      _searchOpen = true;
      _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    if (!mounted) return;
    setState(() => _searchOpen = false);
  }

  void _exitSelection() {
    if (!_selectionMode && _selected.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _enterSelection(String id) => setState(() {
    _selectionMode = true;
    _selected.add(id);
  });

  void _toggleSelection(String id) => setState(() {
    _selectionMode = true;
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _selectAll(LibraryViewState state) => setState(() {
    _selectionMode = true;
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo != null) _selected.add(photo.id);
    }
  });

  void _deselectAll() => setState(() => _selected.clear());

  bool _allLoadedSelected(LibraryViewState state) {
    var loaded = 0;
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo == null) continue;
      loaded += 1;
      if (!_selected.contains(photo.id)) return false;
    }
    return loaded > 0;
  }

  List<LocalPhoto> _selectedPhotos(LibraryViewState state) {
    final photos = <LocalPhoto>[];
    for (final id in _selected) {
      final index = state.indexOf(id);
      if (index == null) continue;
      final photo = state.photoAt(index);
      if (photo != null) photos.add(photo);
    }
    return photos;
  }

  /// Smart heart: all favorited → unfavorite all; otherwise favorite every
  /// not-yet-favorited photo (a mixed set resolves toward favorited).
  void _batchFavorite(LibraryViewState state) {
    final controller = ref.read(localLibraryProvider.notifier);
    final photos = _selectedPhotos(state);
    if (photos.isEmpty) return;
    final allFavorite = photos.every((photo) => photo.favorite);
    for (final photo in photos) {
      if (allFavorite || !photo.favorite) {
        unawaited(controller.setFavorite(photo));
      }
    }
  }

  // --- Destructive / structural batch operations -------------------------

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-action'),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _runBatch(
    Future<int> Function() operation,
    String Function(int) message,
  ) async {
    final strings = AppStrings.of(context);
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
    try {
      final count = await operation();
      _notify(message(count));
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  String _folderLabel(String path) {
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    final name = trimmed.split('/').where((p) => p.isNotEmpty).lastOrNull;
    return name == null || name.isEmpty ? path : name;
  }

  List<String> _selectedIds(LibraryViewState state) =>
      _selectedPhotos(state).map((photo) => photo.id).toList(growable: false);

  Future<void> _batchTrash() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmTrashTitle(ids.length),
      body: strings.confirmTrashBody,
      confirmLabel: strings.moveToTrash,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).trashPhotos(ids),
      strings.trashedCount,
    );
  }

  Future<void> _batchRestore() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).restorePhotos(ids),
      strings.restoredCount,
    );
  }

  Future<void> _batchPurge() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmPurgeTitle(ids.length),
      body: strings.confirmPurgeBody,
      confirmLabel: strings.deletePermanently,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).purgePhotos(ids),
      strings.purgedCount,
    );
  }

  Future<void> _emptyTrash() async {
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmEmptyTrashTitle,
      body: strings.confirmEmptyTrashBody,
      confirmLabel: strings.emptyTrash,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      ref.read(localLibraryProvider.notifier).emptyTrash,
      strings.purgedCount,
    );
  }

  Future<void> _addToAlbum({required bool move}) async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final target = await _pickAlbumTarget(state.albums);
    if (target == null || !mounted) return;
    await _runBatch(
      () => ref
          .read(localLibraryProvider.notifier)
          .addPhotosToAlbum(ids, target, moveFiles: move),
      strings.addedToAlbumCount,
    );
  }

  Future<String?> _pickAlbumTarget(List<LocalAlbum> albums) async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => _AlbumPickerDialog(albums: albums),
    );
    if (selection != _AlbumPickerDialog.newAlbumSentinel) return selection;
    final picker = ref.read(sourcePickerProvider);
    if (picker == null) return null;
    final directory = await picker.chooseDirectory();
    return directory;
  }

  Future<void> _trashOne(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmTrashTitle(1),
      body: strings.confirmTrashBody,
      confirmLabel: strings.moveToTrash,
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(localLibraryProvider.notifier).trashPhotos([photo.id]);
      _notify(strings.trashedCount(1));
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  Future<void> _addOneToAlbum(LocalPhoto photo, {required bool move}) async {
    final strings = AppStrings.of(context);
    final target = await _pickAlbumTarget(
      ref.read(localLibraryProvider).albums,
    );
    if (target == null || !mounted) return;
    try {
      await ref
          .read(localLibraryProvider.notifier)
          .addPhotosToAlbum([photo.id], target, moveFiles: move);
      _notify(strings.addedToAlbumCount(1));
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  Future<void> _renamePhoto(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    final controller = TextEditingController(text: photo.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.renamePhoto),
        content: TextField(
          key: const ValueKey('rename-field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: photo.name),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('rename-confirm'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == photo.name) return;
    try {
      await ref.read(localLibraryProvider.notifier).renamePhoto(photo.id, name);
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final runtime = ref.watch(runtimeProvider);
    if (runtime.phase != ConnectionPhase.ready) {
      // The runtime is an implementation detail: users see library loading and
      // a retry, never a "core" status they cannot act on.
      final failed =
          runtime.phase == ConnectionPhase.failed ||
          runtime.phase == ConnectionPhase.stopped;
      return _StatusPage(
        titleKey: const ValueKey('library-runtime'),
        title: failed ? strings.libraryFailed : strings.loadingLibrary,
        body: failed ? strings.libraryFailedBody : null,
        spinner: !failed,
        action: failed
            ? FilledButton.icon(
                key: const ValueKey('retry-runtime'),
                onPressed: () =>
                    ref.read(runtimeProvider.notifier).initialize(),
                icon: const Icon(Icons.refresh),
                label: Text(strings.retry),
              )
            : null,
      );
    }
    final state = ref.watch(localLibraryProvider);
    final controller = ref.read(localLibraryProvider.notifier);
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    if (_epoch != state.queryEpoch) {
      _epoch = state.queryEpoch;
      _scheduledPages.clear();
      if (_search.text != state.search) {
        _search.text = state.search;
      }
      // Selection survives epoch changes on purpose: favorite toggles and
      // background refreshes bump the epoch, and dropping the batch mid-action
      // would strand the user. Stale ids simply resolve to no photo.
      if (_scroll.hasClients && _scroll.offset != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
    }
    final hasContent = state.extent > 0 || state.hasNext;
    final title = widget.searchMode
        ? strings.search
        : widget.trashMode
        ? strings.trash
        : state.favoritesOnly
        ? strings.albumFavorites
        : state.folder != null
        ? _folderLabel(state.folder!)
        : state.mediaKind == 'image'
        ? strings.images
        : state.mediaKind == 'video'
        ? strings.videos
        : strings.library;
    return Column(
      children: [
        _Header(
          glass: preferences.glass,
          title: title,
          trashMode: widget.trashMode,
          searchMode: widget.searchMode,
          scope: state.searchScope,
          onScopeChanged: controller.setSearchScope,
          searchOpen: _searchOpen,
          searchController: _search,
          searchFocus: _searchFocus,
          onOpenSearch: _openSearch,
          onCloseSearch: _closeSearch,
          onSearchChanged: controller.setSearch,
          selectionMode: _selectionMode,
          selectionCount: _selected.length,
          allLoadedSelected: hasContent && _allLoadedSelected(state),
          onSelectAll: () => _selectAll(state),
          onDeselectAll: _deselectAll,
          onExitSelection: _exitSelection,
          selectedPhotos: _selectionMode ? _selectedPhotos(state) : const [],
          onBatchFavorite: () => _batchFavorite(state),
          onBatchTrash: _batchTrash,
          onBatchRestore: _batchRestore,
          onBatchPurge: _batchPurge,
          onBatchAddToAlbum: (move) => _addToAlbum(move: move),
          onEmptyTrash: _emptyTrash,
          emptyTrashEnabled: state.extent > 0 || state.hasNext,
          strings: strings,
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _body(strings, state, controller, gateway, preferences),
              ),
              if (hasContent && !widget.searchMode)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: ModeSelector(
                      mode: _mode,
                      glass: preferences.glass,
                      onChanged: (mode) => setState(() => _mode = mode),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
    LocalLibraryGateway gateway,
    PresentationPreferences preferences,
  ) {
    final bindings = <ShortcutActivator, VoidCallback>{
      // While the search field is open, Ctrl+A belongs to text editing.
      if (!_searchOpen)
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            _selectAll(state),
      if (_selectionMode)
        const SingleActivator(LogicalKeyboardKey.escape): _exitSelection,
    };
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        // Tab skips this wrapper, but it holds initial focus so Ctrl+A works
        // before any tile is focused; key events from tiles bubble up here.
        autofocus: true,
        skipTraversal: true,
        child: _scrollBody(strings, state, controller, gateway, preferences),
      ),
    );
  }

  Widget _scrollBody(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
    LocalLibraryGateway gateway,
    PresentationPreferences preferences,
  ) {
    final status = _statusPage(strings, state, controller);
    if (status != null) {
      return CustomScrollView(
        key: const ValueKey('local-photo-grid'),
        controller: _scroll,
        slivers: [SliverFillRemaining(hasScrollBody: false, child: status)],
      );
    }
    final sections = widget.searchMode
        ? _searchSections(state, strings)
        : _sections(state);
    return CustomScrollView(
      key: const ValueKey('local-photo-grid'),
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(child: _overview(strings, state, controller)),
        for (final section in sections) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
              child: Text(
                widget.searchMode
                    ? section.label ?? ''
                    : sectionLabel(context, section, _mode),
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700, fontSize: 22),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: gridMaxCrossAxisExtent(_mode),
                mainAxisSpacing: gridSpacing(_mode),
                crossAxisSpacing: gridSpacing(_mode),
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate((context, tileIndex) {
                final item = section.items[tileIndex];
                // Builders only run for children in (or just outside) the
                // viewport, so page loading stays lazy and bounded.
                _ensureNear(item.index);
                return PhotoTile(
                  key: ValueKey('photo-${item.photo.id}'),
                  photo: item.photo,
                  gateway: gateway,
                  selected: _selected.contains(item.photo.id),
                  multiSelect: _selectionMode,
                  onOpen: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LocalPhotoViewer(
                        photo: item.photo,
                        initialIndex: item.index,
                      ),
                    ),
                  ),
                  onSelectToggle: () => _toggleSelection(item.photo.id),
                  onEnterSelection: () => _enterSelection(item.photo.id),
                  onToggleFavorite: () =>
                      unawaited(controller.setFavorite(item.photo)),
                  onShowDetails: () => showPhotoDetails(context, item.photo),
                  onRename: () => _renamePhoto(item.photo),
                  onMoveToTrash: widget.trashMode
                      ? null
                      : () => _trashOne(item.photo),
                  onCopyToAlbum: widget.trashMode
                      ? null
                      : () => _addOneToAlbum(item.photo, move: false),
                  onMoveToAlbum: widget.trashMode
                      ? null
                      : () => _addOneToAlbum(item.photo, move: true),
                );
              }, childCount: section.items.length),
            ),
          ),
        ],
        if (state.hasNext || state.loadingNext)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: state.loadingNext
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        key: const ValueKey('load-next-page'),
                        onPressed: controller.loadNext,
                        child: Text(strings.loadMore),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  /// Group the loaded paged window into date sections, newest bucket first.
  /// Never schedules loads across the whole extent: with a bounded DTO cache,
  /// eagerly requesting every missing page would evict and reload endlessly.
  /// Page loading is driven by [_ensureNear] from visible tiles instead.
  List<PhotoSection> _sections(LibraryViewState state) {
    final grouped = <int, PhotoSection>{};
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo == null) continue;
      // A loaded page can be evicted later; allow another request on return.
      _scheduledPages.remove(index ~/ LocalLibraryController.pageSize);
      final date = DateTime.fromMillisecondsSinceEpoch(
        photo.captureTimeMs ?? photo.modifiedMs,
      );
      final bucket = bucketOf(date, _mode);
      grouped
          .putIfAbsent(bucket, () => PhotoSection(bucket: bucket, date: date))
          .items
          .add(SectionItem(photo, index));
    }
    final ordered = grouped.values.toList()
      ..sort((a, b) => b.bucket.compareTo(a.bucket));
    return ordered;
  }

  /// Search results split by media type (matching photoViewer's search page);
  /// the date-bucket mode selector does not apply here.
  List<PhotoSection> _searchSections(
    LibraryViewState state,
    AppStrings strings,
  ) {
    final now = DateTime.now();
    final images = PhotoSection(bucket: 1, date: now, label: strings.images);
    final videos = PhotoSection(bucket: 0, date: now, label: strings.videos);
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo == null) continue;
      _scheduledPages.remove(index ~/ LocalLibraryController.pageSize);
      (photo.mediaKind == 'video' ? videos : images).items.add(
        SectionItem(photo, index),
      );
    }
    return [
      if (images.items.isNotEmpty) images,
      if (videos.items.isNotEmpty) videos,
    ];
  }

  /// Three distinct empty states, never one "no photos" sentence: indexing,
  /// scan failed (with retry), and empty library (Open Settings).
  Widget? _statusPage(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
  ) {
    if (state.scanning && state.extent == 0) {
      return _StatusPage(title: strings.scanning, spinner: true);
    }
    if (state.problem == LibraryProblem.scan) {
      return _StatusPage(
        titleKey: const ValueKey('library-error'),
        title: strings.scanFailed,
        body: strings.libraryError('scan'),
        action: FilledButton(
          key: const ValueKey('retry-library'),
          onPressed: state.loading
              ? null
              : () {
                  _scheduledPages.clear();
                  unawaited(controller.refresh());
                },
          child: Text(strings.retryScan),
        ),
      );
    }
    if (state.problem != null && state.extent == 0) {
      final problem = state.problem!;
      return _StatusPage(
        titleKey: const ValueKey('library-error'),
        title: strings.libraryError(problem.name),
        action: FilledButton(
          key: const ValueKey('retry-library'),
          onPressed: state.loading
              ? null
              : () {
                  _scheduledPages.clear();
                  unawaited(controller.refresh());
                },
          child: Text(strings.refresh),
        ),
      );
    }
    if (state.loading && state.extent == 0) {
      return _StatusPage(title: strings.loadingLibrary, spinner: true);
    }
    if (widget.trashMode) {
      if (state.extent == 0 && !state.hasNext) {
        return _StatusPage(
          title: strings.trashEmpty,
          titleKey: const ValueKey('trash-empty'),
        );
      }
      return null;
    }
    if (widget.searchMode && state.extent == 0 && !state.hasNext) {
      return _StatusPage(
        title: state.search.isEmpty ? strings.searchPrompt : strings.noMatches,
        body: state.search.isEmpty ? null : strings.noMatchesBody,
      );
    }
    if (state.extent == 0 && !state.hasNext) {
      final filtered =
          state.favoritesOnly ||
          state.search.isNotEmpty ||
          state.folder != null ||
          state.mediaKind != null;
      if (filtered) {
        return _StatusPage(
          title: strings.noMatches,
          body: strings.noMatchesBody,
        );
      }
      return _StatusPage(
        title: strings.emptyLibrary,
        action: FilledButton(
          key: const ValueKey('open-settings'),
          onPressed: widget.onOpenSettings,
          child: Text(strings.openSettings),
        ),
      );
    }
    return null;
  }

  /// Quiet backgroundless two-line overview: full-library count plus a
  /// scan/status line.
  Widget _overview(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.photosCountLabel(state.total),
            key: const ValueKey('library-info'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall ?? const TextStyle(),
            child: state.scanning
                ? Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(strings.indexing),
                      const SizedBox(width: 4),
                      TextButton(
                        key: const ValueKey('cancel-scan'),
                        onPressed: state.cancelRequested
                            ? null
                            : controller.cancelScan,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          state.cancelRequested
                              ? strings.cancellingScan
                              : strings.cancelScan,
                        ),
                      ),
                    ],
                  )
                : state.scanResult != null
                ? Text(
                    strings.scanSummary(
                      state.scanResult!.discovered,
                      state.scanResult!.skipped,
                      state.scanResult!.failed,
                      state.scanResult!.cancelled,
                    ),
                  )
                : Text(
                    strings.pick(
                      '修订 ${state.revision}',
                      'Revision ${state.revision}',
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.glass,
    required this.title,
    required this.trashMode,
    required this.searchMode,
    required this.scope,
    required this.onScopeChanged,
    required this.searchOpen,
    required this.searchController,
    required this.searchFocus,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onSearchChanged,
    required this.selectionMode,
    required this.selectionCount,
    required this.allLoadedSelected,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.onExitSelection,
    required this.selectedPhotos,
    required this.onBatchFavorite,
    required this.onBatchTrash,
    required this.onBatchRestore,
    required this.onBatchPurge,
    required this.onBatchAddToAlbum,
    required this.onEmptyTrash,
    required this.emptyTrashEnabled,
    required this.strings,
  });

  final bool glass;
  final String title;
  final bool trashMode;
  final bool searchMode;
  final SearchScope scope;
  final ValueChanged<SearchScope> onScopeChanged;
  final bool searchOpen;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final ValueChanged<String> onSearchChanged;
  final bool selectionMode;
  final int selectionCount;
  final bool allLoadedSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;
  final VoidCallback onExitSelection;
  final List<LocalPhoto> selectedPhotos;
  final VoidCallback onBatchFavorite;
  final VoidCallback onBatchTrash;
  final VoidCallback onBatchRestore;
  final VoidCallback onBatchPurge;
  final ValueChanged<bool> onBatchAddToAlbum;
  final VoidCallback onEmptyTrash;
  final bool emptyTrashEnabled;
  final AppStrings strings;

  bool get _showField => searchOpen || searchMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      enabled: glass,
      radius: 0,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (_showField)
                        Flexible(
                          child: _SearchField(
                            controller: searchController,
                            focusNode: searchFocus,
                            onChanged: onSearchChanged,
                            onClose: searchMode ? null : onCloseSearch,
                            glass: glass,
                            strings: strings,
                          ),
                        )
                      else
                        _RoundSearchButton(
                          onPressed: onOpenSearch,
                          tooltip: strings.search,
                        ),
                      if (_showField && !trashMode) ...[
                        const SizedBox(width: 10),
                        _ScopeSelector(
                          scope: scope,
                          onChanged: onScopeChanged,
                          glass: glass,
                        ),
                      ],
                      if (selectionMode) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('select-all'),
                            onPressed: allLoadedSelected
                                ? onDeselectAll
                                : onSelectAll,
                            child: Text(
                              allLoadedSelected
                                  ? strings.deselectAll
                                  : strings.selectAll,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('exit-selection'),
                            onPressed: onExitSelection,
                            child: Text(
                              strings.exitSelection,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_showField || trashMode)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _trailing(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trailing(BuildContext context) {
    if (selectionMode && selectionCount > 0) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              strings.selectedCountLabel(selectionCount),
              key: const ValueKey('selection-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          _batchActions(context),
        ],
      );
    }
    if (trashMode) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton.icon(
          key: const ValueKey('empty-trash'),
          onPressed: emptyTrashEnabled ? onEmptyTrash : null,
          icon: const Icon(Icons.delete_forever_outlined, size: 18),
          label: Text(strings.emptyTrash),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _batchActions(BuildContext context) {
    if (trashMode) {
      return Row(
        children: [
          Tooltip(
            message: strings.restore,
            child: _GlassActionButton(
              key: const ValueKey('batch-restore'),
              glass: glass,
              icon: Icons.restore_from_trash_outlined,
              onPressed: selectedPhotos.isEmpty ? null : onBatchRestore,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: strings.deletePermanently,
            child: _GlassActionButton(
              key: const ValueKey('batch-purge'),
              glass: glass,
              icon: Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
              onPressed: selectedPhotos.isEmpty ? null : onBatchPurge,
            ),
          ),
        ],
      );
    }
    final allFavorite =
        selectedPhotos.isNotEmpty &&
        selectedPhotos.every((photo) => photo.favorite);
    final mixed = !allFavorite && selectedPhotos.any((photo) => photo.favorite);
    return Row(
      children: [
        Tooltip(
          message: strings.addToAlbum,
          child: PopupMenuButton<bool>(
            key: const ValueKey('batch-add-to-album'),
            tooltip: strings.addToAlbum,
            enabled: selectedPhotos.isNotEmpty,
            onSelected: onBatchAddToAlbum,
            itemBuilder: (context) => [
              PopupMenuItem<bool>(
                value: false,
                child: Text(strings.copyToAlbum),
              ),
              PopupMenuItem<bool>(
                value: true,
                child: Text(strings.moveToAlbum),
              ),
            ],
            child: _GlassActionButton(
              glass: glass,
              icon: Icons.add,
              onPressed: selectedPhotos.isEmpty ? null : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: mixed
              ? strings.pick('收藏 / 取消收藏', 'Favorite / Unfavorite')
              : allFavorite
              ? strings.unmarkFavorite
              : strings.markFavorite,
          child: _GlassActionButton(
            key: const ValueKey('batch-favorite'),
            glass: glass,
            icon: allFavorite || mixed ? Icons.favorite : Icons.favorite_border,
            color: allFavorite ? const Color(0xb3e5534b) : null,
            badge: mixed,
            onPressed: selectedPhotos.isEmpty ? null : onBatchFavorite,
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: strings.moveToTrash,
          child: _GlassActionButton(
            key: const ValueKey('batch-trash'),
            glass: glass,
            icon: Icons.delete_outline,
            onPressed: selectedPhotos.isEmpty ? null : onBatchTrash,
          ),
        ),
      ],
    );
  }
}

/// All / Name / Date segmented scope control for the search field.
class _ScopeSelector extends StatelessWidget {
  const _ScopeSelector({
    required this.scope,
    required this.onChanged,
    required this.glass,
  });

  final SearchScope scope;
  final ValueChanged<SearchScope> onChanged;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final entries = <(SearchScope, String)>[
      (SearchScope.all, strings.searchAll),
      (SearchScope.name, strings.searchByName),
      (SearchScope.date, strings.searchByDate),
    ];
    return GlassSurface(
      key: const ValueKey('search-scope'),
      enabled: glass,
      radius: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in entries)
            _ScopeChip(
              key: ValueKey('search-scope-${value.name}'),
              label: label,
              selected: scope == value,
              onTap: () => onChanged(value),
            ),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Destination chooser for copy/move-to-album. Returns a folder path, or
/// [newAlbumSentinel] to ask the caller to run the directory picker.
class _AlbumPickerDialog extends StatelessWidget {
  const _AlbumPickerDialog({required this.albums});

  static const String newAlbumSentinel = '__photo_client_new_album__';
  final List<LocalAlbum> albums;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return AlertDialog(
      title: Text(strings.chooseAlbum),
      content: SizedBox(
        width: 360,
        child: albums.isEmpty
            ? Text(strings.noAlbums)
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final album in albums)
                      ListTile(
                        key: ValueKey('album-target-${album.path}'),
                        leading: const Icon(Icons.photo_album_outlined),
                        title: Text(album.name),
                        subtitle: Text(strings.photosCountLabel(album.count)),
                        onTap: () => Navigator.of(context).pop(album.path),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('album-picker-new'),
          onPressed: () =>
              Navigator.of(context).pop(_AlbumPickerDialog.newAlbumSentinel),
          child: Text(strings.newAlbum),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

/// Circular icon-only search button: bare at rest, glass capsule only on
/// hover/focus (the `.round-search-button` rule).
class _RoundSearchButton extends StatelessWidget {
  const _RoundSearchButton({required this.onPressed, required this.tooltip});

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final capsule = dark
        ? Colors.white.withValues(alpha: .14)
        : Colors.black.withValues(alpha: .07);
    return IconButton(
      key: const ValueKey('library-search'),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.search),
      style:
          IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            padding: const EdgeInsets.all(8),
            shape: const CircleBorder(),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                  ? capsule
                  : Colors.transparent,
            ),
          ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    required this.glass,
    required this.strings,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClose;
  final bool glass;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      key: const ValueKey('library-search'),
      enabled: glass,
      radius: 20,
      child: SizedBox(
        height: 40,
        width: 280,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.search, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                onChanged: onChanged,
                onSubmitted: (_) => onClose?.call(),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: strings.searchHint,
                ),
              ),
            ),
            if (onClose != null)
              IconButton(
                key: const ValueKey('library-search-close'),
                tooltip: strings.close,
                icon: const Icon(Icons.close, size: 18),
                style: IconButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                ),
                onPressed: onClose,
              ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

/// Always-on glass toolbar button: the capsule is present at rest so the
/// revealed batch-action set stands out.
class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    super.key,
    required this.glass,
    required this.icon,
    required this.onPressed,
    this.color,
    this.badge = false,
  });

  final bool glass;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      enabled: glass,
      radius: 19,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              icon: Icon(icon),
              color: color,
              onPressed: onPressed,
              iconSize: 20,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                minimumSize: const Size(38, 38),
                padding: EdgeInsets.zero,
              ),
            ),
            if (badge)
              Positioned(
                right: 3,
                bottom: 3,
                child: IgnorePointer(
                  child: Icon(
                    Icons.arrow_drop_down,
                    size: 12,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusPage extends StatelessWidget {
  const _StatusPage({
    required this.title,
    this.titleKey,
    this.body,
    this.spinner = false,
    this.action,
  });

  final String title;
  final Key? titleKey;
  final String? body;
  final bool spinner;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinner)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(),
              )
            else
              Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            const SizedBox(height: 16),
            Text(
              title,
              key: titleKey,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
