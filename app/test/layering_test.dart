import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The four directories under `app/lib/src` mean something.
///
/// `domain/`, `runtime/`, `ui/` and `app/` are a split by what a file is
/// allowed to depend on, not by feature. A folder structure that is only a
/// convention lasts until the first hurried afternoon: someone needs a colour
/// inside a data class, imports `material.dart`, and the layer quietly stops
/// being testable without a widget tester. Nothing about that shows up in a
/// diff unless something is watching.
///
/// The rules, and what each one is actually protecting:
///
/// * `domain/` holds pure data and pure functions. It may use
///   `flutter/foundation.dart` — `@immutable` and `ChangeNotifier` are not UI —
///   but never `material.dart`, `widgets.dart` or `cupertino.dart`. The moment
///   it does, the cheapest tests in the app need a `WidgetTester`.
/// * `runtime/` holds the moving parts. Same ban on Flutter UI: the mesh must
///   be drivable with no screen attached, which is how every multi-device test
///   in this suite works.
/// * Dependencies point one way: `domain` ← `runtime` ← `ui` ← `app`. A screen
///   that a data class imports is a cycle waiting to happen.
/// * Intra-library imports are absolute. `../../domain/models.dart` says
///   nothing about which layer it crosses into.
void main() {
  Directory libSrc() {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final candidate = Directory('${dir.path}/app/lib/src');
      if (candidate.existsSync()) return candidate;
      if (dir.path == dir.parent.path) {
        fail('cannot find app/lib/src from ${Directory.current.path}');
      }
    }
  }

  final root = libSrc();

  /// Every Dart file under `app/lib/src/<layer>`, as (path relative to src,
  /// contents).
  List<(String, String)> filesIn(String layer) {
    final dir = Directory('${root.path}/$layer');
    if (!dir.existsSync()) fail('app/lib/src/$layer is missing');
    return [
      for (final entity in dir.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          (
            entity.path.substring(root.path.length + 1),
            entity.readAsStringSync(),
          ),
    ];
  }

  /// The layer names as they appear in a `package:relay_app/src/...` import.
  const layers = ['app', 'domain', 'runtime', 'ui'];

  test('every source file lives in one of the four layers', () {
    // A file left at the root of src/ belongs to no layer, so no rule below
    // applies to it and the structure erodes from the middle outwards.
    final loose = [
      for (final entity in root.listSync())
        if (entity is File && entity.path.endsWith('.dart'))
          entity.path.substring(root.path.length + 1),
    ];

    expect(
      loose,
      isEmpty,
      reason:
          'put these under domain/, runtime/, ui/ or app/ — whichever matches '
          'what they are allowed to depend on',
    );
  });

  for (final layer in ['domain', 'runtime']) {
    test('$layer/ does not import Flutter UI', () {
      final offenders = <String>[];
      for (final (path, source) in filesIn(layer)) {
        for (final library in ['material', 'widgets', 'cupertino']) {
          if (source.contains("package:flutter/$library.dart")) {
            offenders.add('$path imports flutter/$library.dart');
          }
        }
      }

      expect(
        offenders..sort(),
        isEmpty,
        reason:
            '$layer/ must be testable and runnable with no screen attached. '
            'flutter/foundation.dart is fine; anything that draws is not. If a '
            'widget is genuinely needed, the file belongs in ui/.',
      );
    });
  }

  /// What each layer is allowed to reach for. Read as: `domain` may import
  /// nothing else of ours; `app` may import everything, because wiring the
  /// other three together is the only thing it does.
  const mayImport = <String, Set<String>>{
    'domain': {},
    'runtime': {'domain'},
    'ui': {'domain', 'runtime'},
    'app': {'domain', 'runtime', 'ui'},
  };

  mayImport.forEach((layer, allowed) {
    test(
      '$layer/ only imports ${allowed.isEmpty ? 'nothing' : allowed.join(', ')}',
      () {
        final offenders = <String>[];
        for (final (path, source) in filesIn(layer)) {
          for (final other in layers) {
            if (other == layer || allowed.contains(other)) continue;
            if (source.contains('package:relay_app/src/$other/')) {
              offenders.add('$path imports $other/');
            }
          }
        }

        expect(
          offenders..sort(),
          isEmpty,
          reason:
              'Dependencies run domain <- runtime <- ui <- app, one way only. '
              'Reaching back up the stack is how a data class ends up needing a '
              'screen in order to be constructed.',
        );
      },
    );
  });

  test('intra-library imports are absolute, not relative', () {
    final offenders = <String>[];
    for (final layer in layers) {
      for (final (path, source) in filesIn(layer)) {
        for (final match in RegExp(
          r"^(?:import|export) '([^']+)'",
          multiLine: true,
        ).allMatches(source)) {
          final target = match.group(1)!;
          if (target.startsWith('dart:') || target.startsWith('package:')) {
            continue;
          }
          offenders.add("$path imports '$target'");
        }
      }
    }

    expect(
      offenders..sort(),
      isEmpty,
      reason:
          "use 'package:relay_app/src/<layer>/<file>.dart'. A relative import "
          'across four directories reads ../../domain/models.dart, which hides '
          'the very thing these rules are about — which layer it crosses into.',
    );
  });
}
