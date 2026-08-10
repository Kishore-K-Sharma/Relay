import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/widgets.dart';

/// What a favourite looks like on screen.
void main() {
  const nearby = Peer(id: 'p1', nickname: 'Sara', hops: 1);
  const chosenFar = Peer(
    id: 'fav:1',
    nickname: 'Mum',
    hops: null,
    isFavourite: true,
  );

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('an out-of-range favourite is still listed', (tester) async {
    // The whole point of pinning someone. If they vanish from the strip when
    // they walk off, there is nowhere to tap to write the message that would
    // have waited in the outbox for them.
    await pump(tester, const PresenceStrip(peers: [nearby, chosenFar]));

    expect(find.text('Mum'), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
  });

  testWidgets('an out-of-range favourite is not shown as nearby', (
    tester,
  ) async {
    await pump(tester, const PresenceStrip(peers: [chosenFar]));

    expect(find.text('Not in range'), findsOneWidget);
  });

  testWidgets('favourites come first', (tester) async {
    await pump(
      tester,
      const PresenceStrip(
        peers: [
          nearby,
          Peer(id: 'p2', nickname: 'Ben', hops: 1, isFavourite: true),
        ],
      ),
    );

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(labels.indexOf('Ben'), lessThan(labels.indexOf('Sara')));
  });

  testWidgets('a favourite is marked so the choice is visible', (tester) async {
    await pump(tester, const PresenceStrip(peers: [chosenFar]));

    expect(find.byKey(const Key('favourite-mark-fav:1')), findsOneWidget);
  });

  testWidgets('the conversation menu can star and unstar someone', (
    tester,
  ) async {
    var favourited = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(
          conversation: const Conversation(
            id: 'peer-1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [],
            peer: nearby,
          ),
          onFavourite: () => favourited++,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('favourite-peer')));
    await tester.pumpAndSettle();

    expect(favourited, 1);
  });

  testWidgets('the menu says what starring actually buys', (tester) async {
    // Favouriting turns on the internet relay for this person. That is a real
    // privacy trade — a third party learns two identities are talking — so the
    // menu has to say so rather than showing a bare star.
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(
          conversation: const Conversation(
            id: 'peer-1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [],
            peer: nearby,
          ),
          onFavourite: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();

    expect(find.textContaining('internet'), findsOneWidget);
  });

  testWidgets('an already-favourited person is offered the reverse', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(
          conversation: const Conversation(
            id: 'peer-1',
            title: 'Mum',
            kind: ConversationKind.direct,
            messages: [],
            peer: chosenFar,
          ),
          onFavourite: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Remove'), findsOneWidget);
  });
}
