import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/home_screen.dart';
import 'package:relay_app/src/domain/models.dart';

import 'support/screen_sizes.dart';

/// One screen at a time, or two side by side.
///
/// A phone can only usefully show one thing; a tablet in landscape showing one
/// thing wastes most of the glass. The same app has to do both, and — the part
/// that is easy to get wrong — has to survive the user rotating the device
/// mid-conversation without losing their place.
void main() {
  final conversations = [
    Conversation(
      id: 'c1',
      title: 'Sara',
      kind: ConversationKind.direct,
      messages: [
        Message(
          id: 'm1',
          body: 'by the gate',
          fromMe: false,
          state: MessageState.delivered,
          sentAt: DateTime(2026, 7, 26, 12),
        ),
      ],
    ),
    const Conversation(
      id: 'c2',
      title: 'Rooftop',
      kind: ConversationKind.room,
      messages: [],
    ),
  ];

  const status = MeshStatus(
    bluetoothOn: true,
    permissionsGranted: true,
    peersInRange: 2,
  );

  Future<void> show(WidgetTester tester, Size size, {String? selected}) async {
    useScreen(tester, size);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          status: status,
          peers: const [],
          conversations: conversations,
          selectedConversationId: selected,
          detail: selected == null
              ? null
              : Scaffold(
                  key: const Key('detail'),
                  body: Text('detail for $selected'),
                ),
        ),
      ),
    );
    await tester.pump();
  }

  const phone = Screens.phone;
  const tablet = Screens.largeTablet;

  group('on a phone', () {
    testWidgets('there is no second pane', (tester) async {
      await show(tester, phone, selected: 'c1');

      expect(find.byKey(const Key('detail')), findsNothing);
      expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    });

    testWidgets('conversations are opened by pushing a screen', (tester) async {
      await show(tester, phone);

      expect(
        HomeScreen.opensByPushing(tester.element(find.byType(HomeScreen))),
        isTrue,
      );
    });
  });

  group('on a tablet', () {
    testWidgets('the list and the conversation are both on screen', (
      tester,
    ) async {
      await show(tester, tablet, selected: 'c1');

      expect(find.byKey(const Key('conversation-list')), findsOneWidget);
      expect(find.byKey(const Key('detail')), findsOneWidget);
    });

    testWidgets('the list keeps a sensible width instead of half the glass', (
      tester,
    ) async {
      // A 600-point list of one-line rows beside a 600-point conversation is
      // two columns of mostly whitespace.
      await show(tester, tablet, selected: 'c1');

      final listWidth = tester
          .getSize(find.byKey(const Key('conversation-list')))
          .width;
      expect(listWidth, lessThanOrEqualTo(HomeScreen.listPaneWidth));
      expect(listWidth, greaterThan(280));
    });

    testWidgets('nothing selected shows a prompt, not an empty half', (
      tester,
    ) async {
      await show(tester, tablet);

      expect(find.byKey(const Key('no-conversation-selected')), findsOneWidget);
    });

    testWidgets('conversations are opened in place, not pushed', (
      tester,
    ) async {
      await show(tester, tablet);

      expect(
        HomeScreen.opensByPushing(tester.element(find.byType(HomeScreen))),
        isFalse,
      );
    });
  });

  group('rotating', () {
    testWidgets('a tablet turned upright drops to one pane', (tester) async {
      await show(tester, tablet, selected: 'c1');
      expect(find.byKey(const Key('detail')), findsOneWidget);

      tester.view.physicalSize = phone;
      await tester.pump();

      expect(find.byKey(const Key('detail')), findsNothing);
    });

    testWidgets('a phone turned sideways is still one pane', (tester) async {
      // Wide enough to be "medium" and not wide enough to hold a conversation
      // beside a list without squeezing both.
      await show(tester, Screens.phoneLandscape, selected: 'c1');

      expect(find.byKey(const Key('detail')), findsNothing);
    });
  });
}
