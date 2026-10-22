import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Storage facts that only the Android activity can resolve.
@immutable
final class AndroidPaths {
  const AndroidPaths({
    required this.filesDir,
    required this.cacheDir,
    required this.externalRoot,
    required this.hasAllFiles,
    required this.sdk,
  });

  final String filesDir;
  final String cacheDir;
  final String externalRoot;
  final bool hasAllFiles;
  final int sdk;

  /// The path-based library lives in app-private storage, exactly like a
  /// desktop library root, so SQLite and the trash keep their file semantics.
  String get dataRoot => '$filesDir/library';

  AndroidPaths withAllFiles(bool value) => AndroidPaths(
    filesDir: filesDir,
    cacheDir: cacheDir,
    externalRoot: externalRoot,
    hasAllFiles: value,
    sdk: sdk,
  );
}

/// The single Android platform adapter. Everything below the path level is the
/// same Rust core the Linux client uses.
final class AndroidRuntime {
  static const _channel = MethodChannel('photo_client/android');
  static AndroidPaths? _cached;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static Future<AndroidPaths?> paths({bool refresh = false}) async {
    if (!isAndroid) return null;
    final cached = _cached;
    if (cached != null && !refresh) return cached;
    final values = await _channel.invokeMapMethod<String, Object?>('paths');
    if (values == null) throw StateError('AndroidPathsUnavailable');
    final result = AndroidPaths(
      filesDir: values['filesDir']! as String,
      cacheDir: values['cacheDir']! as String,
      externalRoot: values['externalRoot']! as String,
      hasAllFiles: values['hasAllFiles'] == true,
      sdk: (values['sdk'] as num?)?.toInt() ?? 0,
    );
    return _cached = result;
  }

  static Future<String?> defaultDataRoot() async => (await paths())?.dataRoot;

  static Future<bool> hasAllFiles() async {
    if (!isAndroid) return true;
    final granted = await _channel.invokeMethod<bool>('hasAllFiles') ?? false;
    final cached = _cached;
    if (cached != null) _cached = cached.withAllFiles(granted);
    return granted;
  }

  static Future<void> requestAllFiles() async {
    if (isAndroid) await _channel.invokeMethod<void>('requestAllFiles');
  }

  static Future<void> requestMediaPermissions() async {
    if (isAndroid) {
      await _channel.invokeMethod<void>('requestMediaPermissions');
    }
  }

  static Future<void> openAppSettings() async {
    if (isAndroid) await _channel.invokeMethod<void>('appSettings');
  }

  /// Makes renamed or edited shared-storage files visible to the system media
  /// index. The catalog itself scans paths and does not depend on this.
  static Future<void> mediaScan(List<String> paths) async {
    if (isAndroid && paths.isNotEmpty) {
      await _channel.invokeMethod<void>('mediaScan', paths);
    }
  }
}
