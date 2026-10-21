import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/app.dart';

import 'fakes/local_gateway.dart';

void main() {
  testWidgets('settings groups and category rows keep visible Material ink', (
    tester,
  ) async {
    final gateway = FakeLocalGateway(imagePath: 'unused', count: 0);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearLocaleTestValue();
    });

    await tester.pumpWidget(PhotoClientApp(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('settings-shortcuts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shortcuts-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shortcuts-close')));
    await tester.pumpAndSettle();
    for (final category in [1, 2, 3, 0]) {
      await tester.tap(find.byKey(ValueKey('settings-category-$category')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await gateway.changes.close();
    await gateway.events.close();
  });
}
