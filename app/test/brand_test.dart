import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Five strings are load-bearing cryptography and must never be edited.
///
/// `relay-addr-v1`, `relay-safety-v1`, `relay-room-v1`, `relay-roomid-v1` and
/// `relay-courier-tag-v1` are domain separators: each is hashed into every
/// address, every safety number, every room code and every courier tag. They
/// read like ordinary descriptive strings, which is the problem — editing one
/// for tidiness compiles, passes a smoke test, and changes the identity of
/// every user in the world. Old contacts stop verifying, safety numbers all
/// appear to have changed, and it looks exactly like an attack.
///
/// They end in `-v1` because that is how a domain-separation constant is
/// supposed to be treated: frozen, and superseded by `-v2` if it ever has to
/// move. So the test is deliberately blunt. If you are here because it failed,
/// the answer is almost certainly to put the string back.
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

  /// Absolute path for a repo-relative one, file or directory.
  String resolve(String path) {
    for (var dir = Directory.current; ; dir = dir.parent) {
      final candidate = '${dir.path}/$path';
      if (FileSystemEntity.typeSync(candidate) !=
          FileSystemEntityType.notFound) {
        return candidate;
      }
      if (dir.path == dir.parent.path) {
        fail('cannot find $path from ${Directory.current.path}');
      }
    }
  }

  group('the domain separators are frozen', () {
    const pinned = <String, List<String>>{
      'packages/core_identity/lib/src/identity.dart': [
        "'relay-addr-v1'",
        "'relay-safety-v1'",
      ],
      'packages/core_identity/lib/src/room_code.dart': [
        "'relay-room-v1'",
        "'relay-roomid-v1'",
      ],
      'packages/core_protocol/lib/src/courier.dart': ["'relay-courier-tag-v1'"],
    };

    for (final entry in pinned.entries) {
      test('${entry.key.split('/').last} keeps its domain separators', () {
        final source = read(entry.key);
        for (final constant in entry.value) {
          expect(
            source,
            contains(constant),
            reason:
                '$constant is hashed into user-visible identities. Changing it '
                'silently invalidates every address and safety number already '
                'in the wild. Add a -v2 constant instead of editing this one.',
          );
        }
      });
    }
  });

  group('the app identifies itself as Relay', () {
    test('Android shows Relay on the home screen', () {
      expect(
        read('app/android/app/src/main/AndroidManifest.xml'),
        contains('android:label="Relay"'),
      );
    });

    test('iOS shows Relay on the home screen', () {
      // CFBundleName is what springboard prints under the icon, and it is
      // truncated past about 12 characters — worth pinning, because a display
      // name that silently becomes "Relay App…" is the sort of thing nobody
      // notices until the store listing screenshots come back.
      final plist = read('app/ios/Runner/Info.plist');
      expect(plist, contains('<string>Relay</string>'));
    });

    test('both platforms ship under the same owned identifier', () {
      // Pinned because it is not fixable after the fact: an application id is
      // permanent once a build reaches a store, and it must be under a domain
      // the publisher actually owns — here kishorek.dev, reversed.
      //
      // Both platforms must agree. They are independent settings in unrelated
      // files, and a mismatch is invisible until two stores disagree about what
      // the app is.
      expect(
        read('app/android/app/build.gradle.kts'),
        contains('applicationId = "dev.kishorek.relay"'),
      );
      expect(
        read('app/ios/Runner.xcodeproj/project.pbxproj'),
        contains('PRODUCT_BUNDLE_IDENTIFIER = dev.kishorek.relay;'),
      );
    });
  });

  group('the icons are actually there', () {
    /// Resolves a repo-relative path, or fails saying where it looked.
    File file(String path) {
      for (var dir = Directory.current; ; dir = dir.parent) {
        final candidate = File('${dir.path}/$path');
        if (candidate.existsSync()) return candidate;
        if (dir.path == dir.parent.path) {
          fail('$path is missing — the icon set is generated from brand/');
        }
      }
    }

    test('iOS has the store icon', () {
      // A missing 1024 icon is not caught by a build. It is caught by App
      // Store Connect rejecting the upload, after the build has been made.
      expect(
        file(
          'app/ios/Runner/Assets.xcassets/AppIcon.appiconset/'
          'Icon-App-1024x1024@1x.png',
        ).lengthSync(),
        greaterThan(0),
      );
    });

    test('Android has every launcher layer at every density', () {
      for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        for (final layer in [
          'ic_launcher',
          'ic_launcher_foreground',
          // Without this one the icon stays a bright green tile on a phone
          // where the user has themed every other icon to their wallpaper.
          'ic_launcher_monochrome',
        ]) {
          expect(
            file(
              'app/android/app/src/main/res/mipmap-$density/$layer.png',
            ).lengthSync(),
            greaterThan(0),
            reason: '$layer missing at $density',
          );
        }
      }
    });

    test('every Swift file the Xcode project declares exists at its path', () {
      // Renaming a Swift file on disk does not rename it in project.pbxproj,
      // and nothing in the Dart toolchain notices. The first sign is the iOS
      // build failing on a machine that can run one.
      //
      // This resolves each path the way Xcode does — through the groups that
      // enclose it — rather than asking whether a file by that name exists
      // somewhere. Two weaker versions of this test already let real breakage
      // through. One collected bare filenames, and passed while all nine mesh
      // sources were declared at `Runner/Ble/...` inside a group that already
      // carries `path = Runner`; Xcode resolved that to `Runner/Runner/Ble/...`
      // and the build could not start. The names were right the whole time.
      // The next version searched a handful of plausible roots, and passed on
      // the same bug for the same reason: `app/ios/` + `Runner/Ble/x.swift`
      // happens to hit the real file. Only the enclosing group knows what a
      // path means.
      final project = read('app/ios/Runner.xcodeproj/project.pbxproj');

      // id -> declared path, for every file reference naming a Swift file.
      final files = <String, String>{
        for (final m in RegExp(
          r'([0-9A-Za-z]+) /\*.*?\*/ = \{isa = PBXFileReference;[^}]*?'
          r'path = ([^;]+\.swift);',
        ).allMatches(project))
          m[1]!: m[2]!,
      };
      expect(files, isNotEmpty, reason: 'the file-reference pattern broke');

      // id -> (own path segment, children). A group without a path contributes
      // nothing to the prefix but still passes its parent's down.
      final groupPath = <String, String>{};
      final parentOf = <String, String>{};
      final groups = RegExp(
        r'([0-9A-Za-z]+) /\*.*?\*/ = \{\s*isa = PBXGroup;\s*'
        r'children = \(([^)]*)\);([^}]*)\}',
      ).allMatches(project);
      expect(groups, isNotEmpty, reason: 'the group pattern broke');

      for (final group in groups) {
        final id = group[1]!;
        final own = RegExp(r'path = ([^;]+);').firstMatch(group[3]!);
        if (own != null) groupPath[id] = own[1]!;
        for (final child in RegExp(
          r'([0-9A-Za-z]+) /\*',
        ).allMatches(group[2]!)) {
          parentOf[child[1]!] = id;
        }
      }

      final unresolved = <String>[];
      for (final entry in files.entries) {
        final segments = <String>[entry.value];
        for (var at = parentOf[entry.key]; at != null; at = parentOf[at]) {
          final segment = groupPath[at];
          if (segment != null) segments.insert(0, segment);
        }
        final resolved =
            '${Directory(resolve('app/ios')).path}/'
            '${segments.join('/')}';
        if (!File(resolved).existsSync()) {
          unresolved.add(segments.join('/'));
        }
      }

      expect(
        unresolved,
        isEmpty,
        reason: 'declared in project.pbxproj but absent at the resolved path',
      );
    });

    test('neither platform launches white', () {
      // The launch window is drawn by the OS before Flutter exists, so it
      // cannot know the user picked dark. Flutter's template leaves it plain
      // white, and this app opens dark by default *because* a bright screen at
      // night ruins night vision and marks somebody out. A full-screen white
      // flash on the way in defeats that, however brief it is.
      for (final path in [
        'app/android/app/src/main/res/drawable/launch_background.xml',
        'app/android/app/src/main/res/drawable-v21/launch_background.xml',
      ]) {
        final drawable = read(path);
        expect(
          drawable,
          isNot(contains('@android:color/white')),
          reason: '$path is still the stock white splash',
        );
        expect(drawable, contains('@drawable/launch_mark'));
      }

      // drawable-v21 wins on every API this app supports, so a fix applied to
      // only one of the two is a fix that never runs.
      expect(
        read('app/android/app/src/main/res/drawable/launch_background.xml'),
        read('app/android/app/src/main/res/drawable-v21/launch_background.xml'),
      );

      // iOS: a literal white in the storyboard cannot follow the system
      // appearance. A named colour can.
      final storyboard = read(
        'app/ios/Runner/Base.lproj/LaunchScreen.storyboard',
      );
      expect(
        storyboard,
        contains('<color key="backgroundColor" name="LaunchBackground"/>'),
      );
    });

    test('the launch palette has a dark variant on both platforms', () {
      expect(
        read('app/android/app/src/main/res/values-night/launch_colors.xml'),
        contains('launch_background'),
      );
      // Without the dark appearance entries the light mark — mixed for a white
      // page — is what gets drawn on the near-black launch background.
      expect(
        read(
          'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json',
        ),
        contains('"value" : "dark"'),
      );
      expect(
        read(
          'app/ios/Runner/Assets.xcassets/LaunchBackground.colorset/'
          'Contents.json',
        ),
        contains('"value" : "dark"'),
      );
    });

    test('the source artwork is kept, not just the exports', () {
      // Every PNG above is generated from these. Losing them means the next
      // icon change is a redraw rather than a re-export.
      for (final source in [
        'brand/relay-mark.svg',
        'brand/relay-foreground.svg',
        'brand/relay-mark-mono.svg',
        'brand/relay-mark-on-dark.svg',
        'brand/relay-mark-on-light.svg',
      ]) {
        expect(file(source).lengthSync(), greaterThan(0));
      }
    });
  });
}
