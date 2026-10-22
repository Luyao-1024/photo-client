import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/android_runtime.dart';

/// Android phones use a touch-first shell; every desktop target keeps the
/// existing sidebar workspace. Tests can override the provider directly.
enum LibraryLayout { desktop, mobile }

final libraryLayoutProvider = Provider<LibraryLayout>(
  (ref) =>
      AndroidRuntime.isAndroid ? LibraryLayout.mobile : LibraryLayout.desktop,
);
