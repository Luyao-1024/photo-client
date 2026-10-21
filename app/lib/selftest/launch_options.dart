import 'dart:io';

/// Command-line contract for the real product process.
///
/// Product runs accept `--data-root` only. Everything else selects an
/// acceptance driver, which reuses the same real gateway, database and window.
final class LaunchOptions {
  const LaunchOptions({
    this.selfTest = false,
    this.expectedRejection,
    this.dataRoot,
    this.localJourney = false,
    this.journeyPhase = 'provision',
    this.sources = const [],
    this.evidenceDir,
    this.expectLibraryId,
    this.expectCount,
    this.expectFavoritePath,
    this.missingPath,
    this.changedPath,
    this.holdSeconds = 0,
    this.inputMode = 'x11',
    this.expectRejected = false,
    this.cloudEndpoint,
    this.cloudUsername,
    this.cloudBatchAlbum,
    this.cloudSingleAlbum,
    this.cloudExtraAlbum,
    this.cloudExpectedPhotos = 0,
  });

  static const Set<String> _known = {
    '--self-test',
    '--expect-profile-mismatch',
    '--expect-bridge-mismatch',
    '--data-root',
    '--local-journey',
    '--journey-phase',
    '--source',
    '--evidence-dir',
    '--expect-library-id',
    '--expect-count',
    '--expect-favorite-path',
    '--missing-path',
    '--changed-path',
    '--hold-seconds',
    '--input',
    '--expect-rejected',
    '--cloud-endpoint',
    '--cloud-username',
    '--cloud-batch-album',
    '--cloud-single-album',
    '--cloud-extra-album',
    '--cloud-expected-photos',
    // Consumed by the Linux runner; accepted here so strict runs stay clean.
    '--window-size',
  };

  final bool selfTest;
  final String? expectedRejection;
  final String? dataRoot;
  final bool localJourney;
  final String journeyPhase;
  final List<String> sources;
  final String? evidenceDir;
  final String? expectLibraryId;
  final int? expectCount;
  final String? expectFavoritePath;
  final String? missingPath;
  final String? changedPath;
  final int holdSeconds;
  final String inputMode;
  final bool expectRejected;

  /// Cloud journeys use a real server. The password is never a command-line
  /// argument; it arrives through `PHOTO_CLOUD_PASSWORD` for the child process.
  final String? cloudEndpoint;
  final String? cloudUsername;
  final String? cloudBatchAlbum;
  final String? cloudSingleAlbum;
  final String? cloudExtraAlbum;
  final int cloudExpectedPhotos;

  String get cloudPassword =>
      Platform.environment['PHOTO_CLOUD_PASSWORD'] ?? '';

  String requireCloudEndpoint() =>
      cloudEndpoint ?? (throw ArgumentError('--cloud-endpoint is required'));

  String requireCloudUsername() =>
      cloudUsername ?? (throw ArgumentError('--cloud-username is required'));

  String requireCloudAlbum(String name, String? value) =>
      value ?? (throw ArgumentError('--$name is required'));

  static LaunchOptions parse(List<String> arguments, {bool strict = false}) {
    var selfTest = false;
    String? rejection;
    String? dataRoot;
    var journey = false;
    var phase = 'provision';
    final sources = <String>[];
    String? evidenceDir;
    String? expectLibraryId;
    int? expectCount;
    String? expectFavoritePath;
    String? missingPath;
    String? changedPath;
    var holdSeconds = 0;
    var inputMode = 'x11';
    var expectRejected = false;
    String? cloudEndpoint;
    String? cloudUsername;
    String? cloudBatchAlbum;
    String? cloudSingleAlbum;
    String? cloudExtraAlbum;
    var cloudExpectedPhotos = 0;

    String value(String flag, String? inline, int index) {
      if (inline != null) return inline;
      if (index + 1 >= arguments.length) {
        throw ArgumentError('$flag requires a value');
      }
      return arguments[index + 1];
    }

    for (var index = 0; index < arguments.length; index += 1) {
      final raw = arguments[index];
      final equals = raw.indexOf('=');
      final flag = equals < 0 ? raw : raw.substring(0, equals);
      final inline = equals < 0 ? null : raw.substring(equals + 1);
      var consumed = false;
      switch (flag) {
        case '--self-test':
          selfTest = true;
        case '--expect-profile-mismatch':
          rejection = 'BuildProfileMismatch';
        case '--expect-bridge-mismatch':
          rejection = 'BridgeMismatch';
        case '--local-journey':
          journey = true;
        case '--expect-rejected':
          expectRejected = true;
        case '--data-root':
          dataRoot = value(flag, inline, index);
          consumed = inline == null;
        case '--journey-phase':
          phase = value(flag, inline, index);
          consumed = inline == null;
        case '--source':
          sources.add(value(flag, inline, index));
          consumed = inline == null;
        case '--evidence-dir':
          evidenceDir = value(flag, inline, index);
          consumed = inline == null;
        case '--expect-library-id':
          expectLibraryId = value(flag, inline, index);
          consumed = inline == null;
        case '--expect-count':
          expectCount = int.parse(value(flag, inline, index));
          consumed = inline == null;
        case '--expect-favorite-path':
          expectFavoritePath = value(flag, inline, index);
          consumed = inline == null;
        case '--missing-path':
          missingPath = value(flag, inline, index);
          consumed = inline == null;
        case '--changed-path':
          changedPath = value(flag, inline, index);
          consumed = inline == null;
        case '--hold-seconds':
          holdSeconds = int.parse(value(flag, inline, index));
          consumed = inline == null;
        case '--input':
          inputMode = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-endpoint':
          cloudEndpoint = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-username':
          cloudUsername = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-batch-album':
          cloudBatchAlbum = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-single-album':
          cloudSingleAlbum = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-extra-album':
          cloudExtraAlbum = value(flag, inline, index);
          consumed = inline == null;
        case '--cloud-expected-photos':
          cloudExpectedPhotos = int.parse(value(flag, inline, index));
          consumed = inline == null;
        case '--window-size':
          break;
        default:
          if (strict && !_known.contains(flag)) {
            throw ArgumentError('Unsupported argument: $flag');
          }
      }
      if (consumed) index += 1;
    }
    return LaunchOptions(
      selfTest: selfTest,
      expectedRejection: rejection,
      dataRoot: dataRoot,
      localJourney: journey,
      journeyPhase: phase,
      sources: List.unmodifiable(sources),
      evidenceDir: evidenceDir,
      expectLibraryId: expectLibraryId,
      expectCount: expectCount,
      expectFavoritePath: expectFavoritePath,
      missingPath: missingPath,
      changedPath: changedPath,
      holdSeconds: holdSeconds,
      inputMode: inputMode,
      expectRejected: expectRejected,
      cloudEndpoint: cloudEndpoint,
      cloudUsername: cloudUsername,
      cloudBatchAlbum: cloudBatchAlbum,
      cloudSingleAlbum: cloudSingleAlbum,
      cloudExtraAlbum: cloudExtraAlbum,
      cloudExpectedPhotos: cloudExpectedPhotos,
    );
  }
}
