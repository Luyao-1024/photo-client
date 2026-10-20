import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'local_library_controller.dart';
import 'local_photo_image.dart';
import 'strings.dart';

class LocalPhotoViewer extends ConsumerStatefulWidget {
  const LocalPhotoViewer({
    super.key,
    required this.photo,
    required this.initialIndex,
  });
  final LocalPhoto photo;
  final int initialIndex;
  @override
  ConsumerState<LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends ConsumerState<LocalPhotoViewer> {
  static const double _minScale = .5;
  static const double _maxScale = 8;
  late LocalPhoto _photo = widget.photo;
  final _transform = TransformationController();
  bool _navigating = false;
  bool _immersive = false;
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// Zoom about the viewport centre so keyboard and button zoom match the
  /// pointer gesture bounds enforced by [InteractiveViewer].
  void _applyZoom(double factor) {
    final current = _scale;
    final target = (current * factor).clamp(_minScale, _maxScale);
    final relative = target / current;
    if ((relative - 1).abs() < 1e-3 || _viewport.isEmpty) return;
    final focal = _transform.toScene(_viewport.center(Offset.zero));
    setState(() {
      _transform.value = _transform.value.clone()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..multiply(Matrix4.diagonal3Values(relative, relative, 1))
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    });
  }

  void _resetZoom() => setState(() => _transform.value = Matrix4.identity());

  Future<void> _move(int delta) async {
    if (_navigating) return;
    final library = ref.read(localLibraryProvider);
    final index = library.indexOf(_photo.id);
    if (index == null || index + delta < 0 || index + delta >= library.total) {
      return;
    }
    setState(() => _navigating = true);
    final photo = await ref
        .read(localLibraryProvider.notifier)
        .photoAt(index + delta);
    if (!mounted) return;
    setState(() {
      _navigating = false;
      if (photo != null) {
        _photo = photo;
        _transform.value = Matrix4.identity();
      }
    });
  }

  void _toggleImmersive() => setState(() => _immersive = !_immersive);

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final library = ref.watch(localLibraryProvider);
    final index = library.indexOf(_photo.id);
    final photo = index == null ? _photo : library.photoAt(index) ?? _photo;
    _photo = photo;
    final controller = ref.read(localLibraryProvider.notifier);
    final canPrevious = !_navigating && index != null && index > 0;
    final canNext = !_navigating && index != null && index + 1 < library.total;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.keyI): _toggleImmersive,
        const SingleActivator(LogicalKeyboardKey.equal): () => _applyZoom(1.25),
        const SingleActivator(LogicalKeyboardKey.add): () => _applyZoom(1.25),
        const SingleActivator(LogicalKeyboardKey.minus): () => _applyZoom(.8),
        const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('viewer'),
          backgroundColor: const Color(0xff10131a),
          appBar: _immersive
              ? null
              : AppBar(
                  backgroundColor: const Color(0xff171e29),
                  foregroundColor: Colors.white,
                  leading: IconButton(
                    key: const ValueKey('viewer-close'),
                    tooltip: strings.back,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  title: Text(
                    photo.name,
                    key: const ValueKey('viewer-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    IconButton(
                      key: const ValueKey('viewer-favorite'),
                      tooltip: photo.favorite
                          ? strings.unmarkFavorite
                          : strings.markFavorite,
                      isSelected: photo.favorite,
                      selectedIcon: const Icon(Icons.favorite),
                      icon: const Icon(Icons.favorite_border),
                      onPressed: library.favoritePending.contains(photo.id)
                          ? null
                          : () => controller.setFavorite(photo),
                    ),
                    IconButton(
                      key: const ValueKey('viewer-details'),
                      tooltip: strings.details,
                      icon: const Icon(Icons.info_outline),
                      onPressed: () => _details(context, photo),
                    ),
                    IconButton(
                      key: const ValueKey('viewer-immersive'),
                      tooltip: strings.immersive,
                      icon: const Icon(Icons.fullscreen),
                      onPressed: _toggleImmersive,
                    ),
                  ],
                ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (_immersive)
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    key: const ValueKey('viewer-immersive-exit'),
                    tooltip: strings.exitImmersive,
                    color: Colors.white,
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: _toggleImmersive,
                  ),
                ),
              Column(
                children: [
                  if (library.problem == LibraryProblem.favorite)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        strings.libraryError('favorite'),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  if (index == null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        strings.libraryUpdated,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _viewport = constraints.biggest;
                        final decodeWidth = math.min(
                          4096,
                          math.max(
                            256,
                            (constraints.maxWidth *
                                    MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                          ),
                        );
                        return InteractiveViewer(
                          key: ValueKey(
                            'viewer-image-${photo.id}-${photo.contentVersion}',
                          ),
                          transformationController: _transform,
                          minScale: _minScale,
                          maxScale: _maxScale,
                          child: SizedBox.expand(
                            child: Image(
                              image: ResizeImage.resizeIfNeeded(
                                decodeWidth,
                                null,
                                LocalPhotoImage(photo.path, photo),
                              ),
                              fit: BoxFit.contain,
                              semanticLabel: photo.name,
                              errorBuilder: (context, error, stack) => Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.broken_image_outlined,
                                      size: 48,
                                      color: Colors.white70,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      strings.imageUnavailable,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (!_immersive)
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 16,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              key: const ValueKey('viewer-previous'),
                              tooltip: strings.previous,
                              color: Colors.white,
                              disabledColor: Colors.white30,
                              onPressed: canPrevious ? () => _move(-1) : null,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Flexible(
                              child: Text(
                                index == null
                                    ? '—'
                                    : '${index + 1} / ${library.total}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('viewer-next'),
                              tooltip: strings.next,
                              color: Colors.white,
                              disabledColor: Colors.white30,
                              onPressed: canNext ? () => _move(1) : null,
                              icon: const Icon(Icons.chevron_right),
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              key: const ValueKey('viewer-zoom-out'),
                              tooltip: strings.zoomOut,
                              color: Colors.white,
                              onPressed: _scale > _minScale + 1e-3
                                  ? () => _applyZoom(.8)
                                  : null,
                              icon: const Icon(Icons.zoom_out),
                            ),
                            Text(
                              '${(_scale * 100).round()}%',
                              key: const ValueKey('viewer-zoom-level'),
                              style: const TextStyle(color: Colors.white),
                            ),
                            IconButton(
                              key: const ValueKey('viewer-zoom-in'),
                              tooltip: strings.zoomIn,
                              color: Colors.white,
                              onPressed: _scale < _maxScale - 1e-3
                                  ? () => _applyZoom(1.25)
                                  : null,
                              icon: const Icon(Icons.zoom_in),
                            ),
                            TextButton(
                              key: const ValueKey('viewer-zoom-reset'),
                              onPressed: (_scale - 1).abs() > 1e-3
                                  ? _resetZoom
                                  : null,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              child: Text(strings.zoomReset),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _details(BuildContext context, LocalPhoto photo) {
    final strings = AppStrings.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.details),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detail(strings.filePath, photo.path),
              _detail(strings.fileSize, '${photo.sizeBytes} B'),
              _detail(
                strings.modified,
                DateTime.fromMillisecondsSinceEpoch(photo.modifiedMs)
                    .toLocal()
                    .toString(),
              ),
              _detail(
                strings.dimensions,
                photo.width != null && photo.height != null
                    ? '${photo.width} × ${photo.height}'
                    : strings.unknown,
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(this.context).pop();
                  ref
                      .read(localLibraryProvider.notifier)
                      .setFolder(photo.parent);
                },
                icon: const Icon(Icons.folder_outlined),
                label: Text(
                  photo.parent,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
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

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(label), const SizedBox(height: 4), SelectableText(value)],
    ),
  );
}
