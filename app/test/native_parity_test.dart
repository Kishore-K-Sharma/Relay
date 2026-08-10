import 'dart:io';

import 'package:core_protocol/core_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three copies of the frame-type table agree.
///
/// There are three, in Dart, Kotlin and Swift, because the native relays parse
/// frame headers to decide what to forward while the app is not running. Both
/// of them **drop** a frame whose type they do not recognise, so a type added
/// in Dart and forgotten in native does not degrade — it stops dead at the
/// first hop through that platform, and only on real hardware, which is the
/// most expensive place to find out.
///
/// This reads the native sources as text rather than compiling them. That is
/// crude, and it is still the difference between catching this in a second and
/// catching it in a field test.
void main() {
  /// Reads a repo-relative path regardless of where the runner was started.
  ///
  /// `flutter test` runs with the working directory set to the package, while
  /// CI invokes it from the repository root. A guard that only works from one
  /// of those silently stops guarding from the other.
  String read(String path) {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final file = File('${dir.path}/$path');
      if (file.existsSync()) return file.readAsStringSync();
      if (dir.path == dir.parent.path) {
        fail(
          'cannot find $path from ${Directory.current.path} — has it moved?',
        );
      }
    }
  }

  test('Kotlin knows every frame type Dart can send', () {
    final source = read(
      'app/android/app/src/main/kotlin/dev/kishorek/relay/ble/RelayEngine.kt',
    );

    for (final type in FrameType.values) {
      final hex = type.wireValue
          .toRadixString(16)
          .toUpperCase()
          .padLeft(2, '0');
      expect(
        source,
        contains('0x$hex'),
        reason:
            '${type.name} (0x$hex) is missing from the Kotlin FrameType, so '
            'Android would drop it instead of relaying it',
      );
    }
  });

  test('Swift knows every frame type Dart can send', () {
    final source = read('app/ios/Runner/Ble/RelayEngine.swift');

    for (final type in FrameType.values) {
      final hex = type.wireValue
          .toRadixString(16)
          .toUpperCase()
          .padLeft(2, '0');
      expect(
        source,
        contains('0x$hex'),
        reason:
            '${type.name} (0x$hex) is missing from the Swift FrameType, so '
            'iOS would drop it instead of relaying it',
      );
    }
  });

  test('the guard would notice a missing type', () {
    // Proves the check above is doing something. A test that can only pass is
    // not a test.
    const invented = 0x7E;
    expect(
      read('app/ios/Runner/Ble/RelayEngine.swift'),
      isNot(contains('0x${invented.toRadixString(16).toUpperCase()}')),
    );
  });
}
