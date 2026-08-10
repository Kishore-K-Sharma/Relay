import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real screen sizes, in logical points.
///
/// Named rather than inlined so a layout assertion says which device it is
/// about. The narrow phone is deliberately the smallest Flutter supports in
/// practice — if a row fits there it fits everywhere.
abstract final class Screens {
  /// The smallest phone still in use.
  static const narrowPhone = Size(320, 568);

  static const phone = Size(390, 844);
  static const phoneLandscape = Size(844, 390);
  static const tablet = Size(1024, 768);
  static const largeTablet = Size(1366, 1024);
  static const desktop = Size(1600, 1000);
}

/// Resizes the test window and keeps it that way for the test.
///
/// Sets [devicePixelRatio] explicitly. Without it the ratio is 3.0 and
/// `setSurfaceSize` quietly fails to change the logical size at all — every
/// layout test then passes at the default 800x600 while claiming to be
/// measuring a tablet, which is worse than not testing at all.
void useScreen(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = size;
  addTearDown(tester.view.reset);
}
