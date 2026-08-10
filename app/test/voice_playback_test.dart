import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/conversation_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/runtime/runtime.dart';

/// Playing a voice note back.
///
/// The bubble drew a play arrow from the day voice notes were added. It was an
/// `Icon`, not a button: nothing was listening, `VoicePlayer` was constructed
/// and never called, and `MeshRuntime.voiceBytesOf` had no caller in the
/// product. A user could record a note, send it, watch it arrive, press the
/// triangle, and nothing would happen — with no error, because nothing had
/// gone wrong.
///
/// Worse than a missing feature: a control that looks live and is not teaches
/// the user the app is broken in ways they cannot describe.
void main() {
  Message voice({String id = 'm1', bool fromMe = false}) => Message(
    id: id,
    body: base64Encode(Uint8List.fromList(List.filled(64, 7))),
    fromMe: fromMe,
    state: MessageState.delivered,
    sentAt: DateTime(2026, 7, 27, 9),
    voiceDurationMs: 3200,
  );

  Conversation withMessages(List<Message> messages) => Conversation(
    id: 'c1',
    title: 'Sara',
    kind: ConversationKind.direct,
    messages: messages,
  );

  Future<void> show(
    WidgetTester tester, {
    required List<Message> messages,
    void Function(Message)? onPlayVoice,
    String? playingMessageId,
  }) => tester.pumpWidget(
    MaterialApp(
      home: ConversationScreen(
        conversation: withMessages(messages),
        onPlayVoice: onPlayVoice,
        playingMessageId: playingMessageId,
      ),
    ),
  );

  testWidgets('a voice note can be pressed', (tester) async {
    await show(tester, messages: [voice()], onPlayVoice: (_) {});

    expect(find.byKey(const Key('play-voice-m1')), findsOneWidget);
  });

  testWidgets('pressing it asks for that note, not another', (tester) async {
    Message? asked;
    await show(
      tester,
      messages: [
        voice(id: 'm1'),
        voice(id: 'm2'),
      ],
      onPlayVoice: (m) => asked = m,
    );

    await tester.tap(find.byKey(const Key('play-voice-m2')));
    await tester.pump();

    expect(asked?.id, 'm2');
  });

  testWidgets('a text message has nothing to press', (tester) async {
    await show(
      tester,
      messages: [
        Message(
          id: 'm1',
          body: 'hello',
          fromMe: false,
          state: MessageState.delivered,
          sentAt: DateTime(2026, 7, 27, 9),
        ),
      ],
      onPlayVoice: (_) {},
    );

    expect(find.byKey(const Key('play-voice-m1')), findsNothing);
  });

  testWidgets('the one that is playing says so', (tester) async {
    // Without this the user presses again, and a second press on a control
    // that gave no feedback is how you end up with two things playing.
    await show(
      tester,
      messages: [
        voice(id: 'm1'),
        voice(id: 'm2'),
      ],
      onPlayVoice: (_) {},
      playingMessageId: 'm1',
    );

    final playing = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('play-voice-m1')),
        matching: find.byType(Icon),
      ),
    );
    final idle = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('play-voice-m2')),
        matching: find.byType(Icon),
      ),
    );

    expect(playing.icon, isNot(idle.icon));
  });

  testWidgets('it is announced to a screen reader', (tester) async {
    // A bare triangle is not a label, and a voice note is the one message a
    // blind user cannot read past.
    await show(tester, messages: [voice()], onPlayVoice: (_) {});

    expect(find.bySemanticsLabel(RegExp('voice')), findsWidgets);
  });

  group('decoding the audio', () {
    test('a voice note yields its bytes', () {
      final bytes = Uint8List.fromList(List.filled(64, 7));
      final message = Message(
        id: 'm1',
        body: base64Encode(bytes),
        fromMe: false,
        state: MessageState.delivered,
        sentAt: DateTime(2026, 7, 27),
        voiceDurationMs: 100,
      );

      expect(MeshRuntime.voiceBytesOf(message), bytes);
    });

    test('a text message yields nothing rather than throwing', () {
      final message = Message(
        id: 'm1',
        body: 'hello',
        fromMe: false,
        state: MessageState.delivered,
        sentAt: DateTime(2026, 7, 27),
      );

      expect(MeshRuntime.voiceBytesOf(message), isNull);
    });

    test('a corrupt body yields nothing rather than throwing', () {
      // Arrives from another device. A malformed one must not take the screen
      // down with it.
      final message = Message(
        id: 'm1',
        body: '!!!not base64!!!',
        fromMe: false,
        state: MessageState.delivered,
        sentAt: DateTime(2026, 7, 27),
        voiceDurationMs: 100,
      );

      expect(MeshRuntime.voiceBytesOf(message), isNull);
    });
  });
}
