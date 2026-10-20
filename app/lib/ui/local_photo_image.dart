import 'dart:io';

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
      other.file.path == file.path &&
      other.mediaId == mediaId &&
      other.contentVersion == contentVersion &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(file.path, mediaId, contentVersion, scale);
}
