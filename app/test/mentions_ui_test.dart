import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/domain/models.dart';

/// Mentions where the user meets them: while typing, and once they arrive.
void main() {
  Conversation room({List<Message> messages = const []}) => Conversation(
    id: 'room-1',
    title: 'RUFF7A',
    kind: ConversationKind.room,
    messages: messages,
  );

  Future<void> pump(
    WidgetTester tester,
    Conversation conversation, {
    List<String> candidates = const ['sara', 'ben'],
    void Function(String)? onSend,
  }) => tester.pumpWidget(
    MaterialApp(
      home: ConversationScreen(
        conversation: conversation,
        mentionCandidates: candidates,
        onSend: onSend ?? (_) {},
      ),
    ),
  );

  testWidgets('typing @ offers the people who are here', (tester) async {
    await pump(tester, room());

    await tester.enterText(find.byType(TextField), 'hey @');
    await tester.pump();

    expect(find.byKey(const Key('mention-suggestions')), findsOneWidget);
    expect(find.text('sara'), findsOneWidget);
    expect(find.text('ben'), findsOneWidget);
  });

  testWidgets('the list narrows as the name is typed', (tester) async {
    await pump(tester, room());

    await tester.enterText(find.byType(TextField), 'hey @sa');
    await tester.pump();

    expect(find.text('sara'), findsOneWidget);
    expect(find.text('ben'), findsNothing);
  });

  testWidgets('no suggestions when nothing is being mentioned', (tester) async {
    await pump(tester, room());

    await tester.enterText(find.byType(TextField), 'hello everyone');
    await tester.pump();

    expect(find.byKey(const Key('mention-suggestions')), findsNothing);
  });

  testWidgets('tapping a suggestion finishes the name', (tester) async {
    String? sent;
    await pump(tester, room(), onSend: (body) => sent = body);

    await tester.enterText(find.byType(TextField), 'hey @sa');
    await tester.pump();
    await tester.tap(find.text('sara'));
    await tester.pump();

    // Sending is the only observation that proves the controller was updated
    // rather than merely the visible label.
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();

    expect(sent, 'hey @sara');
  });

  testWidgets('a message naming you is marked', (tester) async {
    await pump(
      tester,
      room(
        messages: [
          Message(
            id: 'm1',
            body: 'hey @sara can you come',
            fromMe: false,
            state: MessageState.delivered,
            sentAt: DateTime(2026),
            mentionsYou: true,
          ),
        ],
      ),
    );

    expect(find.byKey(const Key('mention-mark-m1')), findsOneWidget);
  });

  testWidgets('an ordinary message is not marked', (tester) async {
    await pump(
      tester,
      room(
        messages: [
          Message(
            id: 'm1',
            body: 'hello everyone',
            fromMe: false,
            state: MessageState.delivered,
            sentAt: DateTime(2026),
          ),
        ],
      ),
    );

    expect(find.byKey(const Key('mention-mark-m1')), findsNothing);
  });

  testWidgets('a direct conversation offers no suggestions', (tester) async {
    // There is exactly one other person in it. Offering to name them is noise.
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(
          conversation: const Conversation(
            id: 'peer-1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [],
          ),
          mentionCandidates: const ['sara'],
          onSend: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'hey @');
    await tester.pump();

    expect(find.byKey(const Key('mention-suggestions')), findsNothing);
  });
}
