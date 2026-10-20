import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'local_library_controller.dart';
import 'local_media_tile.dart';
import 'local_photo_viewer.dart';
import 'runtime_controller.dart';
import 'strings.dart';

class LocalLibraryPane extends ConsumerStatefulWidget {
  const LocalLibraryPane({super.key});
  @override
  ConsumerState<LocalLibraryPane> createState() => _LocalLibraryPaneState();
}

class _LocalLibraryPaneState extends ConsumerState<LocalLibraryPane> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _scheduledPages = <int>{};
  int _epoch = -1;

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

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final runtime = ref.watch(runtimeProvider);
    if (runtime.phase != ConnectionPhase.ready) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            runtime.phase == ConnectionPhase.connecting
                ? strings.connecting
                : strings.failed,
          ),
        ),
      );
    }
    final state = ref.watch(localLibraryProvider);
    final controller = ref.read(localLibraryProvider.notifier);
    final picker = ref.watch(sourcePickerProvider);
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    if (_epoch != state.queryEpoch) {
      _epoch = state.queryEpoch;
      _scheduledPages.clear();
      if (_search.text != state.search && !_search.selection.isValid) {
        _search.text = state.search;
      }
      if (_scroll.hasClients && _scroll.offset != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
    }
    final busy = state.scanning || state.selecting;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: CustomScrollView(
        key: const ValueKey('local-photo-grid'),
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: picker == null
                          ? strings.pickerUnavailable
                          : strings.addFiles,
                      child: FilledButton.icon(
                        key: const ValueKey('add-files'),
                        onPressed: picker == null || busy
                            ? null
                            : () => controller.importSources(
                                picker,
                                directory: false,
                              ),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(strings.addFiles),
                      ),
                    ),
                    Tooltip(
                      message: picker == null
                          ? strings.pickerUnavailable
                          : strings.addFolder,
                      child: OutlinedButton.icon(
                        key: const ValueKey('add-folder'),
                        onPressed: picker == null || busy
                            ? null
                            : () => controller.importSources(
                                picker,
                                directory: true,
                              ),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(strings.addFolder),
                      ),
                    ),
                    if (state.scanning)
                      TextButton.icon(
                        key: const ValueKey('cancel-scan'),
                        onPressed: state.cancelRequested
                            ? null
                            : controller.cancelScan,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(
                          state.cancelRequested
                              ? strings.cancellingScan
                              : strings.cancelScan,
                        ),
                      ),
                    FilterChip(
                      key: const ValueKey('filter-favorites'),
                      label: Text(strings.favorites),
                      selected: state.favoritesOnly,
                      onSelected: controller.setFavorites,
                    ),
                    IconButton(
                      tooltip: strings.refresh,
                      onPressed: state.loading
                          ? null
                          : () {
                              _scheduledPages.clear();
                              unawaited(controller.refresh());
                            },
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('library-search'),
                  controller: _search,
                  onChanged: controller.setSearch,
                  decoration: InputDecoration(
                    labelText: strings.searchPhotos,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    isDense: true,
                  ),
                ),
                if (state.folder != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InputChip(
                      label: Text('${strings.folderFilter}: ${state.folder}'),
                      onDeleted: () => controller.setFolder(null),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    state.selecting
                        ? strings.selecting
                        : state.scanning
                        ? strings.scanning
                        : state.info == null
                        ? strings.loadingLibrary
                        : strings.photoCount(state.total),
                  ),
                ),
                if (state.scanResult case final result?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      strings.scanSummary(
                        result.discovered,
                        result.skipped,
                        result.failed,
                        result.cancelled,
                      ),
                    ),
                  ),
                if (state.problem case final problem?)
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            strings.libraryError(problem.name),
                            key: const ValueKey('library-error'),
                          ),
                          TextButton(
                            key: const ValueKey('retry-library'),
                            onPressed: state.loading
                                ? null
                                : () {
                                    _scheduledPages.clear();
                                    unawaited(controller.refresh());
                                  },
                            child: Text(strings.refresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (state.loading && state.extent > 0)
                  const LinearProgressIndicator(),

                if (state.info case final info?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Tooltip(
                      message: info.libraryId,
                      child: Text(
                        strings.librarySummary(info.count, info.revision),
                        key: const ValueKey('library-info'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (state.loading && state.extent == 0)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Semantics(
                  label: strings.loadingLibrary,
                  child: const CircularProgressIndicator(),
                ),
              ),
            )
          else if (state.extent == 0 && state.problem == null)
            SliverToBoxAdapter(
              child: _EmptyLibrary(
                filtered:
                    state.favoritesOnly ||
                    state.search.isNotEmpty ||
                    state.folder != null,
              ),
            )
          else if (state.extent > 0)
            SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: .86,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index == state.extent) {
                  return Center(
                    child: OutlinedButton(
                      key: const ValueKey('load-next-page'),
                      onPressed: state.loadingNext ? null : controller.loadNext,
                      child: Text(
                        state.loadingNext
                            ? strings.loadingLibrary
                            : strings.loadMore,
                      ),
                    ),
                  );
                }
                final photo = state.photoAt(index);
                if (photo == null) {
                  final page = index ~/ LocalLibraryController.pageSize;
                  if (_scheduledPages.add(page)) {
                    scheduleMicrotask(() {
                      if (mounted) unawaited(controller.ensurePage(page));
                    });
                  }
                  return const Center(child: Icon(Icons.photo_outlined));
                }
                // A loaded page can be evicted later; allow another request on return.
                _scheduledPages.remove(
                  index ~/ LocalLibraryController.pageSize,
                );
                return LocalMediaTile(
                  key: ValueKey('photo-${photo.id}'),
                  photo: photo,
                  gateway: gateway,
                  onOpen: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          LocalPhotoViewer(photo: photo, initialIndex: index),
                    ),
                  ),
                );
              }, childCount: state.extent + (state.hasNext ? 1 : 0)),
            ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.filtered});
  final bool filtered;
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.photo_library_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              filtered ? strings.noMatches : strings.localEmpty,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(filtered ? strings.noMatchesBody : strings.localEmptyBody),
          ],
        ),
      ),
    );
  }
}
