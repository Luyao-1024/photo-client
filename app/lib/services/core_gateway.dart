/// Platform-neutral boundary owned by the presentation layer.
///
/// Implementations must support another initialize attempt after a failed one.
/// shutdown must release the current session, including partial initialization.
abstract class CoreGateway {
  Future<CoreSnapshot> initialize();
  Stream<CoreRuntimeEvent> watchRuntime();
  Future<String> roundTrip(String message);
  Future<void> shutdown();
}

class CoreSnapshot {
  const CoreSnapshot({
    required this.profileId,
    required this.profileDigest,
    required this.bridgeProtocolVersion,
    required this.sessionId,
    required this.status,
  });

  final String profileId;
  final String profileDigest;
  final int bridgeProtocolVersion;
  final String sessionId;
  final String status;
}

class CoreRuntimeEvent {
  const CoreRuntimeEvent({required this.sequence, required this.status});

  final int sequence;
  final String status;
}
