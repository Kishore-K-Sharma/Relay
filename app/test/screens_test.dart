import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/relay_app.dart';

Widget wrap(Widget child) => MaterialApp(theme: appTheme(), home: child);

const healthy = MeshStatus(
  bluetoothOn: true,
  permissionsGranted: true,
  peersInRange: 2,
);

Message msg(
  String id, {
  bool fromMe = true,
  MessageState state = MessageState.sent,
  int? voiceMs,
}) => Message(
  id: id,
  body: 'body $id',
  fromMe: fromMe,
  state: state,
  sentAt: DateTime(2026, 7, 26, 12),
  voiceDurationMs: voiceMs,
);

void main() {
  group('ConversationScreen', () {
    testWidgets('renders messages and the composer', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [msg('1'), msg('2', fromMe: false)],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('message-list')), findsOneWidget);
      expect(find.byKey(const Key('composer-field')), findsOneWidget);
      expect(find.byKey(const Key('voice-button')), findsOneWidget);
    });

    testWidgets('sends trimmed text and clears the field', (tester) async {
      String? sent;
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: const Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [],
            ),
            onSend: (body) => sent = body,
          ),
        ),
      );

      await tester.enterText(find.byKey(const Key('composer-field')), '  hi  ');
      await tester.tap(find.byKey(const Key('send-button')));
      await tester.pump();

      expect(sent, 'hi');
      expect(find.text('  hi  '), findsNothing);
    });

    testWidgets('refuses to send an empty message', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: const Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [],
            ),
            onSend: (_) => calls++,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('send-button')));
      await tester.pump();

      expect(calls, 0);
    });

    testWidgets('shows a standing reminder in a room', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConversationScreen(
            conversation: Conversation(
              id: 'r1',
              title: 'FEST24',
              kind: ConversationKind.room,
              memberCount: 8,
              messages: [],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('room-reminder')), findsOneWidget);
    });

    testWidgets('shows no room reminder in a direct chat', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('room-reminder')), findsNothing);
    });

    testWidgets('warns loudly when a contact key changed', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              peer: Peer(
                id: 'sara',
                nickname: 'Sara',
                hops: 1,
                trust: TrustBadge.keyChanged,
              ),
              messages: [],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('key-changed-warning')), findsOneWidget);
      expect(find.textContaining('may not be them'), findsOneWidget);
    });

    testWidgets('offers retry only on terminal failures', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [msg('1', state: MessageState.expired)],
            ),
            onRetry: (_) {},
          ),
        ),
      );

      expect(find.byKey(const Key('retry-button')), findsOneWidget);
    });

    testWidgets('does not offer retry on an in-flight message', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [msg('1', state: MessageState.sent)],
            ),
            onRetry: (_) {},
          ),
        ),
      );

      expect(find.byKey(const Key('retry-button')), findsNothing);
    });

    testWidgets('renders a voice note with its duration', (tester) async {
      await tester.pumpWidget(
        wrap(
          ConversationScreen(
            conversation: Conversation(
              id: 'c1',
              title: 'Sara',
              kind: ConversationKind.direct,
              messages: [msg('1', voiceMs: 12000)],
            ),
          ),
        ),
      );

      expect(find.text('12s'), findsOneWidget);
    });
  });

  group('RadarScreen', () {
    testWidgets('states plainly that it is not a map', (tester) async {
      await tester.pumpWidget(wrap(const RadarScreen(peers: [])));

      expect(find.byKey(const Key('radar-disclaimer')), findsOneWidget);
      expect(find.textContaining('not a map'), findsOneWidget);
    });

    testWidgets('shows an empty state with nobody in range', (tester) async {
      await tester.pumpWidget(wrap(const RadarScreen(peers: [])));

      expect(find.byKey(const Key('radar-empty')), findsOneWidget);
    });

    testWidgets('plots only reachable peers', (tester) async {
      await tester.pumpWidget(
        wrap(
          const RadarScreen(
            peers: [
              Peer(id: 'a', nickname: 'Sara', hops: 1),
              Peer(id: 'b', nickname: 'Ghost', hops: null),
            ],
          ),
        ),
      );

      expect(find.text('Sara'), findsOneWidget);
      expect(find.text('Ghost'), findsNothing);
    });
  });

  group('SettingsScreen', () {
    setUp(() {
      // The settings list is taller than the default 800px test viewport.
      // A tall viewport keeps these tests about content, not scrolling.
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1200, 3600);
      view.devicePixelRatio = 1.0;
    });

    tearDown(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    testWidgets('shows the battery cost of each power mode', (tester) async {
      await tester.pumpWidget(
        wrap(const SettingsScreen(status: healthy, nickname: 'you')),
      );

      expect(find.textContaining('12.0% battery per hour'), findsOneWidget);
      expect(find.textContaining('2.5% battery per hour'), findsOneWidget);
    });

    testWidgets('explains that stealth mode keeps relaying', (tester) async {
      await tester.pumpWidget(
        wrap(const SettingsScreen(status: healthy, nickname: 'you')),
      );

      expect(
        find.textContaining('keep passing on other people'),
        findsOneWidget,
      );
    });

    testWidgets('states the unreviewed security posture', (tester) async {
      await tester.pumpWidget(
        wrap(const SettingsScreen(status: healthy, nickname: 'you')),
      );

      await tester.tap(find.byKey(const Key('threat-model')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('has not yet had an independent security review'),
        findsOneWidget,
      );
    });

    testWidgets('requires confirmation before wiping', (tester) async {
      var wiped = false;
      await tester.pumpWidget(
        wrap(
          SettingsScreen(
            status: healthy,
            nickname: 'you',
            onPanicWipe: () => wiped = true,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('panic-wipe')));
      await tester.pumpAndSettle();
      expect(wiped, isFalse, reason: 'destructive and irreversible');

      await tester.tap(find.byKey(const Key('confirm-wipe')));
      await tester.pumpAndSettle();
      expect(wiped, isTrue);
    });

    testWidgets('cancelling the wipe dialog changes nothing', (tester) async {
      var wiped = false;
      await tester.pumpWidget(
        wrap(
          SettingsScreen(
            status: healthy,
            nickname: 'you',
            onPanicWipe: () => wiped = true,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('panic-wipe')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(wiped, isFalse);
    });
  });

  group('OnboardingScreen', () {
    testWidgets('blocks continuing while steps remain', (tester) async {
      await tester.pumpWidget(
        wrap(
          OnboardingScreen(
            outstanding: const [SetupStep.permissions],
            onResolve: (_) {},
            onFinish: () {},
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('onboarding-continue')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('allows continuing once everything is done', (tester) async {
      var finished = false;
      await tester.pumpWidget(
        wrap(
          OnboardingScreen(
            outstanding: const [],
            onResolve: (_) {},
            onFinish: () => finished = true,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('onboarding-continue')));
      await tester.pump();

      expect(finished, isTrue);
      expect(find.byKey(const Key('setup-complete')), findsOneWidget);
    });

    testWidgets('explains why the battery step matters', (tester) async {
      await tester.pumpWidget(
        wrap(
          OnboardingScreen(
            outstanding: const [SetupStep.battery],
            onResolve: (_) {},
          ),
        ),
      );

      expect(find.textContaining('stops passing on messages'), findsOneWidget);
    });
  });

  group('PairingScreen', () {
    testWidgets('shows the pairing payload before a scan', (tester) async {
      await tester.pumpWidget(
        wrap(const PairingScreen(myPublicKeyHex: 'abcd')),
      );

      expect(find.byKey(const Key('pairing-payload')), findsOneWidget);
      expect(find.byKey(const Key('safety-code')), findsNothing);
    });

    testWidgets('shows the safety code and its warning after a scan', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const PairingScreen(
            myPublicKeyHex: 'abcd',
            safetyCode: '12345 67890',
            peerName: 'Sara',
          ),
        ),
      );

      expect(find.byKey(const Key('safety-code')), findsOneWidget);
      expect(find.textContaining('may be impersonating Sara'), findsOneWidget);
    });
  });

  group('AppState', () {
    test('lists outstanding setup steps in order', () {
      final state = AppState()..needsBatteryExemption = true;

      expect(state.outstandingSteps, [
        SetupStep.permissions,
        SetupStep.bluetoothOn,
        SetupStep.battery,
      ]);
    });

    test('recomputes peers in range when peers change', () {
      final state = AppState(status: healthy);

      state.updatePeers([
        const Peer(id: 'a', nickname: 'A', hops: 1),
        const Peer(id: 'b', nickname: 'B', hops: null),
      ]);

      expect(state.status.peersInRange, 1);
    });

    test('stealth mode disables the internet relay', () {
      final state = AppState(
        status: const MeshStatus(
          bluetoothOn: true,
          permissionsGranted: true,
          peersInRange: 0,
          relayAvailable: true,
        ),
      );

      state.setStealth(true);

      expect(state.status.relayAvailable, isFalse);
    });

    test('advances a message state in place', () {
      final state = AppState()
        ..upsertConversation(
          Conversation(
            id: 'c1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [msg('m1', state: MessageState.sent)],
          ),
        );

      state.updateMessageState('c1', 'm1', MessageState.delivered);

      expect(
        state.conversation('c1')!.messages.single.state,
        MessageState.delivered,
      );
    });

    test('counts an incoming message as unread', () {
      final state = AppState()
        ..upsertConversation(
          const Conversation(
            id: 'c1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [],
          ),
        );

      state.appendMessage('c1', msg('m1', fromMe: false));

      expect(state.conversation('c1')!.unread, 1);
    });

    test('wipe clears everything', () {
      final state = AppState(onboarded: true)
        ..upsertConversation(
          const Conversation(
            id: 'c1',
            title: 'Sara',
            kind: ConversationKind.direct,
            messages: [],
          ),
        );

      state.wipe();

      expect(state.conversations, isEmpty);
      expect(state.onboarded, isFalse);
    });
  });
}
