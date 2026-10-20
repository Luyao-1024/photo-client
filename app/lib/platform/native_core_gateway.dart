import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../services/core_gateway.dart';
import '../src/rust/api/bootstrap.dart' as native;
import '../src/rust/frb_generated.dart';

/// The only presentation adapter that knows the generated FFI API or native path.
final class NativeCoreGateway implements CoreGateway {
  NativeCoreGateway({this.expectedDigestOverride, this.protocolOverride});

  /// Used only by the real-window rejection checks, never by product settings.
  final String? expectedDigestOverride;
  final int? protocolOverride;
  static Future<void>? _bindingInitialization;
  CoreSnapshot? _snapshot;

  static Future<void> _initializeBinding() async {
    if (!Platform.isLinux) {
      throw UnsupportedError('PlatformPlanned');
    }
    final directory = File(Platform.resolvedExecutable).parent.path;
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        '$directory/lib/libphoto_bridge.so',
      ),
    );
  }

  @override
  Future<CoreSnapshot> initialize() async {
    final existing = _snapshot;
    if (existing != null) return existing;
    final binding = _bindingInitialization ??= _initializeBinding();
    try {
      await binding;
    } catch (_) {
      if (identical(_bindingInitialization, binding)) {
        _bindingInitialization = null;
      }
      rethrow;
    }
    const profile = String.fromEnvironment('PHOTO_PROFILE_JSON');
    const digest = String.fromEnvironment('PHOTO_PROFILE_DIGEST');
    const protocolText = String.fromEnvironment(
      'PHOTO_BRIDGE_PROTOCOL_VERSION',
      defaultValue: '1',
    );
    if (profile.isEmpty || digest.isEmpty) {
      throw StateError('BuildProfileMissing');
    }
    final result = await native.initialize(
      profileJson: profile,
      expectedDigest: expectedDigestOverride ?? digest,
      bridgeProtocolVersion: protocolOverride ?? int.parse(protocolText),
    );
    return _snapshot = CoreSnapshot(
      profileId: result.profileId,
      profileDigest: result.profileDigest,
      bridgeProtocolVersion: result.bridgeProtocolVersion,
      sessionId: result.sessionId,
      status: result.status,
    );
  }

  @override
  Stream<CoreRuntimeEvent> watchRuntime() {
    if (_snapshot == null) throw StateError('NotInitialized');
    return native.watchRuntime().map(
      (event) => CoreRuntimeEvent(
        sequence: event.sequence.toInt(),
        status: event.status,
      ),
    );
  }

  @override
  Future<String> roundTrip(String message) =>
      native.roundTrip(message: message);

  @override
  Future<void> shutdown() async {
    if (_snapshot == null) return;
    await native.shutdown();
    _snapshot = null;
  }
}
