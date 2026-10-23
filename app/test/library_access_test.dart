import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/library_access.dart';
import 'package:photo_client/ui/local_library_controller.dart';
import 'package:photo_client/ui/presentation_preferences.dart';
import 'package:photo_client/ui/runtime_controller.dart';

import 'fakes/local_gateway.dart';

class _PendingAccess extends LibraryAccessController {
  @override
  bool build() => false;
}

class _RecordingGateway extends FakeToolsGateway {
  _RecordingGateway() : super(imagePath: 'unused');
  final commands = <String>[];

  @override
  Future<Object?> localCommand(Map<String, Object?> command) {
    commands.add(command['op'] as String);
    return super.localCommand(command);
  }
}

Future<void> settleProviders() async {
  // Drain the asynchronous runtime -> preferences -> catalog startup chain.
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'storage authorization precedes preferences and the initial catalog scan',
    () async {
      final gateway = _RecordingGateway();
      final container = ProviderContainer(
        overrides: [
          coreGatewayProvider.overrideWithValue(gateway),
          libraryAccessProvider.overrideWith(_PendingAccess.new),
        ],
      );
      container.listen(presentationProvider, (_, _) {});
      container.listen(localLibraryProvider, (_, _) {});
      await settleProviders();

      expect(gateway.initializes, 0);
      expect(gateway.openCalls, 0);
      expect(gateway.commands, isEmpty);
      expect(container.read(runtimeProvider).phase, ConnectionPhase.connecting);

      container.read(libraryAccessProvider.notifier).setGranted(true);
      await settleProviders();
      expect(gateway.initializes, 1);
      expect(gateway.openCalls, greaterThan(0));
      expect(gateway.commands, contains('preferences'));
      expect(container.read(runtimeProvider).phase, ConnectionPhase.ready);

      container.dispose();
      await settleProviders();
      await gateway.changes.close();
      await gateway.events.close();
    },
  );

  test(
    'denied retries stay idle and repeated permission checks keep the session',
    () async {
      final gateway = _RecordingGateway();
      final container = ProviderContainer(
        overrides: [
          coreGatewayProvider.overrideWithValue(gateway),
          libraryAccessProvider.overrideWith(_PendingAccess.new),
        ],
      );
      container.listen(runtimeProvider, (_, _) {});
      await container.read(runtimeProvider.notifier).initialize();
      await settleProviders();
      expect(gateway.initializes, 0);

      final access = container.read(libraryAccessProvider.notifier);
      access.setGranted(true);
      await settleProviders();
      access.setGranted(true);
      access.setGranted(false);
      access.setGranted(true);
      await settleProviders();
      expect(gateway.initializes, 1);
      expect(gateway.shutdowns, 0);

      container.dispose();
      await settleProviders();
      await gateway.changes.close();
      await gateway.events.close();
    },
  );
}
