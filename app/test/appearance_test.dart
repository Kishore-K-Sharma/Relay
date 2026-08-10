import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/runtime/app_state.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';
import 'package:relay_app/src/ui/theme.dart';

/// Choosing how the app looks, and how hard it works.
void main() {
  const status = MeshStatus(
    bluetoothOn: true,
    permissionsGranted: true,
    peersInRange: 1,
  );

  group('the theme', () {
    test('defaults to dark', () {
      // The app is used at night, outdoors, in crowds. A bright screen ruins
      // night vision and marks the user out.
      expect(AppState(nickname: 'me').themeChoice, ThemeChoice.dark);
    });

    test('offers following the system', () {
      // Somebody whose phone switches at sunset expects this app to as well.
      expect(ThemeChoice.values, contains(ThemeChoice.system));
    });

    test('maps to a Flutter mode', () {
      expect(ThemeChoice.dark.mode, ThemeMode.dark);
      expect(ThemeChoice.light.mode, ThemeMode.light);
      expect(ThemeChoice.system.mode, ThemeMode.system);
    });

    test('a change is announced so the app can rebuild and store it', () {
      final state = AppState(nickname: 'me');
      var notified = 0;
      state.addListener(() => notified++);

      state.themeChoice = ThemeChoice.light;

      expect(state.themeChoice, ThemeChoice.light);
      expect(notified, 1);
    });

    test('setting the same choice changes nothing', () {
      final state = AppState(nickname: 'me');
      var notified = 0;
      state.addListener(() => notified++);

      state.themeChoice = ThemeChoice.dark;

      expect(notified, 0);
    });

    testWidgets('is chosen from settings', (tester) async {
      ThemeChoice? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            status: status,
            nickname: 'me',
            themeChoice: ThemeChoice.dark,
            onThemeChanged: (value) => chosen = value,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('theme-light')));
      await tester.pump();

      expect(chosen, ThemeChoice.light);
    });

    testWidgets('a light theme is readable', (tester) async {
      // Guards the one thing a second theme can get wrong: text the same
      // colour as what is behind it.
      final theme = appTheme(brightness: Brightness.light);

      expect(theme.colorScheme.brightness, Brightness.light);
      expect(
        theme.colorScheme.onSurface.computeLuminance(),
        lessThan(theme.colorScheme.surface.computeLuminance()),
      );
    });
  });

  group('power modes', () {
    test('there is a mode for making the battery last', () {
      // bitchat's fourth tier. Somebody on 4% who still needs to be reachable
      // is exactly who this app is for, and "battery saver" was not the floor.
      expect(PowerMode.values, contains(PowerMode.ultraLow));
    });

    test('they are ordered from most to least power', () {
      final drains = <double>[
        for (final mode in PowerMode.values) mode.drainPercentPerHour,
      ];

      final descending = List<double>.of(drains)
        ..sort((a, b) => b.compareTo(a));
      expect(drains, orderedEquals(descending));
    });

    test('a lower mode announces less often', () {
      expect(
        PowerMode.ultraLow.announceIntervalMs,
        greaterThan(PowerMode.saver.announceIntervalMs),
      );
    });

    test('each says what it costs the user, not what it does technically', () {
      for (final mode in PowerMode.values) {
        expect(mode.label, isNotEmpty);
        expect(mode.detail, isNotEmpty);
        expect(
          mode.detail,
          isNot(contains('ms')),
          reason: '${mode.name} describes an interval rather than an effect',
        );
      }
    });

    testWidgets('every mode is offered', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            status: status,
            nickname: 'me',
            powerMode: PowerMode.balanced,
            onPowerModeChanged: (_) {},
          ),
        ),
      );

      for (final mode in PowerMode.values) {
        expect(
          find.text(mode.label),
          findsOneWidget,
          reason: '${mode.name} is missing from settings',
        );
      }
    });
  });
}
