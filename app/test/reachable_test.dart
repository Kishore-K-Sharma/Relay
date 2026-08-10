import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every public thing the runtime offers can be reached from the product.
///
/// This exists because the same bug happened twice. `depositWithCouriers` and
/// `leaveRoom` were both written, both tested, both correct — and neither had
/// a single caller outside the test suite. Couriering could not be invoked by
/// any user, and a room could be joined and never left.
///
/// Nothing catches that. The analyzer sees a public API and assumes somebody
/// outside will call it. The tests pass, because the tests *are* the caller.
/// Coverage is high for the same reason. It looks finished from every angle
/// except using it.
///
/// So: for each public member of MeshRuntime, find at least one reference from
/// production code — `app/lib` or `packages/*/lib` — other than its own
/// declaration. Reachability through another runtime method counts, because
/// that is a real path; `sendByCourier` calling `depositWithCouriers` is how
/// couriering became reachable.
///
/// The check is textual, so it is approximate in one direction only: it can be
/// fooled into thinking something is used, never into thinking something is
/// unused. A false pass is a missed bug; a false failure would be noise that
/// gets the test deleted. This errs toward the first.
void main() {
  String read(String path) {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final file = File('${dir.path}/$path');
      if (file.existsSync()) return file.readAsStringSync();
      if (dir.path == dir.parent.path) {
        fail('cannot find $path from ${Directory.current.path}');
      }
    }
  }

  Directory dirOf(String path) {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final candidate = Directory('${dir.path}/$path');
      if (candidate.existsSync()) return candidate;
      if (dir.path == dir.parent.path) fail('cannot find $path');
    }
  }

  /// Members that are deliberately not called from the product.
  ///
  /// Everything else that only tests use must be marked `@visibleForTesting`,
  /// which is the convention this file already used and which the analyzer
  /// enforces at the call site. That annotation is a claim — "this is a seam,
  /// not a feature" — and making it explicit is the whole point: the two bugs
  /// this test exists for were both features that *looked* like seams because
  /// nothing called them.
  ///
  /// Every entry below is a decision, not a backlog.
  const allowed = <String, String>{
    // A test seam for the room-ownership forgery case. It cannot carry
    // @visibleForTesting because it deliberately reaches inside the signing
    // path; named `debug` so it is obvious in a stack trace and greppable
    // before a release.
    'debugSendForgedClaim': 'test seam, named so it is findable',
  };

  test('no public runtime API is reachable only from tests', () {
    final source = read('app/lib/src/runtime/runtime.dart');

    // Members declared at one level of indentation inside the class.
    final declared = <String>{};
    final pattern = RegExp(
      r'^  (?:late\s+)?(?:final\s+)?[\w<>?,\s\[\]]*?\b(?:get\s+)?'
      r'([a-z]\w*)\s*[({=;]',
      multiLine: true,
    );
    for (final match in pattern.allMatches(source)) {
      final name = match.group(1)!;
      if (name.startsWith('_')) continue;
      // Declared a seam. The analyzer already stops the product calling it.
      if (source
          .substring(0, match.start)
          .trimRight()
          .endsWith('@visibleForTesting')) {
        continue;
      }
      // Dart keywords that the pattern can pick up as a name.
      if (const {
        'return',
        'if',
        'for',
        'while',
        'switch',
        'await',
        'case',
        'final',
        'const',
        'var',
        'new',
        'this',
        'super',
        'get',
        'set',
        'yield',
        'throw',
        'assert',
        'else',
        'try',
        'catch',
      }.contains(name)) {
        continue;
      }
      declared.add(name);
    }
    expect(
      declared,
      isNotEmpty,
      reason:
          'the declaration pattern stopped matching — fix it, do not '
          'leave this test passing vacuously',
    );

    // Every line of production Dart except the runtime's own declarations.
    final production = StringBuffer();
    for (final root in ['app/lib', 'packages']) {
      for (final entity in dirOf(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('/test/')) continue;
        if (!entity.path.contains('/lib/')) continue;
        production.writeln(entity.readAsStringSync());
      }
    }
    final all = production.toString();

    final unreachable = <String>[];
    for (final name in declared) {
      if (allowed.containsKey(name)) continue;
      final uses = RegExp(r'\b' + RegExp.escape(name) + r'\b').allMatches(all);
      // One match is the declaration itself. Anything more is a caller.
      if (uses.length <= 1) unreachable.add(name);
    }

    expect(
      unreachable..sort(),
      isEmpty,
      reason:
          'These exist, are tested, and nothing in the product calls them. '
          'Either wire each one up or delete it — a feature that cannot be '
          'invoked from the app is not a feature, and a tested one is worse '
          'than an untested one because it looks finished.',
    );
  });

  test('the allow-list is not quietly growing', () {
    // A guard whose exceptions expand is a guard being switched off one line
    // at a time.
    expect(allowed, hasLength(1));
  });
}
