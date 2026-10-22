import 'thumbnail_image.dart';

import 'package:flutter/material.dart';

import '../services/local_library_gateway.dart';
import '../services/thumbnail_pipeline.dart';

/// Keep a paintable thumbnail until the replacement has an actual decoded
/// frame. Resolving a filename or opening a codec is not a ready-to-paint signal.
class ProgressiveImage extends StatelessWidget {
  const ProgressiveImage({
    super.key,
    required this.image,
    required this.placeholder,
    this.semanticLabel,
    this.errorBuilder,
  });
  final ImageProvider image;
  final Widget placeholder;
  final String? semanticLabel;
  final ImageErrorWidgetBuilder? errorBuilder;
  @override
  Widget build(BuildContext context) => Image(
    key: const ValueKey('progressive-original-image'),
    image: image,
    fit: BoxFit.contain,
    semanticLabel: semanticLabel,
    frameBuilder: (context, child, frame, synchronous) {
      if (synchronous || frame != null) {
        return child;
      }
      return placeholder;
    },
    errorBuilder: (context, error, stack) => Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        if (errorBuilder != null) errorBuilder!(context, error, stack),
      ],
    ),
  );
}

class ViewerThumbnail extends StatefulWidget {
  const ViewerThumbnail({
    super.key,
    required this.photo,
    required this.gateway,
  });
  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  @override
  State<ViewerThumbnail> createState() => _ViewerThumbnailState();
}

class _ViewerThumbnailState extends State<ViewerThumbnail> {
  ThumbnailHandle? _request;
  String? _identity;
  bool _repaired = false;
  @override
  void dispose() {
    _request?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ThumbnailPool.forGateway(widget.gateway).epoch,
    builder: (context, _) => _build(context),
  );
  Widget _build(BuildContext context) {
    final photo = widget.photo;
    final identity =
        '${identityHashCode(widget.gateway)}:${photo.id}:${photo.contentVersion}:${ThumbnailPool.forGateway(widget.gateway).epoch.value}';
    if (_identity != identity) {
      _identity = identity;
      _repaired = false;
      _request?.release();
      final pool = ThumbnailPool.forGateway(widget.gateway);
      _request = pool.acquire(photo, pool.bestAvailableSize(photo) ?? 512);
    }
    return FutureBuilder<String>(
      future: _request!.future,
      initialData: _request!.path,
      builder: (context, snapshot) => snapshot.hasData
          ? Image(
              key: const ValueKey('viewer-thumbnail-placeholder'),
              image: ThumbnailImage.file(snapshot.data!, photo),
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stack) {
                if (!_repaired) {
                  _repaired = true;
                  final current = _request!;
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted || _identity != identity) return;
                    try {
                      await current.invalidate();
                    } catch (_) {
                      return;
                    }
                    if (mounted && _identity == identity) {
                      current.release();
                      setState(() {
                        _request = ThumbnailPool.forGateway(widget.gateway)
                            .acquire(photo, current.sizeClass);
                      });
                    }
                  });
                }
                return const SizedBox.shrink();
              },
            )
          : const SizedBox.shrink(),
    );
  }
}
