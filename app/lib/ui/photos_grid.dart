import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_library_gateway.dart';
import 'local_photo_image.dart';
import 'strings.dart';

/// Year/Month/Day grouping of the Photos grid. See
/// photoViewer/docs/modules/ui-design.md "Media Grids And Tiles".
enum GroupMode { year, month, day }

/// Largest tile edge per mode; Day is the densest layout.
double gridMaxCrossAxisExtent(GroupMode mode) => switch (mode) {
  GroupMode.year => 300,
  GroupMode.month => 220,
  GroupMode.day => 150,
};

double gridSpacing(GroupMode mode) => switch (mode) {
  GroupMode.year => 8,
  GroupMode.month => 6,
  GroupMode.day => 4,
};

/// One calendar bucket of the loaded window: a header plus its tiles.
class PhotoSection {
  PhotoSection({required this.bucket, required this.date});
  final int bucket;
  final DateTime date;
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
String sectionLabel(BuildContext context, PhotoSection section, GroupMode mode) {
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

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);
  /// One in-flight request per bounded cache class, reused across rebuilds.
  final Map<int, Future<String>> _requests = {};
  String? _identity;
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  String get _photoIdentity =>
      '${widget.photo.id}:${widget.photo.contentVersion}';

  Future<String> _thumbnail(int sizeClass) {
    final identity = _photoIdentity;
    if (_identity != identity) {
      _identity = identity;
      _requests.clear();
    }
    return _requests.putIfAbsent(
      sizeClass,
      () => widget.gateway.thumbnail(widget.photo.id, sizeClass: sizeClass),
    );
  }

  void _retry(int sizeClass) {
    if (!mounted) return;
    setState(() => _requests.remove(sizeClass));
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.space) {
      if (widget.multiSelect) {
        widget.onSelectToggle();
      } else {
        widget.onEnterSelection();
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
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(origin, Offset.zero & overlay.size),
      items: [
        PopupMenuItem<String>(
          value: 'select',
          child: Text(
            widget.selected
                ? strings.pick('取消选择', 'Deselect')
                : strings.pick('选择', 'Select'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'favorite',
          child: Text(
            widget.photo.favorite
                ? strings.unmarkFavorite
                : strings.markFavorite,
          ),
        ),
        PopupMenuItem<String>(
          value: 'details',
          child: Text(strings.details),
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
      case 'details':
        widget.onShowDetails();
    }
  }

  @override
  Widget build(BuildContext context) {
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
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _thumbnailLayer(strings),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  color: Colors.black.withValues(alpha: veil),
                ),
                if (widget.photo.favorite)
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
                      duration: const Duration(milliseconds: 120),
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
        final pixels = constraints.maxWidth * MediaQuery.devicePixelRatioOf(context);
        final sizeClass = thumbnailSizeClassFor(pixels);
        final target = pixels.ceil().clamp(64, 1024);
        return FutureBuilder<String>(
          future: _thumbnail(sizeClass),
          builder: (context, result) {
            if (result.hasError) return _failure(strings, sizeClass);
            if (!result.hasData) {
              return const Center(child: Icon(Icons.photo_outlined));
            }
            return Image(
              image: ResizeImage.resizeIfNeeded(
                target,
                null,
                LocalPhotoImage(result.data!, widget.photo),
              ),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stack) =>
                  _failure(strings, sizeClass),
            );
          },
        );
      },
    ),
  );

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
    builder: (context) => AlertDialog(
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
