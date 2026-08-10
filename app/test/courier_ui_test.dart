import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/runtime/runtime.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';

/// Carrying other people's mail, made visible.
///
/// The behaviour shipped before the interface did: this device would quietly
/// hold sealed messages for people it had never met, spend storage and battery
/// doing it, and never say so. Bounded and safe is not the same as consented
/// to, and a user who cannot see a thing cannot refuse it.
void main() {
  const status = MeshStatus(
    bluetoothOn: true,
    permissionsGranted: true,
    peersInRange: 2,
  );

  Widget settings({
    MeshStatus mesh = status,
    void Function(bool)? onCarryChanged,
    VoidCallback? onDropCarried,
  }) => MaterialApp(
    home: SettingsScreen(
      status: mesh,
      nickname: 'me',
      onCarryForOthersChanged: onCarryChanged,
      onDropCarriedMail: onDropCarried,
    ),
  );

  /// Scrolls the settings list until [finder] is on screen.
  ///
  /// Settings is a lazy ListView, so a row below the fold is not merely
  /// off-screen — it does not exist yet, and `find` reports nothing rather
  /// than reporting it is out of view.
  Future<void> reveal(WidgetTester tester, Finder finder) =>
      tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );

  group('the switch', () {
    testWidgets('says what carrying actually is', (tester) async {
      // "Couriers" means nothing to somebody who has not read the protocol
      // documentation, and this setting spends their battery.
      await tester.pumpWidget(settings());
      await reveal(tester, find.byKey(const Key('carry-for-others')));

      expect(find.byKey(const Key('carry-for-others')), findsOneWidget);
      expect(find.textContaining('for other people'), findsWidgets);
    });

    testWidgets('is on by default', (tester) async {
      // A mesh where everybody opts out delivers nothing to anybody absent.
      await tester.pumpWidget(settings());
      await reveal(tester, find.byKey(const Key('carry-for-others')));

      final row = tester.widget<SwitchListTile>(
        find.byKey(const Key('carry-for-others')),
      );
      expect(row.value, isTrue);
    });

    testWidgets('turning it off is reported', (tester) async {
      bool? chosen;
      await tester.pumpWidget(settings(onCarryChanged: (v) => chosen = v));
      await reveal(tester, find.byKey(const Key('carry-for-others')));

      await tester.tap(find.byKey(const Key('carry-for-others')));
      await tester.pump();

      expect(chosen, isFalse);
    });
  });

  group('what this device is holding', () {
    testWidgets('is shown as a count, not a list', (tester) async {
      // A list would be a list of who is talking to whom. The count is the
      // part the user needs — it is their storage.
      await tester.pumpWidget(settings(mesh: status.copyWith(carriedCount: 3)));
      await reveal(tester, find.byKey(const Key('drop-carried')));

      expect(find.textContaining('3'), findsWidgets);
    });

    testWidgets('carrying nothing offers nothing to drop', (tester) async {
      // A destructive button that does nothing still teaches the user to press
      // destructive buttons.
      await tester.pumpWidget(settings(onDropCarried: () {}));
      // Scroll past where it would be, so "not found" means absent rather
      // than merely not built yet.
      await reveal(tester, find.byKey(const Key('carry-for-others')));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pump();

      expect(find.byKey(const Key('drop-carried')), findsNothing);
    });

    testWidgets('dropping is offered only when there is something to drop', (
      tester,
    ) async {
      await tester.pumpWidget(
        settings(mesh: status.copyWith(carriedCount: 2), onDropCarried: () {}),
      );
      await reveal(tester, find.byKey(const Key('drop-carried')));

      expect(find.byKey(const Key('drop-carried')), findsOneWidget);
    });

    testWidgets('dropping asks first, and says what is lost', (tester) async {
      // Every one of these is somebody's undelivered message and none can be
      // recovered — the sender has no way to know it went.
      var dropped = false;
      await tester.pumpWidget(
        settings(
          mesh: status.copyWith(carriedCount: 2),
          onDropCarried: () => dropped = true,
        ),
      );
      await reveal(tester, find.byKey(const Key('drop-carried')));

      await tester.tap(find.byKey(const Key('drop-carried')));
      await tester.pumpAndSettle();

      expect(dropped, isFalse, reason: 'not until it is confirmed');
      expect(find.textContaining('never arrive'), findsOneWidget);
    });

    testWidgets('confirming drops it', (tester) async {
      var dropped = false;
      await tester.pumpWidget(
        settings(
          mesh: status.copyWith(carriedCount: 2),
          onDropCarried: () => dropped = true,
        ),
      );
      await reveal(tester, find.byKey(const Key('drop-carried')));

      await tester.tap(find.byKey(const Key('drop-carried')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drop-carried-confirm')));
      await tester.pumpAndSettle();

      expect(dropped, isTrue);
    });

    testWidgets('the switch being off still shows what is held', (
      tester,
    ) async {
      // Turning carrying off does not discard what is already here, and a user
      // who thinks it did would be wrong about where their storage went.
      await tester.pumpWidget(
        settings(
          mesh: status.copyWith(carryForOthers: false, carriedCount: 4),
          onDropCarried: () {},
        ),
      );
      await reveal(tester, find.byKey(const Key('drop-carried')));

      expect(find.byKey(const Key('drop-carried')), findsOneWidget);
    });
  });

  group('sending one by hand', () {
    Conversation outgoing({
      required MessageState state,
      ConversationKind kind = ConversationKind.direct,
    }) => Conversation(
      id: 'c1',
      title: 'Carol',
      kind: kind,
      messages: [
        Message(
          id: 'm1',
          body: 'meet at the gate',
          fromMe: true,
          state: state,
          sentAt: DateTime(2026, 7, 27, 9),
        ),
      ],
    );

    Future<void> show(
      WidgetTester tester,
      Conversation conversation, {
      void Function(Message)? onSendByCourier,
    }) => tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(
          conversation: conversation,
          onSendByCourier: onSendByCourier,
        ),
      ),
    );

    testWidgets('is offered on a message that has not got through', (
      tester,
    ) async {
      // The whole point of a courier is a recipient who is not here. This is
      // the only moment the user has any reason to want one.
      await show(
        tester,
        outgoing(state: MessageState.queued),
        onSendByCourier: (_) {},
      );

      expect(find.byKey(const Key('send-by-courier')), findsOneWidget);
    });

    testWidgets('is offered after a failure too', (tester) async {
      await show(
        tester,
        outgoing(state: MessageState.failed),
        onSendByCourier: (_) {},
      );

      expect(find.byKey(const Key('send-by-courier')), findsOneWidget);
    });

    testWidgets('is not offered once it has arrived', (tester) async {
      // Sending a second copy by hand would spend other people's storage to
      // deliver something already delivered.
      await show(
        tester,
        outgoing(state: MessageState.delivered),
        onSendByCourier: (_) {},
      );

      expect(find.byKey(const Key('send-by-courier')), findsNothing);
    });

    testWidgets('is never offered in a room', (tester) async {
      // An envelope is sealed to exactly one recipient's key. There is no such
      // thing as sealing one to a group, so offering it would be a lie.
      await show(
        tester,
        outgoing(state: MessageState.queued, kind: ConversationKind.room),
        onSendByCourier: (_) {},
      );

      expect(find.byKey(const Key('send-by-courier')), findsNothing);
    });

    testWidgets('is not offered on somebody else\'s message', (tester) async {
      await show(
        tester,
        Conversation(
          id: 'c1',
          title: 'Carol',
          kind: ConversationKind.direct,
          messages: [
            Message(
              id: 'm1',
              body: 'hello',
              fromMe: false,
              state: MessageState.delivered,
              sentAt: DateTime(2026, 7, 27, 9),
            ),
          ],
        ),
        onSendByCourier: (_) {},
      );

      expect(find.byKey(const Key('send-by-courier')), findsNothing);
    });

    testWidgets('tapping it hands the message up', (tester) async {
      Message? asked;
      await show(
        tester,
        outgoing(state: MessageState.queued),
        onSendByCourier: (m) => asked = m,
      );

      await tester.tap(find.byKey(const Key('send-by-courier')));
      await tester.pump();

      expect(asked?.id, 'm1');
    });

    testWidgets('nothing is offered when the app cannot do it', (tester) async {
      // No callback means the screen was built without a runtime behind it.
      await show(tester, outgoing(state: MessageState.queued));

      expect(find.byKey(const Key('send-by-courier')), findsNothing);
    });
  });

  group('why a courier was refused', () {
    test('every reason says what to do about it', () {
      // "Could not send" is the failure this replaces. Each of these is a
      // different situation with a different next move.
      for (final refusal in CourierRefusal.values) {
        expect(refusal.explanation, isNotEmpty);
        expect(
          refusal.explanation,
          isNot(contains('courier')),
          reason: 'user-facing text must not use the protocol word',
        );
      }
    });
  });

  group('a message somebody carried here', () {
    Conversation withMessage({required bool viaCourier}) => Conversation(
      id: 'c1',
      title: 'Carol',
      kind: ConversationKind.direct,
      messages: [
        Message(
          id: 'm1',
          body: 'meet at the gate',
          fromMe: false,
          state: MessageState.delivered,
          sentAt: DateTime(2026, 7, 27, 9),
          viaCourier: viaCourier,
        ),
      ],
    );

    testWidgets('says so', (tester) async {
      // It may have been written hours ago by somebody still nowhere near, and
      // the obvious reply — sending one straight back — will not reach them
      // the same way.
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationScreen(conversation: withMessage(viaCourier: true)),
        ),
      );

      expect(find.byKey(const Key('carried-chip')), findsOneWidget);
    });

    testWidgets('an ordinary message says nothing', (tester) async {
      // If every message carries a badge the badge stops being read.
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationScreen(
            conversation: withMessage(viaCourier: false),
          ),
        ),
      );

      expect(find.byKey(const Key('carried-chip')), findsNothing);
    });

    testWidgets('explains itself without jargon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationScreen(conversation: withMessage(viaCourier: true)),
        ),
      );

      final label = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const Key('carried-chip')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(label.message, isNot(contains('courier')));
      expect(label.message, contains('carried'));
    });
  });
}
