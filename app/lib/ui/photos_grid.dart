import 'thumbnail_image.dart';
import '../services/thumbnail_pipeline.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_library_gateway.dart';
import 'glass_dialog.dart';
import 'glass_theme.dart';
import 'strings.dart';

/// Year/Month/Day grouping of the Photos grid. See
/// photoViewer/docs/modules/ui-design.md "Media Grids And Tiles".
enum GroupMode { year, month, day }

/// Phone overview modes progressively fit more photos on the same screen.
int mobileGridColumns(GroupMode mode, int dayColumns) {
  final day = dayColumns.clamp(3, 8);
  return switch (mode) {
    GroupMode.day => day,
    GroupMode.month => (day * 1.6).ceil(),
    GroupMode.year => (day * 2.6).ceil(),
  };
}

/// Largest tile edge per desktop mode; Year is the densest layout.
double gridMaxCrossAxisExtent(GroupMode mode) => switch (mode) {
  GroupMode.year => 90,
  GroupMode.month => 180,
  GroupMode.day => 270,
};

double gridSpacing(GroupMode mode) => switch (mode) {
  GroupMode.year => 8,
  GroupMode.month => 8,
  GroupMode.day => 8,
};

/// One calendar bucket of the loaded window: a header plus its tiles.
class PhotoSection {
  PhotoSection({
    required this.bucket,
    required this.date,
    this.label,
    this.startIndex,
    this.totalCount,
  });
  final int? startIndex;
  int? totalCount;
  final int bucket;
  final DateTime date;

  /// Overrides the date-derived header title when set (search media sections).
  final String? label;
  final List<SectionItem> items = [];
}

class SectionItem {
  const SectionItem(this.photo, this.index);
  final LocalPhoto photo;

  /// Rank in the controller's flat paged window; feeds the viewer.
  final int index;
}

int bucketOf(DateTime date, GroupMode mode) => switch (mode) {
  GroupMode.year => date.year,
  GroupMode.month => date.year * 12 + date.month,
  GroupMode.day =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay,
};

/// Today/Yesterday for the last two local days, a locale date otherwise;
/// Year/Month modes use the coarser locale label.
String sectionLabel(
  BuildContext context,
  PhotoSection section,
  GroupMode mode,
) {
  final strings = AppStrings.of(context);
  final localizations = MaterialLocalizations.of(context);
  switch (mode) {
    case GroupMode.year:
      return localizations.formatYear(section.date);
    case GroupMode.month:
      return localizations.formatMonthYear(section.date);
    case GroupMode.day:
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(
        section.date.year,
        section.date.month,
        section.date.day,
      );
      if (day == today) return strings.today;
      if (day == today.subtract(const Duration(days: 1))) {
        return strings.yesterday;
      }
      return localizations.formatFullDate(day);
  }
}

/// A square thumbnail tile: hover veil, selection veil + checkmark, accent
/// focus ring, tap-to-open, right-click/long-press context menu, Space to
/// select. No filename caption — the grid is content-first.
class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.photo,
    required this.gateway,
    required this.selected,
    required this.multiSelect,
    required this.onOpen,
    required this.onSelectToggle,
    required this.onEnterSelection,
    required this.onToggleFavorite,
    required this.onShowDetails,
    this.cloudBound = false,
    this.compact = false,
    this.onUploadToCloud,
    this.onRename,
    this.onMoveToTrash,
    this.onCopyToAlbum,
    this.onMoveToAlbum,
    this.onExport,
    this.onSetCover,
    this.onRestore,
    this.onPurge,
    this.radius = GlassTheme.photoRadius,
  });

  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  final bool selected;

  /// True while grid-wide multi-select is active.
  final bool multiSelect;
  final VoidCallback onOpen;
  final VoidCallback onSelectToggle;
  final VoidCallback onEnterSelection;
  final VoidCallback onToggleFavorite;
  final VoidCallback onShowDetails;
  final bool cloudBound;

  /// Dense overviews keep badges from covering the thumbnail or clipping.
  final bool compact;
  final VoidCallback? onUploadToCloud;
  final VoidCallback? onRename;
  final VoidCallback? onMoveToTrash;
  final VoidCallback? onCopyToAlbum;
  final VoidCallback? onMoveToAlbum;
  final VoidCallback? onExport, onSetCover;
  final VoidCallback? onRestore, onPurge;

  /// Mobile grids run edge to edge with a much softer corner than panels.
  final double radius;

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);

  /// One in-flight request per bounded cache class, reused across rebuilds.
  final Map<int, ThumbnailHandle> _requests = {};
  String? _identity;
  final _automaticRepairs = <int>{};
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    for (final request in _requests.values) {
      request.release();
    }
    _focusNode.dispose();
    super.dispose();
  }

  String get _photoIdentity =>
      '${identityHashCode(widget.gateway)}:${widget.photo.id}:${widget.photo.contentVersion}:${ThumbnailPool.forGateway(widget.gateway).epoch.value}';

  ThumbnailHandle _thumbnail(int sizeClass) {
    final identity = _photoIdentity;
    if (_identity != identity) {
      _identity = identity;
      for (final request in _requests.values) {
        request.release();
      }
      _requests.clear();
      _automaticRepairs.clear();
    }
    return _requests.putIfAbsent(
      sizeClass,
      () =>
          ThumbnailPool.forGateway(widget.gateway)
              .acquire(widget.photo, sizeClass),
    );
  }

  Future<void> _retry(int sizeClass) async {
    final request = _requests.remove(sizeClass);
    if (request != null) {
      try {
        await request.invalidate();
      } catch (_) {
        /* Native errors remain retryable. */
      }
      request.release();
    }
    if (mounted) setState(() {});
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.delete &&
        !widget.multiSelect) {
      final action = widget.onPurge ?? widget.onMoveToTrash;
      if (action != null) {
        action();
        return KeyEventResult.handled;
      }
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.space) {
      if (widget.multiSelect) {
        widget.onSelectToggle();
      } else {
        widget.onEnterSelection();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      if (widget.multiSelect) {
        widget.onSelectToggle();
      } else {
        widget.onOpen();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openMenu(Offset globalPosition) async {
    _focusNode.requestFocus();
    final strings = AppStrings.of(context);
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox || !overlay.hasSize) return;
    final origin = Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1);
    final action = await showGlassMenu<String>(
      context: context,
      position: RelativeRect.fromRect(origin, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<String>(
          key: const ValueKey('tile-menu-select'),
          value: 'select',
          child: Text(
            widget.selected
                ? strings.pick('取消选择', 'Deselect')
                : strings.pick('选择', 'Select'),
          ),
        ),
        if (widget.photo.state != 'trashed')
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-favorite'),
            value: 'favorite',
            child: Text(
              widget.photo.favorite
                  ? strings.unmarkFavorite
                  : strings.markFavorite,
            ),
          ),
        if (widget.onUploadToCloud != null)
          PopupMenuItem<String>(
            key: const ValueKey('photo-upload-cloud'),
            value: 'upload-cloud',
            child: Text(strings.cloudUpload),
          ),
        PopupMenuItem<String>(
          key: const ValueKey('tile-menu-details'),
          value: 'details',
          child: Text(strings.details),
        ),
        if (widget.onRestore != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-restore'),
            value: 'restore',
            child: Text(strings.restore),
          ),
        if (widget.onPurge != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-purge'),
            value: 'purge',
            child: Text(strings.deletePermanently),
          ),
        if (widget.onRename != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-rename'),
            value: 'rename',
            child: Text(strings.rename),
          ),
        if (widget.onCopyToAlbum != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-copy-album'),
            value: 'copy-album',
            child: Text(strings.copyToAlbum),
          ),
        if (widget.onMoveToAlbum != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-move-album'),
            value: 'move-album',
            child: Text(strings.moveToAlbum),
          ),
        if (widget.onExport != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-export'),
            value: 'export',
            child: Text(strings.pick('导出副本', 'Export copy')),
          ),
        if (widget.onSetCover != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-cover'),
            value: 'cover',
            child: Text(strings.pick('设为相册封面', 'Set as album cover')),
          ),
        if (widget.onMoveToTrash != null)
          PopupMenuItem<String>(
            key: const ValueKey('tile-menu-trash'),
            value: 'trash',
            child: Text(strings.moveToTrash),
          ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'select':
        if (widget.multiSelect) {
          widget.onSelectToggle();
        } else {
          widget.onEnterSelection();
        }
      case 'favorite':
        widget.onToggleFavorite();
      case 'upload-cloud':
        widget.onUploadToCloud?.call();
      case 'details':
        widget.onShowDetails();
      case 'rename':
        widget.onRename?.call();
      case 'copy-album':
        widget.onCopyToAlbum?.call();
      case 'move-album':
        widget.onMoveToAlbum?.call();
      case 'restore':
        widget.onRestore?.call();
      case 'purge':
        widget.onPurge?.call();
      case 'export':
        widget.onExport?.call();
      case 'cover':
        widget.onSetCover?.call();
      case 'trash':
        widget.onMoveToTrash?.call();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ThumbnailPool.forGateway(widget.gateway).epoch,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final veil = widget.selected
        ? .36
        : _hovered
        ? .18
        : 0.0;
    final checkOpacity = widget.selected
        ? 1.0
        : widget.multiSelect
        ? .32
        : 0.0;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.photo.name,
      child: FocusableActionDetector(
        focusNode: _focusNode,
        onShowHoverHighlight: (value) {
          if (mounted) setState(() => _hovered = value);
        },
        onShowFocusHighlight: (value) {
          if (mounted) setState(() => _focused = value);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focusNode.requestFocus();
            if (widget.multiSelect) {
              widget.onSelectToggle();
            } else {
              widget.onOpen();
            }
          },
          onSecondaryTapUp: (details) => _openMenu(details.globalPosition),
          onLongPressStart: (details) => _openMenu(details.globalPosition),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _thumbnailLayer(strings),
                AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  color: Colors.black.withValues(alpha: veil),
                ),
                if (widget.photo.mediaKind == 'video' ||
                    widget.photo.motionOffset != null)
                  Positioned(
                    left: widget.compact ? 2 : 6,
                    bottom: widget.compact ? 2 : 6,
                    child: Semantics(
                      label: widget.photo.mediaKind == 'video'
                          ? strings.videos
                          : strings.pick('动态照片', 'Motion photo'),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: widget.compact ? 3 : 5,
                            vertical: widget.compact ? 2 : 3,
                          ),
                          child:
                              widget.compact || widget.photo.durationMs == null
                              ? Icon(
                                  Icons.play_arrow_rounded,
                                  size: widget.compact ? 12 : 18,
                                  color: Colors.white,
                                )
                              : Text(
                                  '${(widget.photo.durationMs! ~/ 60000).toString().padLeft(2, '0')}:${((widget.photo.durationMs! ~/ 1000) % 60).toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                if (widget.cloudBound && !widget.compact)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Semantics(
                      label: strings.pick('已同步到云端', 'Synced to cloud'),
                      child: DecoratedBox(
                        key: ValueKey('cloud-badge-${widget.photo.id}'),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .55),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.cloud_outlined,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.photo.favorite && !widget.compact)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0x59000000),
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.favorite,
                          size: 12,
                          color: Colors.white.withValues(alpha: .9),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 120),
                      opacity: checkOpacity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .35),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.check,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_focused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.primary, width: 3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnailLayer(AppStrings strings) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final pixels =
            constraints.maxWidth * MediaQuery.devicePixelRatioOf(context);
        final sizeClass = thumbnailSizeClassForCover(pixels, widget.photo);
        final target = thumbnailDecodeWidth(pixels);
        return FutureBuilder<String>(
          key: ValueKey('thumbnail-$_photoIdentity-$sizeClass'),
          future: _thumbnail(sizeClass).future,
          initialData: _thumbnail(sizeClass).path,
          builder: (context, result) {
            if (result.hasError) return _failure(strings, sizeClass);
            if (!result.hasData) {
              return FutureBuilder<String?>(
                future: _thumbnail(sizeClass).placeholder,
                builder: (context, preview) => preview.data == null
                    ? const Center(child: Icon(Icons.photo_outlined))
                    : Image(
                        image: ThumbnailImage.file(
                          preview.data!,
                          widget.photo,
                          use: ThumbnailUse.embedded,
                        ),
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) =>
                            const Center(child: Icon(Icons.photo_outlined)),
                      ),
              );
            }
            return Image(
              image: ThumbnailImage.file(
                result.data!,
                widget.photo,
                width: target,
              ),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stack) =>
                  _decodeFailure(strings, sizeClass),
            );
          },
        );
      },
    ),
  );

  Widget _decodeFailure(AppStrings strings, int sizeClass) {
    if (_automaticRepairs.add(sizeClass)) {
      final identity = _photoIdentity;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identity == _photoIdentity) _retry(sizeClass);
      });
      return const Center(child: Icon(Icons.photo_outlined));
    }
    return _failure(strings, sizeClass);
  }

  Widget _failure(AppStrings strings, int sizeClass) => Center(
    child: IconButton(
      tooltip: strings.retryImage,
      onPressed: () => _retry(sizeClass),
      icon: Icon(
        Icons.broken_image_outlined,
        semanticLabel: strings.thumbnailUnavailable,
      ),
    ),
  );
}

/// Grid-side details dialog mirroring the viewer's metadata rows.
Future<void> showPhotoDetails(BuildContext context, LocalPhoto photo) {
  final strings = AppStrings.of(context);
  final localizations = MaterialLocalizations.of(context);
  final modified = DateTime.fromMillisecondsSinceEpoch(photo.modifiedMs);
  return showDialog<void>(
    context: context,
    builder: (context) => GlassAlertDialog(
      title: Text(photo.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailRow(strings.filePath, photo.path),
          _detailRow(strings.fileSize, '${photo.sizeBytes} B'),
          _detailRow(
            strings.modified,
            '${localizations.formatFullDate(modified)} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(modified))}',
          ),
          _detailRow(
            strings.dimensions,
            photo.width != null && photo.height != null
                ? '${photo.width} × ${photo.height}'
                : strings.unknown,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    ),
  );
}

Widget _detailRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: 96, child: Text(label)),
      Expanded(child: SelectableText(value)),
    ],
  ),
);
