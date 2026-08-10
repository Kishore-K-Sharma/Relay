import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';

/// The Dart half of the power-mode contract.
///
/// Kotlin and Swift are checked against the same file by the parity runners in
/// `tools/`. The figure that matters is the battery cost, because it is printed
/// on screen next to the user's choice: if Dart says 5% an hour while native
/// runs a duty cycle designed for 12%, the app is lying about what the setting
/// costs, and battery lies are how a background app gets uninstalled.
Map<String, dynamic> loadModes() {
  for (final candidate in [
    'testvectors/power/modes.json',
    '../testvectors/power/modes.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  throw StateError('power vectors not found');
}

void main() {
  final contract = loadModes();
  final modes = (contract['modes'] as List).cast<Map<String, dynamic>>();

  test('every mode in the contract exists in Dart, and no others', () {
    expect(
      PowerMode.values.map((m) => m.name).toSet(),
      modes.map((m) => m['name'] as String).toSet(),
    );
  });

  for (final vector in modes) {
    final mode = PowerMode.values.byName(vector['name'] as String);

    test('${mode.name} quotes the agreed battery cost', () {
      expect(mode.drainPercentPerHour, vector['estimatedDrainPercentPerHour']);
    });

    test('${mode.name} uses the agreed announce interval', () {
      expect(mode.announceIntervalMs, vector['announceIntervalMs']);
    });
  }

  test('the modes are ordered from most to least expensive', () {
    final costs = PowerMode.values.map((m) => m.drainPercentPerHour).toList();

    // The settings screen lists them in declaration order. Presenting the
    // cheapest first would nudge users away from the mode that actually makes
    // the mesh work, and presenting them unordered is just confusing.
    for (var i = 1; i < costs.length; i++) {
      expect(costs[i], lessThan(costs[i - 1]));
    }
  });

  test('a cheaper mode announces less often, never more', () {
    final intervals = PowerMode.values
        .map((m) => m.announceIntervalMs)
        .toList();

    for (var i = 1; i < intervals.length; i++) {
      expect(intervals[i], greaterThan(intervals[i - 1]));
    }
  });

  test('the figures are still flagged as estimates', () {
    // Turns to true only when the Phase 6 battery measurement has been done on
    // real hardware. Until then the app is quoting an engineering guess, and
    // this test exists so that fact cannot be quietly forgotten.
    expect(
      contract['measured'],
      isFalse,
      reason:
          'if the battery measurement has been done, update the figures and '
          'the in-app copy, not just this flag',
    );
  });
}
