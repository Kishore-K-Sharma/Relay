import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/brand.dart';
import 'package:relay_app/src/ui/screens/onboarding_screen.dart';

/// The mark as it appears inside the app.
///
/// Drawn rather than loaded. An app icon is an export; this is the same
/// geometry as a painter, so it stays sharp at any size, costs no asset, and
/// takes its colour from the theme instead of being one green PNG sitting on a
/// white screen in light mode.
void main() {
  Widget wrap(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5FD97A),
            brightness: brightness,
          ),
        ),
        home: Scaffold(body: Center(child: child)),
      );

  /// The colour the mark would actually paint with under [brightness].
  Future<Color> paintedColour(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    await tester.pumpWidget(
      wrap(const RelayMark(size: 96), brightness: brightness),
    );
    // MaterialApp wraps its theme in an AnimatedTheme, so on the first frame
    // after a theme change the tree is still showing the previous one. Reading
    // without settling compares dark against dark and passes nothing.
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(RelayMark));
    return const RelayMark(size: 96).resolveColor(context);
  }

  testWidgets('takes exactly the size it is given', (tester) async {
    await tester.pumpWidget(wrap(const RelayMark(size: 96)));

    expect(tester.getSize(find.byType(RelayMark)), const Size(96, 96));
  });

  testWidgets('is announced, not left as a stray graphic', (tester) async {
    // A screen reader landing on an unlabelled CustomPaint says nothing at
    // all, which on the first screen of the app is disorienting.
    await tester.pumpWidget(wrap(const RelayMark(size: 96)));

    expect(find.bySemanticsLabel('Relay'), findsOneWidget);
  });

  testWidgets('follows the theme rather than shipping one green', (
    tester,
  ) async {
    // One fixed colour for both themes is the usual way a logo ends up
    // unreadable in whichever theme it was not designed against.
    final onDark = await paintedColour(tester, Brightness.dark);
    final onLight = await paintedColour(tester, Brightness.light);

    expect(onDark, isNot(onLight));
  });

  testWidgets('an explicit colour wins over the theme', (tester) async {
    // Needed wherever it sits on a fixed surface regardless of the user's
    // choice — a splash, or a dark card in a light app.
    await tester.pumpWidget(wrap(const RelayMark(size: 96)));
    const red = Color(0xFFFF0000);

    expect(
      const RelayMark(
        size: 96,
        color: red,
      ).resolveColor(tester.element(find.byType(RelayMark))),
      red,
    );
  });

  testWidgets('onboarding leads with the mark, beside the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        OnboardingScreen(
          outstanding: const [SetupStep.permissions],
          onResolve: (_) {},
        ),
      ),
    );

    expect(find.byType(RelayMark), findsOneWidget);

    final mark = tester.getRect(find.byType(RelayMark));
    final name = tester.getRect(find.text('Relay'));
    // Mark left of the wordmark, on the same line — the arrangement the
    // printed lockup uses. Stacking them instead costs 72 points of fixed
    // header, which is enough to overflow the smallest phone at 1.6x text.
    expect(mark.right, lessThanOrEqualTo(name.left));
    expect(mark.center.dy, closeTo(name.center.dy, 8));
  });
}
