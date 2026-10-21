import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:photo_client/app.dart';
import 'package:photo_client/services/local_library_tools.dart';
import 'package:photo_client/ui/presentation_preferences.dart';

import 'fakes/local_gateway.dart';

class _Gateway extends FakeLocalGateway implements LocalLibraryTools {
  _Gateway(this.saved) : super(imagePath: 'unused');
  final Map<String, Object?> saved;
  @override
  Future<Object?> localCommand(Map<String, Object?> command) async {
    switch (command['op']) {
      case 'preferences':
        return Map.of(saved);
      case 'setPreference':
        saved[command['key'] as String] = command['value'];
        return null;
      case 'window':
        return {
          'items': <Object?>[],
          'groups': <Object?>[],
          'total': 0,
          'revision': 1,
        };
      case 'sources':
        return <Object?>[];
      case 'cacheUsage':
        return 0;
      default:
        throw UnsupportedError('${command['op']}');
    }
  }
}

void main() {
  testWidgets(
    'appearance has only three persistent controls and ignores legacy material modes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearLocaleTestValue();
      });
      final saved = <String, Object?>{'glassMode': 'reduced'};
      Future<void> open(_Gateway gateway) async {
        await tester.pumpWidget(PhotoClientApp(gateway: gateway));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-category-1')));
        await tester.pumpAndSettle();
      }

      Future<void> close(_Gateway gateway) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await gateway.changes.close();
        await gateway.events.close();
      }

      final first = _Gateway(saved);
      await open(first);
      expect(find.byType(Slider), findsNWidgets(2));
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-content')),
          matching: find.byType(ChoiceChip),
        ),
        findsNothing,
      );
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-glass-quality')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('settings-reduce-motion')),
        findsNothing,
      );
      for (final scope in tester.widgetList<GlassAdaptiveScope>(
        find.byType(GlassAdaptiveScope),
      )) {
        expect(scope.minQuality, GlassQuality.premium);
        expect(scope.maxQuality, GlassQuality.premium);
        expect(scope.frostStep, isFalse);
        expect(scope.allowStepUp, isFalse);
      }
      for (final key in ['settings-transparency', 'settings-background-blur']) {
        final slider = find.byKey(ValueKey(key));
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final rect = tester.getRect(slider);
        await tester.tapAt(
          Offset(rect.left + rect.width * .75, rect.center.dy),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(slider).value, greaterThan(.6));
      }
      final follow = find.byKey(const ValueKey('settings-follow-scroll'));
      await tester.ensureVisible(follow);
      await tester.pumpAndSettle();
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(follow).value, isFalse);
      final container = ProviderScope.containerOf(tester.element(follow));
      await container.read(presentationProvider.notifier).flush();
      expect(saved['followScroll'], false);
      expect(
        saved['backgroundBlur'],
        container.read(presentationProvider).backgroundBlur,
      );
      expect(
        saved['transparency'],
        container.read(presentationProvider).transparency,
      );
      expect(saved['glassMode'], 'reduced');
      await close(first);
      final second = _Gateway(saved);
      await open(second);
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('settings-background-blur')),
            )
            .value,
        saved['backgroundBlur'],
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('settings-transparency')))
            .value,
        saved['transparency'],
      );
      expect(tester.widget<SwitchListTile>(follow).value, isFalse);
      expect(tester.takeException(), isNull);
      await close(second);
    },
  );
}
