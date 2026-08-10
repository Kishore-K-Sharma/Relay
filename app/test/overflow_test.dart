import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/ui/screens/diagnostics_screen.dart';
import 'package:relay_app/src/ui/screens/home_screen.dart';
import 'package:relay_app/src/ui/screens/join_room_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/screens/onboarding_screen.dart';
import 'package:relay_app/src/ui/responsive.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';
import 'package:transport_ble/transport_ble.dart';

import 'support/screen_sizes.dart';

/// Every screen, on the smallest phone, at the largest text the app allows.
///
/// This is the test that catches the thing users actually report: a row of
/// yellow-and-black stripes where a button should be. Flutter reports an
/// overflow as an exception during paint, so a screen that overflows fails here
/// rather than in somebody's hands.
///
/// The matrix is deliberately every screen rather than a sample. Overflow is
/// not a property of a widget, it is a property of a widget *in a size*, and
/// the one screen nobody thought to check is the one that breaks.
void main() {
  final peers = [
    const Peer(
      id: 'p1',
      // A long name in a script that is wide when rendered. Truncation is the
      // app's job, not the user's.
      nickname: 'Sudhanshu Vishwakarma',
      hops: 1,
      trust: TrustBadge.verified,
      isFavourite: true,
    ),
    const Peer(id: 'p2', nickname: 'ज़ेहरा', hops: 3),
    const Peer(id: 'p3', nickname: 'Out of range friend', hops: null),
  ];

  final conversations = [
    Conversation(
      id: 'c1',
      title: 'A conversation with a very long title indeed',
      kind: ConversationKind.direct,
      peer: peers.first,
      unread: 12,
      messages: [
        Message(
          id: 'm1',
          body: 'Short.',
          fromMe: false,
          state: MessageState.delivered,
          sentAt: DateTime(2026, 7, 26, 12),
        ),
        Message(
          id: 'm2',
          body:
              'A much longer message that has to wrap onto several lines '
              'even on a wide screen, and on a narrow one becomes a paragraph.',
          fromMe: true,
          state: MessageState.expired,
          sentAt: DateTime(2026, 7, 26, 12, 1),
        ),
        Message(
          id: 'm3',
          body: 'voice',
          fromMe: false,
          state: MessageState.read,
          sentAt: DateTime(2026, 7, 26, 12, 2),
          voiceDurationMs: 4200,
        ),
      ],
    ),
    const Conversation(
      id: 'c2',
      title: 'Rooftop',
      kind: ConversationKind.room,
      memberCount: 14,
      messages: [],
    ),
  ];

  const status = MeshStatus(
    bluetoothOn: false,
    permissionsGranted: true,
    peersInRange: 3,
    stealthMode: true,
    wifiAvailable: true,
    wifiPeers: 2,
  );

  final screens = <String, Widget Function()>{
    'home': () => HomeScreen(
      status: status,
      peers: peers,
      conversations: conversations,
      onOpenConversation: (_) {},
      onJoinRoom: () {},
      onOpenPairing: () {},
    ),
    'home empty': () =>
        const HomeScreen(status: status, peers: [], conversations: []),
    'conversation': () => ConversationScreen(conversation: conversations.first),
    'room': () => ConversationScreen(
      conversation: conversations.last,
      mentionCandidates: const ['sara', 'ज़ेहरा', 'someone-with-a-long-name'],
    ),
    'settings': () => SettingsScreen(
      status: status,
      nickname: 'a rather long nickname',
      powerMode: PowerMode.balanced,
      blocked: [(nickname: 'someone', blockedAt: DateTime(2026, 7, 20))],
      onPowerModeChanged: (_) {},
      onStealthChanged: (_) {},
      onPanicWipe: () {},
      onOpenDiagnostics: () {},
    ),
    'join room': () => const JoinRoomScreen(),
    'onboarding': () =>
        const OnboardingScreen(outstanding: SetupStep.values, onResolve: _noop),
    'diagnostics': () => const DiagnosticsScreen(
      status: status,
      stats: BleRelayStats(
        framesReceived: 1200,
        framesRelayed: 340,
        framesDropped: 12,
        framesSuppressed: 88,
        storedForForward: 3,
        inboxDepth: 2,
      ),
      outboxDepth: 4,
      log: [],
    ),
  };

  /// Renders [child] at [size] with [scale] text and returns any layout error.
  Future<Object?> render(
    WidgetTester tester,
    Widget child, {
    required Size size,
    required double scale,
  }) async {
    useScreen(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: AppTextScale(child: inner!),
        ),
        home: child,
      ),
    );
    await tester.pump();
    return tester.takeException();
  }

  for (final entry in screens.entries) {
    group(entry.key, () {
      testWidgets('fits the smallest phone', (tester) async {
        expect(
          await render(
            tester,
            entry.value(),
            size: Screens.narrowPhone,
            scale: 1,
          ),
          isNull,
        );
      });

      testWidgets('fits the smallest phone at the largest text', (
        tester,
      ) async {
        // The scale the app clamps to. If a screen cannot survive it, either
        // the screen changes or the clamp does — but silently overflowing is
        // not one of the options.
        expect(
          await render(
            tester,
            entry.value(),
            size: Screens.narrowPhone,
            scale: AppTextScale.maximum,
          ),
          isNull,
        );
      });

      testWidgets('fits a phone in landscape', (tester) async {
        // The short dimension is 390 points, most of which a keyboard takes.
        expect(
          await render(
            tester,
            entry.value(),
            size: Screens.phoneLandscape,
            scale: 1,
          ),
          isNull,
        );
      });

      testWidgets('fits a large tablet', (tester) async {
        expect(
          await render(
            tester,
            entry.value(),
            size: Screens.largeTablet,
            scale: 1,
          ),
          isNull,
        );
      });
    });
  }

  testWidgets('the guard would notice an overflow', (tester) async {
    // Proves the matrix above is doing something. A test that can only pass is
    // not a test.
    final overflowing = Row(
      children: [
        for (var i = 0; i < 40; i++) const SizedBox(width: 100, height: 10),
      ],
    );

    expect(
      await render(
        tester,
        Scaffold(body: overflowing),
        size: Screens.narrowPhone,
        scale: 1,
      ),
      isNotNull,
    );
  });
}

/// A no-op resolver, so the onboarding screen can be built as a const.
Future<void> _noop(SetupStep step) async {}
