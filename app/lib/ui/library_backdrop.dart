import 'thumbnail_image.dart';
import '../services/thumbnail_pipeline.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'backdrop_viewport.dart';
import 'glass_theme.dart';
import 'local_library_controller.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';

/// Start with the saved cover; follow throttled viewport samples after scrolling.
/// Only decoded cache thumbnails can replace the last complete background.
class LibraryBackdrop extends ConsumerStatefulWidget {
  const LibraryBackdrop({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LibraryBackdrop> createState() => _LibraryBackdropState();
}

class _LibraryBackdropState extends ConsumerState<LibraryBackdrop> {
  Object? _gateway;
  int? _epoch;
  LocalPhoto? _cover;
  String? _coverId;
  int _request = 0;
  ImageProvider? _image;
  BackdropViewport? _focus;
  ThumbnailHandle? _thumbnail;
  MediaThumbnailHandle? _coverThumbnail;
  @override
  void dispose() {
    _thumbnail?.release();
    _coverThumbnail?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(localLibraryProvider);
    final preferences = ref.watch(presentationProvider);
    final viewport = ref.watch(backdropViewportProvider);
    final gateway = ref.watch(coreGatewayProvider);
    final gatewayChanged = !identical(_gateway, gateway);
    if (_epoch != library.queryEpoch || gatewayChanged) {
      _epoch = library.queryEpoch;
      _gateway = gateway;
      _thumbnail?.release();
      _thumbnail = null;
      _coverThumbnail?.release();
      _coverThumbnail = null;
      _cover = null;
      _coverId = null;
      _request++;
      if (gatewayChanged) _image = null;
    }
    final focus =
        preferences.followScroll &&
            viewport?.queryEpoch == library.queryEpoch &&
            viewport?.rank != null
        ? viewport
        : null;
    if (_focus != focus) {
      _focus = focus;
      _thumbnail?.release();
      _thumbnail = null;
      _cover = null;
      _coverId = null;
      // Invalidate late decodes even if this target's DTO page is not here yet.
      _request++;
    }
    final first = library.photoAt(0);
    String? albumCover;
    if (library.folder != null) {
      for (final album in library.albums) {
        if (album.path == library.folder) {
          albumCover = album.coverMediaId;
          break;
        }
      }
    }
    final focusedRank = focus?.rank;
    final id = focusedRank == null
        ? albumCover ?? first?.id
        : library.photoAt(focusedRank)?.id;
    final rank = id == null ? null : library.indexOf(id);
    final photo = rank == null ? null : library.photoAt(rank);
    // Empty/trash destinations must not retain a previous private photo.
    if (library.trashed || (!library.loading && library.extent == 0)) {
      _thumbnail?.release();
      _thumbnail = null;
      _cover = null;
      _coverId = null;
      _image = null;
      _request++;
    } else if (id != null &&
        gateway is LocalLibraryGateway &&
        (_coverId != id ||
            (photo != null &&
                photo.contentVersion != _cover?.contentVersion))) {
      _coverId = id;
      _cover = photo;
      unawaited(_load(gateway as LocalLibraryGateway, id, photo, ++_request));
    }
    return GlassBackdrop(
      image: _image,
      blurSigma: preferences.backgroundBlur * 36,
      child: widget.child,
    );
  }

  Future<void> _load(
    LocalLibraryGateway gateway,
    String id,
    LocalPhoto? photo,
    int request,
  ) async {
    try {
      _thumbnail?.release();
      _coverThumbnail?.release();
      _coverThumbnail = photo == null
          ? MediaThumbnailHandle(gateway, id, 512)
          : null;
      _thumbnail = photo == null
          ? null
          : ThumbnailPool.forGateway(gateway).acquire(photo, 512, priority: 1);
      final path = await (_thumbnail?.future ?? _coverThumbnail!.future);
      if (!mounted || request != _request) return;
      final image = photo == null
          ? ThumbnailImage(
              ResizeImage(FileImage(File(path)), width: 512),
              use: ThumbnailUse.background,
            )
          : ThumbnailImage.file(
              path,
              photo,
              width: 512,
              use: ThumbnailUse.background,
            );
      var failed = false;
      // A filename alone is not a paintable frame. Decode first while retaining
      // the last complete image, then let the background dissolve into this one.
      await precacheImage(image, context, onError: (_, stack) => failed = true);
      if (!mounted || request != _request || failed) return;
      setState(() => _image = image);
    } catch (_) {
      // Failed or stale requests never replace a complete background with blank.
    }
  }
}
