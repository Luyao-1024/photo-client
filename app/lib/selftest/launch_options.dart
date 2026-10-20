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
    this.holdSeconds = 0,
    this.inputMode = 'x11',
    this.expectRejected = false,
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
    '--hold-seconds',
    '--input',
    '--expect-rejected',
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
  final int holdSeconds;
  final String inputMode;
  final bool expectRejected;

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
    var holdSeconds = 0;
    var inputMode = 'x11';
    var expectRejected = false;

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
        case '--hold-seconds':
          holdSeconds = int.parse(value(flag, inline, index));
          consumed = inline == null;
        case '--input':
          inputMode = value(flag, inline, index);
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
      holdSeconds: holdSeconds,
      inputMode: inputMode,
      expectRejected: expectRejected,
    );
  }
}
