import 'thumbnail_image.dart';
import '../services/thumbnail_pipeline.dart';

import 'package:flutter/material.dart';

import '../services/local_library_gateway.dart';
import 'local_photo_image.dart';
import 'strings.dart';

class LocalMediaTile extends StatefulWidget {
  const LocalMediaTile({
    super.key,
    required this.photo,
    required this.gateway,
    required this.onOpen,
  });
  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  final VoidCallback onOpen;

  @override
  State<LocalMediaTile> createState() => _LocalMediaTileState();
}

class _LocalMediaTileState extends State<LocalMediaTile> {
  /// One in-flight request per bounded cache class, reused across rebuilds.
  final Map<int, ThumbnailHandle> _requests = {};
  String? _identity;
  final _automaticRepairs = <int>{};

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

  @override
  void dispose() {
    for (final request in _requests.values) {
      request.release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ThumbnailPool.forGateway(widget.gateway).epoch,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Semantics(
      button: true,
      label: widget.photo.name,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final pixels =
                                constraints.maxWidth *
                                MediaQuery.devicePixelRatioOf(context);
                            final sizeClass = thumbnailSizeClassForCover(
                              pixels,
                              widget.photo,
                            );
                            final target = thumbnailDecodeWidth(pixels);
                            return FutureBuilder<String>(
                              key: ValueKey(
                                'thumbnail-$_photoIdentity-$sizeClass',
                              ),
                              future: _thumbnail(sizeClass).future,
                              initialData: _thumbnail(sizeClass).path,
                              builder: (context, result) {
                                if (result.hasError) {
                                  return _failure(strings, sizeClass);
                                }
                                if (!result.hasData) {
                                  return FutureBuilder<String?>(
                                    future: _thumbnail(sizeClass).placeholder,
                                    builder: (context, preview) =>
                                        preview.data == null
                                        ? const Center(
                                            child: Icon(Icons.photo_outlined),
                                          )
                                        : Image(
                                            image: LocalPhotoImage(
                                              preview.data!,
                                              widget.photo,
                                            ),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                const Center(
                                                  child: Icon(
                                                    Icons.photo_outlined,
                                                  ),
                                                ),
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
                      ),
                      if (widget.photo.favorite)
                        const Positioned(
                          top: 8,
                          right: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xa6000000),
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.favorite,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  widget.photo.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
