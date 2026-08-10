import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/domain/models.dart';

/// Getting out of a group.
///
/// `MeshRuntime.leaveRoom` was written, tested, and called by nothing in the
/// product. A user could join a group and never leave it — and while you are in
/// a room your phone answers other people's requests for its history, so a room
/// you have forgotten about is a room you are still serving to strangers.
///
/// A slash command alone does not fix that. Nobody discovers `/leave` by
/// looking at a screen.
void main() {
  Conversation room({String title = 'Rooftop'}) => Conversation(
    id: 'r1',
    title: title,
    kind: ConversationKind.room,
    messages: const [],
  );

  Conversation direct() => const Conversation(
    id: 'c1',
    title: 'Sara',
    kind: ConversationKind.direct,
    messages: [],
  );

  Future<void> show(
    WidgetTester tester,
    Conversation conversation, {
    VoidCallback? onLeave,
    VoidCallback? onBlock,
  }) => tester.pumpWidget(
    MaterialApp(
      home: ConversationScreen(
        conversation: conversation,
        onLeave: onLeave,
        onBlock: onBlock,
      ),
    ),
  );

  testWidgets('a group offers a way out', (tester) async {
    await show(tester, room(), onLeave: () {});

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('leave-room')), findsOneWidget);
  });

  testWidgets('a direct conversation does not', (tester) async {
    // There is nothing to leave. Blocking is the equivalent, and it is
    // already there — so the menu exists and simply has no leave in it.
    await show(tester, direct(), onLeave: () {}, onBlock: () {});

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('leave-room')), findsNothing);
  });

  testWidgets('leaving asks first', (tester) async {
    // Rejoining needs the code, and the user may not have kept it anywhere.
    var left = false;
    await show(tester, room(), onLeave: () => left = true);

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-room')));
    await tester.pumpAndSettle();

    expect(left, isFalse, reason: 'not until it is confirmed');
    expect(find.textContaining('code'), findsWidgets);
  });

  testWidgets('confirming leaves', (tester) async {
    var left = false;
    await show(tester, room(), onLeave: () => left = true);

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-room')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-room-confirm')));
    await tester.pumpAndSettle();

    expect(left, isTrue);
  });

  testWidgets('the warning names the group being left', (tester) async {
    // Two rooms open side by side on a tablet is the case where a generic
    // "leave this group?" is genuinely ambiguous.
    await show(tester, room(title: 'North Gate'), onLeave: () {});

    await tester.tap(find.byKey(const Key('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-room')));
    await tester.pumpAndSettle();

    expect(find.textContaining('North Gate'), findsWidgets);
  });

  testWidgets('no menu at all when nothing can be done', (tester) async {
    // A menu button that opens an empty sheet is worse than no button.
    await show(tester, room());

    expect(find.byKey(const Key('conversation-menu')), findsNothing);
  });
}
