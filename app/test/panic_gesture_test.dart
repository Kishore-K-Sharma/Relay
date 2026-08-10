import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/widgets.dart';

/// The emergency wipe gesture.
///
/// Three taps on the title erases the phone. There is deliberately no
/// confirmation: the situation this exists for is somebody reaching for your
/// phone, and a dialog in that moment is the same as no feature at all.
///
/// Because of that it is off until the user turns it on, and the taps have to
/// be quick — a slow triple-tap is somebody fidgeting, not an emergency.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required VoidCallback onTriggered,
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PanicTapTarget(
          enabled: enabled,
          onTriggered: onTriggered,
          child: const Text('Relay'),
        ),
      ),
    ),
  );

  Future<void> tap(
    WidgetTester tester, {
    int times = 3,
    int gapMs = 100,
  }) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(find.text('Relay'));
      await tester.pump(Duration(milliseconds: gapMs));
    }
  }

  testWidgets('three quick taps fire it', (tester) async {
    var fired = 0;
    await pump(tester, onTriggered: () => fired++);

    await tap(tester);

    expect(fired, 1);
  });

  testWidgets('two taps do nothing', (tester) async {
    var fired = 0;
    await pump(tester, onTriggered: () => fired++);

    await tap(tester, times: 2);

    expect(fired, 0);
  });

  testWidgets('three slow taps do nothing', (tester) async {
    // Somebody fidgeting with the screen must not erase their phone.
    var fired = 0;
    await pump(tester, onTriggered: () => fired++);

    await tap(tester, gapMs: 900);

    expect(fired, 0);
  });

  testWidgets('it does nothing at all when switched off', (tester) async {
    var fired = 0;
    await pump(tester, onTriggered: () => fired++, enabled: false);

    await tap(tester);

    expect(fired, 0);
  });

  testWidgets('it fires once, not once per extra tap', (tester) async {
    // Erasing is already done after the third tap. A fourth must not run the
    // whole thing again against an empty database.
    var fired = 0;
    await pump(tester, onTriggered: () => fired++);

    await tap(tester, times: 5);

    expect(fired, 1);
  });

  testWidgets('the count resets, so it can be used twice', (tester) async {
    var fired = 0;
    await pump(tester, onTriggered: () => fired++);

    await tap(tester);
    await tester.pump(const Duration(seconds: 2));
    await tap(tester);

    expect(fired, 2);
  });
}
