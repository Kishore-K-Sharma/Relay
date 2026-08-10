import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/diagnostics_screen.dart';
import 'package:relay_app/src/runtime/event_log.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:transport_ble/transport_ble.dart';

const healthy = MeshStatus(
  bluetoothOn: true,
  permissionsGranted: true,
  peersInRange: 3,
);

Widget wrap(Widget child) => MaterialApp(home: child);

void main() {
  // Tall enough that the whole list is laid out. A ListView does not build
  // what is off screen, so the alternative is scripting scrolls in every test
  // for no benefit.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 4000);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  testWidgets('shows the relay counters', (tester) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats(
            framesReceived: 120,
            framesRelayed: 44,
            framesDropped: 6,
            framesSuppressed: 70,
            storedForForward: 2,
            inboxDepth: 1,
          ),
          outboxDepth: 3,
        ),
      ),
    );

    expect(find.text('120'), findsOneWidget);
    expect(find.text('44'), findsOneWidget);
    expect(find.text('70'), findsOneWidget);
  });

  testWidgets('explains what a counter means rather than just naming it', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      ),
    );

    // A bare number called "suppressed" tells a user nothing. The screen exists
    // so someone can work out why the mesh is misbehaving.
    expect(find.textContaining('already carrying'), findsOneWidget);
  });

  testWidgets('reports the mesh problem at the top when there is one', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: MeshStatus(
            bluetoothOn: false,
            permissionsGranted: true,
            peersInRange: 0,
          ),
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      ),
    );

    expect(find.byKey(const Key('diagnostics-problem')), findsOneWidget);
  });

  testWidgets('says nothing has been relayed yet rather than showing bare '
      'zeroes with no context', (tester) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      ),
    );

    expect(find.byKey(const Key('diagnostics-idle')), findsOneWidget);
  });

  testWidgets('shows how many messages are still waiting to go', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 7,
        ),
      ),
    );

    expect(find.byKey(const Key('diagnostics-outbox')), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('refresh asks for new numbers', (tester) async {
    var refreshed = 0;

    await tester.pumpWidget(
      wrap(
        DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
          onRefresh: () => refreshed++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('diagnostics-refresh')));

    expect(refreshed, 1);
  });

  testWidgets('shows recent activity', (tester) async {
    await tester.pumpWidget(
      wrap(
        DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
          log: [
            LogEntry(
              at: DateTime(2026, 7, 26, 9, 4, 3),
              level: LogLevel.info,
              message: 'Sara came into range',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Sara came into range'), findsOneWidget);
    expect(find.text('09:04:03'), findsOneWidget);
  });

  testWidgets('says the log stays on the phone', (tester) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      ),
    );

    // The promise has to be on the screen, not only in the source. A user
    // looking at a page of diagnostics will reasonably assume it is being
    // collected unless told otherwise.
    expect(find.textContaining('sends nothing'), findsOneWidget);
  });

  testWidgets('an empty log says so rather than showing a blank space', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      ),
    );

    expect(find.byKey(const Key('diagnostics-log-empty')), findsOneWidget);
  });

  testWidgets('copying is offered only when there is a handler for it', (
    tester,
  ) async {
    var copied = 0;

    await tester.pumpWidget(
      wrap(
        DiagnosticsScreen(
          status: healthy,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
          onCopyLog: () => copied++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('diagnostics-copy-log')));

    expect(copied, 1);
  });
}
