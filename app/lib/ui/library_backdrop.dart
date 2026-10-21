import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_theme.dart';
import 'local_library_controller.dart';
import 'local_photo_image.dart';
import 'runtime_controller.dart';

/// Hold one cover per destination so scrolling/paging never changes the wash.
/// It uses the thumbnail cache, with no original-file decode or extra scan.
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

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(localLibraryProvider);
    final gateway = ref.watch(coreGatewayProvider);
    final gatewayChanged = !identical(_gateway, gateway);
    if (_epoch != library.queryEpoch || gatewayChanged) {
      _epoch = library.queryEpoch;
      _gateway = gateway;
      _cover = null;
      _coverId = null;
      _request++;
      if (gatewayChanged) _image = null;
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
    final id = albumCover ?? first?.id;
    final rank = id == null ? null : library.indexOf(id);
    final photo = rank == null ? null : library.photoAt(rank);
    // Empty/trash destinations must not retain a previous private photo.
    if (library.trashed || (!library.loading && library.extent == 0)) {
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
    return GlassBackdrop(image: _image, child: widget.child);
  }

  Future<void> _load(
    LocalLibraryGateway gateway,
    String id,
    LocalPhoto? photo,
    int request,
  ) async {
    try {
      final path = await gateway.thumbnail(id, sizeClass: 512);
      if (!mounted || request != _request) return;
      final image = ResizeImage(
        photo == null ? FileImage(File(path)) : LocalPhotoImage(path, photo),
        width: 512,
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
