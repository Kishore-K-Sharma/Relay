import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/relay_app.dart';

Widget wrap(Widget child) => MaterialApp(theme: appTheme(), home: child);

const healthy = MeshStatus(
  bluetoothOn: true,
  permissionsGranted: true,
  peersInRange: 3,
);

Peer peer(String name, int? hops, {TrustBadge trust = TrustBadge.unverified}) =>
    Peer(id: name, nickname: name, hops: hops, trust: trust);

Conversation conversation({
  String title = 'Sara',
  Peer? withPeer,
  int unread = 0,
  List<Message> messages = const [],
  ConversationKind kind = ConversationKind.direct,
}) => Conversation(
  id: title,
  title: title,
  kind: kind,
  peer: withPeer,
  unread: unread,
  messages: messages,
);

void main() {
  group('HomeScreen', () {
    testWidgets('shows the presence strip above the conversation list', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          HomeScreen(
            status: healthy,
            peers: [peer('Sara', 1), peer('Maya', 2)],
            conversations: [conversation()],
          ),
        ),
      );

      final strip = tester.getTopLeft(find.byKey(const Key('presence-strip')));
      final list = tester.getTopLeft(
        find.byKey(const Key('conversation-list')),
      );

      expect(
        strip.dy,
        lessThan(list.dy),
        reason: 'live reachability is the first question a crowd user has',
      );
    });

    testWidgets('summarises who is reachable in the header', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeScreen(
            status: healthy,
            peers: [
              peer('Sara', 1, trust: TrustBadge.verified),
              peer('Maya', 2),
              peer('Gone', null),
            ],
            conversations: const [],
          ),
        ),
      );

      expect(find.text('2 nearby · 1 friend'), findsOneWidget);
    });

    testWidgets('says it is still looking when nobody is in range', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const HomeScreen(status: healthy, peers: [], conversations: [])),
      );

      expect(find.byKey(const Key('presence-empty')), findsOneWidget);
      expect(find.text('Looking for people nearby'), findsOneWidget);
    });

    testWidgets('excludes unreachable peers from the presence strip', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          HomeScreen(
            status: healthy,
            peers: [peer('Sara', 1), peer('Ghost', null)],
            conversations: const [],
          ),
        ),
      );

      expect(find.text('Sara'), findsOneWidget);
      expect(
        find.text('Ghost'),
        findsNothing,
        reason: 'showing an unreachable peer as present would be misleading',
      );
    });

    testWidgets('shows an empty state when there are no conversations', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const HomeScreen(status: healthy, peers: [], conversations: [])),
      );

      expect(find.byKey(const Key('conversations-empty')), findsOneWidget);
    });

    testWidgets('surfaces a stealth mode indicator', (tester) async {
      await tester.pumpWidget(
        wrap(
          const HomeScreen(
            status: MeshStatus(
              bluetoothOn: true,
              permissionsGranted: true,
              peersInRange: 0,
              stealthMode: true,
            ),
            peers: [],
            conversations: [],
          ),
        ),
      );

      expect(find.byKey(const Key('stealth-indicator')), findsOneWidget);
    });
  });

  group('degraded transport states', () {
    testWidgets('warns when Bluetooth is off', (tester) async {
      await tester.pumpWidget(
        wrap(
          const HomeScreen(
            status: MeshStatus(
              bluetoothOn: false,
              permissionsGranted: true,
              peersInRange: 0,
            ),
            peers: [],
            conversations: [],
          ),
        ),
      );

      expect(find.byKey(const Key('status-banner')), findsOneWidget);
      expect(find.textContaining('Bluetooth is off'), findsOneWidget);
    });

    testWidgets('permission problems outrank other warnings', (tester) async {
      await tester.pumpWidget(
        wrap(
          const HomeScreen(
            status: MeshStatus(
              bluetoothOn: false,
              permissionsGranted: false,
              peersInRange: 0,
            ),
            peers: [],
            conversations: [],
          ),
        ),
      );

      expect(find.textContaining('needs Bluetooth permission'), findsOneWidget);
    });

    testWidgets('discloses when the phone cannot be discovered', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const HomeScreen(
            status: MeshStatus(
              bluetoothOn: true,
              permissionsGranted: true,
              peersInRange: 1,
              canAdvertise: false,
            ),
            peers: [],
            conversations: [],
          ),
        ),
      );

      expect(
        find.textContaining('others cannot discover it'),
        findsOneWidget,
        reason:
            'a chipset without peripheral support must be disclosed, not hidden',
      );
    });

    testWidgets('shows no banner when everything is healthy', (tester) async {
      await tester.pumpWidget(
        wrap(const HomeScreen(status: healthy, peers: [], conversations: [])),
      );

      expect(find.byKey(const Key('status-banner')), findsNothing);
    });
  });

  group('message state is reported honestly', () {
    testWidgets('sent is visually distinct from delivered', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Scaffold(
            body: Column(
              children: [
                MessageStateChip(state: MessageState.sent),
                MessageStateChip(state: MessageState.delivered),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Sent into the mesh'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
    });

    testWidgets('every state has a distinct user-facing label', (tester) async {
      final labels = MessageState.values.map((s) => s.label).toSet();

      expect(labels, hasLength(MessageState.values.length));
    });

    testWidgets('only delivered and read count as confirmed', (tester) async {
      expect(MessageState.sent.isConfirmed, isFalse);
      expect(MessageState.queued.isConfirmed, isFalse);
      expect(MessageState.delivered.isConfirmed, isTrue);
      expect(MessageState.read.isConfirmed, isTrue);
    });

    testWidgets('shows failure states rather than hiding them', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Scaffold(body: MessageStateChip(state: MessageState.expired)),
        ),
      );

      expect(find.text('Never delivered'), findsOneWidget);
    });
  });

  group('room security is stated plainly', () {
    testWidgets('the join screen carries the warning', (tester) async {
      await tester.pumpWidget(wrap(const JoinRoomScreen()));

      expect(find.byKey(const Key('room-security-notice')), findsOneWidget);
      expect(
        find.text('Anyone who knows this code can read the group'),
        findsOneWidget,
      );
    });

    testWidgets('rejects a malformed code with a readable message', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const JoinRoomScreen()));

      await tester.enterText(find.byKey(const Key('room-code-field')), 'ABC');
      await tester.tap(find.byKey(const Key('join-button')));
      await tester.pump();

      expect(find.textContaining('exactly 6 characters'), findsOneWidget);
    });

    testWidgets('accepts a valid code and reports it upper-cased', (
      tester,
    ) async {
      String? joined;
      await tester.pumpWidget(
        wrap(JoinRoomScreen(onJoin: (code) => joined = code.value)),
      );

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'fest24',
      );
      await tester.tap(find.byKey(const Key('join-button')));
      await tester.pump();

      expect(joined, 'FEST24');
    });

    testWidgets('a room conversation is not marked strongly encrypted', (
      tester,
    ) async {
      final room = conversation(title: 'FEST24', kind: ConversationKind.room);
      final direct = conversation(title: 'Sara');

      expect(room.hasStrongEncryption, isFalse);
      expect(direct.hasStrongEncryption, isTrue);
    });
  });
}
