import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import '../services/thumbnail_pipeline.dart';
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'glass_theme.dart';
import 'local_album_actions.dart';
import 'library_activity_progress.dart';
import 'local_library_controller.dart';
import 'mobile_pull_refresh.dart';
import 'runtime_controller.dart';
import 'strings.dart';

/// The fixed collections every phone library exposes above its folders.
enum MobileSmartAlbum { favorites, images, videos, motion, trash }

final _smartAlbumPageProvider = FutureProvider.autoDispose
    .family<LocalPhotoPage?, MobileSmartAlbum>((ref, album) async {
      final identity = ref.watch(
        localLibraryProvider.select(
          (state) => (state.info?.libraryId, state.revision),
        ),
      );
      if (identity.$1 == null) return null;
      final gateway = ref.watch(coreGatewayProvider) as LocalLibraryGateway;
      return switch (album) {
        MobileSmartAlbum.favorites => gateway.listPhotos(
          favoritesOnly: true,
          limit: 1,
        ),
        MobileSmartAlbum.images => gateway.listPhotos(
          mediaKind: 'image',
          limit: 1,
        ),
        MobileSmartAlbum.videos => gateway.listPhotos(
          mediaKind: 'video',
          limit: 1,
        ),
        MobileSmartAlbum.motion => gateway.listPhotos(
          mediaKind: 'motion',
          limit: 1,
        ),
        MobileSmartAlbum.trash => gateway.listPhotos(trashed: true, limit: 1),
      };
    });

/// Touch-first collections page: fixed smart albums first, then the physical
/// folders with their covers, exactly one tap from the photo grid.
class MobileAlbumsPage extends ConsumerStatefulWidget {
  const MobileAlbumsPage({
    super.key,
    required this.onOpenSmartAlbum,
    required this.onOpenAlbum,
    required this.onSearch,
    required this.onOpenSettings,
    required this.onAdd,
  });

  final ValueChanged<MobileSmartAlbum> onOpenSmartAlbum;
  final ValueChanged<LocalAlbum> onOpenAlbum;
  final VoidCallback onSearch;
  final VoidCallback onOpenSettings;
  final VoidCallback onAdd;

  @override
  ConsumerState<MobileAlbumsPage> createState() => _MobileAlbumsPageState();
}

class _MobileAlbumsPageState extends ConsumerState<MobileAlbumsPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final library = ref.watch(localLibraryProvider);
    final albums = library.albums;
    final textScaler = MediaQuery.textScalerOf(context);
    final smartAlbums = <(MobileSmartAlbum, String, IconData)>[
      (
        MobileSmartAlbum.favorites,
        strings.albumFavorites,
        Icons.favorite_border,
      ),
      (MobileSmartAlbum.images, strings.images, Icons.photo_outlined),
      (MobileSmartAlbum.videos, strings.videos, Icons.videocam_outlined),
      (
        MobileSmartAlbum.motion,
        strings.motionPhotos,
        Icons.motion_photos_on_outlined,
      ),
      (MobileSmartAlbum.trash, strings.trash, Icons.delete_outline),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = math.max(0.0, constraints.maxWidth - 32);
        // Phone albums keep three columns; larger text gets more vertical
        // space below the cover instead of reducing the number of columns.
        const columns = 3;
        final side = (availableWidth - (columns - 1) * 10) / columns;
        // Reserve both title lines and the count at the actual text scale.
        final cardExtent =
            side +
            7 +
            textScaler.scale(14) * 2.5 +
            textScaler.scale(12) * 1.4 +
            4;
        return Column(
          key: const ValueKey('mobile-albums-page'),
          children: [
            _header(context, strings, albums.length),
            Expanded(
              child: MobilePullRefresh(
                key: const ValueKey('mobile-albums-pull'),
                child: CustomScrollView(
                  key: const ValueKey('mobile-albums-scroll'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 10,
                          mainAxisExtent: cardExtent,
                        ),
                        itemCount: smartAlbums.length,
                        itemBuilder: (context, index) {
                          final (kind, label, icon) = smartAlbums[index];
                          final page = ref
                              .watch(_smartAlbumPageProvider(kind))
                              .asData
                              ?.value;
                          return _AlbumCard(
                            key: ValueKey('mobile-smart-album-${kind.name}'),
                            label: label,
                            count: page?.total,
                            coverMediaId: page?.items.firstOrNull?.id,
                            revision: library.revision,
                            fallbackIcon: icon,
                            onTap: () => widget.onOpenSmartAlbum(kind),
                          );
                        },
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        label: strings.albums,
                        onAdd: _createAlbum,
                        onReorder: albums.length > 1 ? _reorderAlbums : null,
                        addKey: const ValueKey('mobile-albums-add'),
                        reorderKey: const ValueKey('mobile-albums-reorder'),
                      ),
                    ),
                    if (albums.isEmpty)
                      SliverToBoxAdapter(
                        child: _EmptyAlbums(onAdd: widget.onAdd),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 18,
                                crossAxisSpacing: 10,
                                mainAxisExtent: cardExtent,
                              ),
                          itemCount: albums.length,
                          itemBuilder: (context, index) {
                            final album = albums[index];
                            return _AlbumCard(
                              key: ValueKey('mobile-album-${album.path}'),
                              label: album.name,
                              count: album.count,
                              coverMediaId: album.coverMediaId,
                              revision: library.revision,
                              fallbackIcon: Icons.folder_outlined,
                              onTap: () => widget.onOpenAlbum(album),
                              onLongPress: () =>
                                  unawaited(_showAlbumMenu(album)),
                            );
                          },
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 132)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, AppStrings strings, int albumCount) {
    return Padding(
      key: const ValueKey('mobile-albums-header'),
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        12,
        6,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.albums,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 2),
                LibraryActivityProgress(
                  compact: true,
                  textAlign: TextAlign.start,
                  idle: Text(
                    strings.pick('$albumCount 个相册', '$albumCount albums'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _CircleAction(
            key: const ValueKey('mobile-albums-search'),
            tooltip: strings.search,
            icon: Icons.search,
            onPressed: widget.onSearch,
          ),
          const SizedBox(width: 8),
          _AlbumsOptionsButton(
            tooltip: strings.pick('更多选项', 'More options'),
            onOpenSettings: widget.onOpenSettings,
          ),
        ],
      ),
    );
  }

  Future<void> _createAlbum() async {
    if (_busy) return;
    final folder = await createLocalAlbum(context, ref);
    if (folder == null || !mounted) return;
    final controller = ref.read(localLibraryProvider.notifier);
    await controller.refresh(force: true);
    final album = ref
        .read(localLibraryProvider)
        .albums
        .where((entry) => entry.path == folder)
        .firstOrNull;
    if (album != null && mounted) widget.onOpenAlbum(album);
  }

  Future<void> _showAlbumMenu(LocalAlbum album) async {
    final strings = AppStrings.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _MobileSheet(
        title: album.name,
        children: [
          ListTile(
            key: const ValueKey('mobile-album-open'),
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(strings.pick('打开相册', 'Open album')),
            onTap: () => Navigator.of(context).pop('open'),
          ),
          ListTile(
            key: const ValueKey('mobile-album-rename'),
            leading: const Icon(Icons.edit_outlined),
            title: Text(strings.rename),
            onTap: () => Navigator.of(context).pop('rename'),
          ),
          ListTile(
            key: const ValueKey('mobile-album-remove'),
            leading: const Icon(Icons.remove_circle_outline),
            title: Text(strings.pick('从图库移除相册', 'Remove album from library')),
            onTap: () => Navigator.of(context).pop('remove'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'open') {
      widget.onOpenAlbum(album);
    } else if (action == 'rename') {
      await _renameAlbum(album, strings);
    } else if (action == 'remove') {
      await _removeAlbum(album, strings);
    }
  }

  Future<void> _renameAlbum(LocalAlbum album, AppStrings strings) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _RenameAlbumDialog(initialName: album.name, strings: strings),
    );
    if (!mounted || name == null || name.isEmpty || name == album.name) {
      return;
    }
    await _run(() async {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({
        'op': 'renameAlbum',
        'folder': album.path,
        'name': name,
      });
      await controller.refresh(force: true);
    }, strings);
  }

  Future<void> _removeAlbum(LocalAlbum album, AppStrings strings) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(strings.pick('移除相册？', 'Remove album?')),
        content: Text(
          strings.pick(
            '从图库移除此文件夹及其子文件夹，原始文件会保留。',
            'Remove this folder and its subfolders from the library. Original files are kept.',
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const ValueKey('mobile-album-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.pick('移除', 'Remove')),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    await _run(() async {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({
        'op': 'removeAlbum',
        'folder': album.path,
      });
      await controller.showDestination();
      await controller.refresh(force: true);
    }, strings);
  }

  Future<void> _reorderAlbums() async {
    final albums = List<LocalAlbum>.of(ref.read(localLibraryProvider).albums);
    final ordered = await showModalBottomSheet<List<LocalAlbum>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _AlbumOrderSheet(albums: albums),
    );
    if (!mounted || ordered == null) return;
    await _run(() async {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({
        'op': 'reorderAlbums',
        'ids': [for (final album in ordered) album.path],
      });
      await controller.refresh(force: true);
    }, AppStrings.of(context));
  }

  Future<void> _run(Future<void> Function() action, AppStrings strings) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      debugPrint('ALBUM_ACTION_FAILED: $error');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(strings.actionFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.onAdd,
    required this.onReorder,
    required this.addKey,
    required this.reorderKey,
  });

  final String label;
  final VoidCallback onAdd;
  final VoidCallback? onReorder;
  final Key addKey, reorderKey;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (onReorder != null)
            TextButton(
              key: reorderKey,
              onPressed: onReorder,
              child: Text(strings.pick('调整', 'Reorder')),
            ),
          IconButton(
            key: addKey,
            tooltip: strings.pick('新建相册', 'New album'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    super.key,
    required this.label,
    required this.count,
    required this.coverMediaId,
    required this.revision,
    required this.fallbackIcon,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final int? count;
  final String? coverMediaId;
  final int revision;
  final IconData fallbackIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final localizations = MaterialLocalizations.of(context);
    final countLabel = count == null ? '' : localizations.formatDecimal(count!);
    return Semantics(
      button: true,
      label: count == null
          ? label
          : strings.pick('$label，$count 项', '$label, $count items'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _AlbumCover(
                  mediaId: coverMediaId,
                  revision: revision,
                  fallbackIcon: fallbackIcon,
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: 14,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (countLabel.isNotEmpty)
              Text(
                countLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AlbumCover extends ConsumerStatefulWidget {
  const _AlbumCover({
    required this.mediaId,
    required this.revision,
    required this.fallbackIcon,
  });

  final String? mediaId;
  final int revision;
  final IconData fallbackIcon;

  @override
  ConsumerState<_AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends ConsumerState<_AlbumCover> {
  MediaThumbnailHandle? _cover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  void _load() {
    _cover?.release();
    final gateway = ref.read(coreGatewayProvider);
    final id = widget.mediaId;
    _cover = id != null && gateway is LocalLibraryGateway
        ? MediaThumbnailHandle(gateway as LocalLibraryGateway, id, 512)
        : null;
  }

  @override
  void dispose() {
    _cover?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          widget.fallbackIcon,
          size: 32,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final handle = _cover;
    if (handle == null) return placeholder;
    return FutureBuilder<String>(
      key: ValueKey((widget.mediaId, widget.revision)),
      future: handle.future,
      initialData: handle.path,
      builder: (context, snapshot) => snapshot.hasData
          ? Image(
              image: FileImage(File(snapshot.data!)),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => placeholder,
            )
          : placeholder,
    );
  }
}

class _EmptyAlbums extends StatelessWidget {
  const _EmptyAlbums({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: GlassTheme.of(context).inset,
        borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(
                Icons.photo_album_outlined,
                size: 36,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(
                strings.noAlbums,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('mobile-albums-empty-add'),
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(strings.pick('添加照片或目录', 'Add photos or a folder')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumOrderSheet extends StatefulWidget {
  const _AlbumOrderSheet({required this.albums});
  final List<LocalAlbum> albums;

  @override
  State<_AlbumOrderSheet> createState() => _AlbumOrderSheetState();
}

class _AlbumOrderSheetState extends State<_AlbumOrderSheet> {
  late final List<LocalAlbum> _albums = List.of(widget.albums);

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final height = MediaQuery.sizeOf(context).height * .66;
    return _MobileSheet(
      title: strings.pick('调整相册顺序', 'Reorder albums'),
      trailing: TextButton(
        key: const ValueKey('mobile-album-order-done'),
        onPressed: () => Navigator.of(context).pop(_albums),
        child: Text(strings.save),
      ),
      children: [
        SizedBox(
          height: height,
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _albums.length,
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                final album = _albums.removeAt(oldIndex);
                _albums.insert(newIndex, album);
              });
            },
            itemBuilder: (context, index) {
              final album = _albums[index];
              return ListTile(
                key: ValueKey('mobile-album-order-${album.path}'),
                leading: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle),
                ),
                title: Text(album.name, maxLines: 1),
                subtitle: Text('${album.count}'),
                trailing: Text('${index + 1}'),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MobileSheet extends StatelessWidget {
  const _MobileSheet({this.title, this.trailing, required this.children});
  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: GlassSurface(
        role: GlassRole.overlay,
        radius: GlassTheme.dialogRadius,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title!,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameAlbumDialog extends StatefulWidget {
  const _RenameAlbumDialog({required this.initialName, required this.strings});
  final String initialName;
  final AppStrings strings;

  @override
  State<_RenameAlbumDialog> createState() => _RenameAlbumDialogState();
}

class _RenameAlbumDialogState extends State<_RenameAlbumDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return GlassAlertDialog(
      title: Text(strings.pick('重命名相册', 'Rename album')),
      content: TextField(
        key: const ValueKey('mobile-album-rename-field'),
        controller: _text,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('mobile-album-rename-confirm'),
          onPressed: () => Navigator.of(context).pop(_text.text.trim()),
          child: Text(strings.rename),
        ),
      ],
    );
  }
}

class _AlbumsOptionsButton extends StatelessWidget {
  const _AlbumsOptionsButton({
    required this.tooltip,
    required this.onOpenSettings,
  });

  final String tooltip;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return SizedBox.square(
      dimension: 46,
      child: GlassSurface(
        role: GlassRole.raised,
        live: true,
        radius: 23,
        child: PopupMenuButton<int>(
          key: const ValueKey('mobile-albums-options'),
          tooltip: tooltip,
          icon: const Icon(Icons.more_vert, size: 22),
          style: IconButton.styleFrom(
            fixedSize: const Size(46, 46),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          menuPadding: EdgeInsets.zero,
          clipBehavior: Clip.none,
          position: PopupMenuPosition.under,
          padding: EdgeInsets.zero,
          offset: const Offset(0, 4),
          constraints: const BoxConstraints(minWidth: 168, maxWidth: 280),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
          ),
          onSelected: (_) => onOpenSettings(),
          itemBuilder: (context) => [
            GlassMenuEntry<int>(
              padding: EdgeInsets.zero,
              items: [
                PopupMenuItem(
                  key: const ValueKey('mobile-albums-menu-settings'),
                  value: 0,
                  height: 48,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.settings_outlined),
                    title: Text(strings.settings),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 46,
    child: GlassSurface(
      role: GlassRole.raised,
      live: true,
      radius: 23,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 22),
        style: IconButton.styleFrom(
          fixedSize: const Size(46, 46),
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
      ),
    ),
  );
}
