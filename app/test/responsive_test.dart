import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/responsive.dart';

import 'support/screen_sizes.dart';

/// Where the layout changes shape, and why.
///
/// The app runs on a 320-point phone and on a tablet in landscape. Those are
/// not the same screen with different numbers in it: one wants a single column
/// and a back button, the other wants both panes at once. Everything here is
/// about the boundary between them being a decision rather than an accident.
void main() {
  Future<Size> sizeSeenBy(WidgetTester tester, Size surface) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: SizedBox.expand(key: Key('surface'))),
    );
    // Pumped again: the resize lands on the next frame, so reading during the
    // first build reports the default surface and every size assertion below
    // would be measuring 800x600 while claiming to measure a phone.
    await tester.pump();
    return tester.getSize(find.byKey(const Key('surface')));
  }

  group('breakpoints', () {
    test('a phone is compact', () {
      expect(Breakpoint.of(320), Breakpoint.compact);
      expect(Breakpoint.of(390), Breakpoint.compact);
      expect(Breakpoint.of(599), Breakpoint.compact);
    });

    test('a small tablet or a phone in landscape is medium', () {
      expect(Breakpoint.of(600), Breakpoint.medium);
      expect(Breakpoint.of(839), Breakpoint.medium);
    });

    test('a large tablet or a desktop window is expanded', () {
      expect(Breakpoint.of(840), Breakpoint.expanded);
      expect(Breakpoint.of(1920), Breakpoint.expanded);
    });

    test('only expanded is wide enough for both panes', () {
      // A medium window is wide enough to look roomy and too narrow to hold a
      // conversation beside a list without squeezing both.
      expect(Breakpoint.compact.isWideEnoughForTwoPanes, isFalse);
      expect(Breakpoint.medium.isWideEnoughForTwoPanes, isFalse);
      expect(Breakpoint.expanded.isWideEnoughForTwoPanes, isTrue);
    });

    test('a zero or negative width does not throw', () {
      // Happens for one frame during startup and on some desktop resizes.
      expect(Breakpoint.of(0), Breakpoint.compact);
      expect(Breakpoint.of(-1), Breakpoint.compact);
    });
  });

  group('two panes', () {
    test('need height as well as width', () {
      // A phone in landscape is wider than any breakpoint table's threshold
      // and useless for two panes: raising the keyboard leaves about 150
      // points for the conversation.
      expect(Panes.twoIn(const Size(1024, 768)), isTrue);
      expect(Panes.twoIn(const Size(844, 390)), isFalse);
    });

    test('a tall narrow window stays one pane', () {
      expect(Panes.twoIn(const Size(500, 1200)), isFalse);
    });

    test('the height floor is where a keyboard still leaves room', () {
      expect(Panes.twoIn(const Size(900, Panes.minHeight)), isTrue);
      expect(Panes.twoIn(const Size(900, Panes.minHeight - 1)), isFalse);
    });
  });

  group('readable width', () {
    testWidgets('long text stops before it becomes unreadable', (tester) async {
      // A line that runs the full width of a desktop window is physically hard
      // to read: the eye loses the start of the next line.
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReadableWidth(child: SizedBox.expand(key: Key('content'))),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const Key('content'))).width,
        lessThanOrEqualTo(ReadableWidth.maximum),
      );
    });

    testWidgets('a scrollable child still gets the full height', (
      tester,
    ) async {
      // The failure this guards against is silent and total: given loose
      // constraints a scroll view collapses to zero height, and every control
      // inside it is painted but cannot be tapped. Nothing looks wrong.
      useScreen(tester, Screens.phone);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // A bottom bar, because that is what changes the body's
            // constraints and is exactly the arrangement that collapsed.
            bottomNavigationBar: const SizedBox(height: 60),
            body: ReadableWidth(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < 30; i++) const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getSize(find.byType(SingleChildScrollView)).height,
        greaterThan(0),
      );
    });

    testWidgets('a bottom bar still sizes to its content', (tester) async {
      // The opposite failure to the one above, and caused by fixing that one
      // carelessly: forcing the height makes a bottom bar as tall as the whole
      // window, leaving the body nothing.
      useScreen(tester, Screens.phone);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            bottomNavigationBar: ReadableWidth(
              child: SizedBox(height: 60, key: Key('bar')),
            ),
            body: SizedBox.expand(key: Key('body')),
          ),
        ),
      );
      await tester.pump();

      expect(tester.getSize(find.byKey(const Key('bar'))).height, 60);
      expect(
        tester.getSize(find.byKey(const Key('body'))).height,
        greaterThan(400),
      );
    });

    testWidgets('a phone uses every point it has', (tester) async {
      // Capping on a small screen would waste the only space there is.
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReadableWidth(child: SizedBox.expand(key: Key('content'))),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('content'))).width, 360);
    });
  });

  group('text scale', () {
    testWidgets('a user\'s larger text setting is honoured', (tester) async {
      // Accessibility settings are not a suggestion. Ignoring them outright is
      // the most common way an app becomes unusable for somebody.
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: AppTextScale(child: child!),
          ),
          home: const Scaffold(body: Text('hello', key: Key('t'))),
        ),
      );

      final scaler = tester.widget<Text>(find.byKey(const Key('t'))).textScaler;
      expect(scaler, isNull, reason: 'the widget must not override it itself');

      final applied = MediaQuery.of(
        tester.element(find.byKey(const Key('t'))),
      ).textScaler;
      expect(applied.scale(10), greaterThan(10));
    });

    testWidgets('an extreme scale is clamped rather than breaking', (
      tester,
    ) async {
      // Some platforms allow 3x and more. Past a point every row overflows and
      // the app shows nothing but overflow stripes, which helps nobody.
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(4)),
            child: AppTextScale(child: child!),
          ),
          home: const Scaffold(body: Text('hello', key: Key('t'))),
        ),
      );

      final applied = MediaQuery.of(
        tester.element(find.byKey(const Key('t'))),
      ).textScaler;
      expect(applied.scale(10), lessThanOrEqualTo(10 * AppTextScale.maximum));
      expect(
        applied.scale(10),
        greaterThan(10),
        reason: 'clamping must not undo the user\'s choice entirely',
      );
    });
  });

  group('the test surface itself', () {
    testWidgets('a narrow phone really is narrow', (tester) async {
      // Guards the harness: if setSurfaceSize stops working, every layout test
      // below silently passes at the default 800x600.
      expect(
        await sizeSeenBy(tester, const Size(320, 640)),
        const Size(320, 640),
      );
    });
  });
}
