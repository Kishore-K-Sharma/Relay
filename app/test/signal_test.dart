import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/theme.dart';
import 'package:relay_app/src/ui/widgets.dart';

import 'support/screen_sizes.dart';

/// How strong the link to somebody is.
///
/// Radio strength is the difference between "they are in this room" and "they
/// are somewhere in the building", which in a crowd is the thing the user
/// actually wants to know. The number itself is meaningless to anybody but a
/// radio engineer, so it is shown as bars.
void main() {
  group('bands', () {
    test('a strong signal is close', () {
      // dBm is negative and closer to zero is stronger.
      expect(SignalStrength.fromRssi(-40), SignalStrength.strong);
    });

    test('a weak signal is far', () {
      expect(SignalStrength.fromRssi(-95), SignalStrength.weak);
    });

    test('the bands are ordered', () {
      final bars = <int>[
        for (final rssi in [-30, -60, -75, -95])
          SignalStrength.fromRssi(rssi)!.bars,
      ];

      final descending = List<int>.of(bars)..sort((a, b) => b.compareTo(a));
      expect(bars, orderedEquals(descending));
    });

    test('an unknown strength is not guessed', () {
      // Wi-Fi peers and relayed peers have no RSSI at all. Inventing one would
      // put a confident bar count on a link nobody measured.
      expect(SignalStrength.fromRssi(null), isNull);
    });

    test('an absurd reading is clamped rather than trusted', () {
      // Some chipsets report 127 for "unknown".
      expect(SignalStrength.fromRssi(127), SignalStrength.strong);
      expect(SignalStrength.fromRssi(-200), SignalStrength.weak);
    });
  });

  group('the peer model', () {
    test('carries the strength when there is one', () {
      expect(
        const Peer(id: 'p', nickname: 'sara', hops: 1, rssi: -45).signal,
        SignalStrength.strong,
      );
    });

    test('has none for a peer that is out of range', () {
      expect(const Peer(id: 'p', nickname: 'sara', hops: null).signal, isNull);
    });

    test('has none for a peer several hops away', () {
      // The RSSI of a relayed peer would be the strength of the link to
      // whoever passed it on, which is a different fact about a different
      // person. Showing it beside their name would be a lie.
      expect(
        const Peer(id: 'p', nickname: 'sara', hops: 3, rssi: -45).signal,
        isNull,
      );
    });
  });

  group('the indicator', () {
    Future<void> show(WidgetTester tester, Peer peer) async {
      useScreen(tester, Screens.phone);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: Center(child: SignalBars(peer: peer)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows bars for a direct peer', (tester) async {
      await show(
        tester,
        const Peer(id: 'p', nickname: 'sara', hops: 1, rssi: -45),
      );

      expect(find.byKey(const Key('signal-bars')), findsOneWidget);
    });

    testWidgets('shows nothing when the strength is unknown', (tester) async {
      // Blank, not zero bars. Zero bars means "measured, and bad".
      await show(tester, const Peer(id: 'p', nickname: 'sara', hops: 1));

      expect(find.byKey(const Key('signal-bars')), findsNothing);
    });

    testWidgets('describes itself to a screen reader', (tester) async {
      // Bars are the one thing in this app with no text at all.
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const Peer(id: 'p', nickname: 'sara', hops: 1, rssi: -45),
      );

      expect(
        find.bySemanticsLabel(RegExp('signal', caseSensitive: false)),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
