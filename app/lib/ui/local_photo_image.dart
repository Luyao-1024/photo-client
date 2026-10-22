import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../services/local_library_gateway.dart';

/// A local file may be replaced at the same path; cache by native media version.
class LocalPhotoImage extends FileImage {
  LocalPhotoImage(String path, LocalPhoto photo)
    : mediaId = photo.id,
      contentVersion = photo.contentVersion,
      super(File(path));

  final String mediaId;
  final int contentVersion;

  @override
  bool operator ==(Object other) =>
      other is LocalPhotoImage &&
      other.runtimeType == runtimeType &&
      other.file.path == file.path &&
      other.mediaId == mediaId &&
      other.contentVersion == contentVersion &&
      other.scale == scale;

  @override
  int get hashCode =>
      Object.hash(runtimeType, file.path, mediaId, contentVersion, scale);
}

/// Original stills must not start a GIF/WebP animation while metadata or the
/// dedicated animation stage is being prepared.
class StaticPhotoImage extends LocalPhotoImage {
  StaticPhotoImage(super.path, super.photo);
  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_decodeFirst(key, decode));
  Future<ImageInfo> _decodeFirst(
    FileImage key,
    ImageDecoderCallback decode,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(key.file.path);
    final codec = await decode(buffer);
    try {
      return ImageInfo(
        image: (await codec.getNextFrame()).image,
        scale: key.scale,
      );
    } finally {
      codec.dispose();
    }
  }
}

/// Bound both axes. Width-only decode over-allocates severely for long portraits.
ImageProvider boundedViewerImage(
  String path,
  LocalPhoto photo,
  Size viewport,
  double pixelRatio, {
  double scale = 1,
  bool animate = false,
}) => ResizeImage(
  animate ? LocalPhotoImage(path, photo) : StaticPhotoImage(path, photo),
  width: (viewport.width * pixelRatio * scale.clamp(1, 4)).ceil().clamp(
    64,
    4096,
  ),
  height: (viewport.height * pixelRatio * scale.clamp(1, 4)).ceil().clamp(
    64,
    4096,
  ),
  policy: ResizeImagePolicy.fit,
);
