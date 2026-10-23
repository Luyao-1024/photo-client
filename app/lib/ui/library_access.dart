import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/android_runtime.dart';

/// Android must resolve storage access before preferences or the backdrop can
/// open the catalog and consume its first source scan. Desktop is ready at once.
final libraryAccessProvider = NotifierProvider<LibraryAccessController, bool>(
  LibraryAccessController.new,
);

class LibraryAccessController extends Notifier<bool> {
  @override
  bool build() => !AndroidRuntime.isAndroid;

  void setGranted(bool granted) {
    if (state != granted) state = granted;
  }
}
