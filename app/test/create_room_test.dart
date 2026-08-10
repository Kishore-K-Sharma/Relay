import 'package:core_identity/core_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/join_room_screen.dart';

/// Starting a group, as opposed to joining one someone else started.
///
/// The two are the same act underneath — a room exists as soon as anyone types
/// its code — but they are not the same to a user, and the difference matters
/// for a reason beyond wording: a code somebody invents is not random. People
/// pick FEST24 and PARTY7, and a guesser starts with exactly those.
void main() {
  Future<void> show(
    WidgetTester tester, {
    void Function(RoomCode)? onJoin,
  }) async {
    await tester.pumpWidget(MaterialApp(home: JoinRoomScreen(onJoin: onJoin)));
    // Settled, not one frame. The route transition absorbs pointers while it
    // animates, so a tap on the first frame lands on the transition rather
    // than on the button under it.
    await tester.pumpAndSettle();
  }

  String codeInField(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('room-code-field')))
      .controller!
      .text;

  testWidgets('there is a way to start a group without knowing a code', (
    tester,
  ) async {
    await show(tester);

    expect(find.byKey(const Key('generate-code')), findsOneWidget);
  });

  testWidgets('the generated code is a valid room code', (tester) async {
    await show(tester);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();

    // Parsing is the real assertion: a code that fails here cannot be joined,
    // and the user would be staring at a rejection of the app's own suggestion.
    expect(() => RoomCode.parse(codeInField(tester)), returnsNormally);
  });

  testWidgets('generating twice gives two different codes', (tester) async {
    await show(tester);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();
    final first = codeInField(tester);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();

    expect(codeInField(tester), isNot(first));
  });

  testWidgets('a generated code can be joined straight away', (tester) async {
    RoomCode? joined;
    await show(tester, onJoin: (code) => joined = code);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();
    final generated = codeInField(tester);
    await tester.tap(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();

    expect(joined?.value, generated);
  });

  testWidgets('it says the code has to be passed on by hand', (tester) async {
    // There is no invite link and no directory. If nobody tells anyone the
    // code, the group has exactly one member and the user will not know why.
    await show(tester);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Tell it to the people'), findsOneWidget);
  });

  testWidgets('the code can be copied', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(((call.arguments as Map)['text'] as String?) ?? '');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await show(tester);
    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();
    final generated = codeInField(tester);

    await tester.tap(find.byKey(const Key('copy-code')));
    await tester.pumpAndSettle();

    expect(copied, [generated]);
  });

  testWidgets('nothing to copy before a code exists', (tester) async {
    await show(tester);

    expect(find.byKey(const Key('copy-code')), findsNothing);
  });

  testWidgets('the warning about weak codes stays up', (tester) async {
    // Generating a strong code does not make the room private: the code is
    // still shouted across a room, and anyone who hears it reads the group
    // forever. Hiding the notice on the generated path would be the exact
    // moment the app started overstating what it protects.
    await show(tester);

    await tester.tap(find.byKey(const Key('generate-code')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-security-notice')), findsOneWidget);
  });
}
