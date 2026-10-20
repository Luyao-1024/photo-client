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
  final Map<int, Future<String>> _requests = {};
  String? _identity;

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

  @override
  Widget build(BuildContext context) {
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
                            final sizeClass = thumbnailSizeClassFor(pixels);
                            final target = pixels.ceil().clamp(64, 1024);
                            return FutureBuilder<String>(
                              future: _thumbnail(sizeClass),
                              builder: (context, result) {
                                if (result.hasError) {
                                  return _failure(strings, sizeClass);
                                }
                                if (!result.hasData) {
                                  return const Center(
                                    child: Icon(Icons.photo_outlined),
                                  );
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
