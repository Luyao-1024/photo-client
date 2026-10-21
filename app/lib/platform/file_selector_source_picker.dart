import 'package:file_selector/file_selector.dart';

import '../services/local_library_gateway.dart';

/// Real Linux source selection through the platform file chooser.
///
/// Only the formats the local scanner indexes are offered; everything else would
/// be skipped as unsupported and must not look like a successful import.
final class FileSelectorSourcePicker implements LocalSourcePicker {
  const FileSelectorSourcePicker();

  static const XTypeGroup _images = XTypeGroup(
    label: 'Images',
    extensions: [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'heic',
      'heif',
      'mp4',
      'm4v',
      'mov',
      'webm',
      'mkv',
      'avi',
    ],
  );

  @override
  Future<List<String>> chooseFiles() async {
    final files = await openFiles(acceptedTypeGroups: const [_images]);
    return [for (final file in files) file.path];
  }

  @override
  Future<String?> chooseDirectory() =>
      getDirectoryPath(confirmButtonText: 'Add folder');
}
