import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'platform/native_core_gateway.dart';
import 'services/core_gateway.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final smoke = arguments.contains('--self-test');
  final rejection = smoke && arguments.contains('--expect-profile-mismatch')
      ? 'BuildProfileMismatch'
      : smoke && arguments.contains('--expect-bridge-mismatch')
      ? 'BridgeMismatch'
      : null;
  final gateway = NativeCoreGateway(
    expectedDigestOverride: rejection == 'BuildProfileMismatch'
        ? 'invalid'
        : null,
    protocolOverride: rejection == 'BridgeMismatch' ? 2 : null,
  );
  if (smoke) {
    runApp(_BootstrapSmokeApp(gateway: gateway, expectedRejection: rejection));
  } else {
    runApp(PhotoClientApp(gateway: gateway));
  }
}

/// A real-window check, separate from the product flow and fake widget tests.
class _BootstrapSmokeApp extends StatefulWidget {
  const _BootstrapSmokeApp({required this.gateway, this.expectedRejection});
  final CoreGateway gateway;
  final String? expectedRejection;
  @override
  State<_BootstrapSmokeApp> createState() => _BootstrapSmokeAppState();
}

class _BootstrapSmokeAppState extends State<_BootstrapSmokeApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  Future<void> _check() async {
    StreamSubscription<CoreRuntimeEvent>? subscription;
    try {
      final snapshot = await widget.gateway.initialize();
      if (widget.expectedRejection != null) {
        throw StateError('ExpectedRejectionDidNotOccur');
      }
      final initial = Completer<void>();
      final roundTrip = Completer<void>();
      final closed = Completer<void>();
      final sequence = <int>[];
      subscription = widget.gateway.watchRuntime().listen((event) {
        sequence.add(event.sequence);
        if (event.status == 'bridge_ready' && !initial.isCompleted) {
          initial.complete();
        }
        if (event.status == 'round_trip_complete' && !roundTrip.isCompleted) {
          roundTrip.complete();
        }
        if (event.status == 'closed' && !closed.isCompleted) closed.complete();
      });
      await initial.future.timeout(const Duration(seconds: 10));
      const message = 'Photo Client / Linux / 照片';
      final reply = await widget.gateway.roundTrip(message);
      if (reply != message) throw StateError('RoundTripMismatch');
      await roundTrip.future.timeout(const Duration(seconds: 10));
      await widget.gateway.shutdown();
      await closed.future.timeout(const Duration(seconds: 10));
      if (sequence.length != 3 ||
          sequence[0] >= sequence[1] ||
          sequence[1] >= sequence[2]) {
        throw StateError('EventOrderMismatch');
      }
      await subscription.cancel();
      stdout.writeln(
        'PHOTO_CLIENT_SMOKE ${jsonEncode({'result': 'PASS', 'real_window': true, 'profile_id': snapshot.profileId, 'profile_digest': snapshot.profileDigest, 'bridge_protocol_version': snapshot.bridgeProtocolVersion, 'round_trip': true, 'event_sequence': sequence, 'shutdown': true})}',
      );
      await stdout.flush();
      exit(0);
    } catch (error) {
      await subscription?.cancel();
      final rejection = widget.expectedRejection;
      if (rejection != null && error.toString().contains(rejection)) {
        stdout.writeln(
          'PHOTO_CLIENT_SMOKE ${jsonEncode({'result': 'PASS', 'expected_rejection': rejection, 'initialized': false})}',
        );
        await stdout.flush();
        exit(0);
      }
      await widget.gateway.shutdown();
      stderr.writeln('BOOTSTRAP_DIAGNOSTIC: ${error.runtimeType}: $error');
      stderr.writeln(
        'PHOTO_CLIENT_SMOKE {"result":"FAIL","reason":"BootstrapCheckFailed"}',
      );
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Photo Client — Linux 启动验证'))),
  );
}
