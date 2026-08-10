import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_app/src/ui/screens/diagnostics_screen.dart';
import 'package:relay_app/src/ui/screens/home_screen.dart';
import 'package:relay_app/src/domain/models.dart';
import 'package:relay_app/src/ui/screens/settings_screen.dart';
import 'package:transport_ble/transport_ble.dart';

/// What the screen says about Wi-Fi.
///
/// The transport is only half the feature. If the app cannot tell someone that
/// their messages are crossing a router rather than the air — and what that
/// costs them in privacy — they cannot make an informed choice about using it.
Future<void> show(WidgetTester tester, Widget child) async {
  tester.view
    ..physicalSize = const Size(1200, 4000)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

const bluetoothOnly = MeshStatus(
  bluetoothOn: true,
  permissionsGranted: true,
  peersInRange: 2,
);

const wifiWorking = MeshStatus(
  bluetoothOn: true,
  permissionsGranted: true,
  peersInRange: 5,
  wifiAvailable: true,
  wifiPeers: 3,
);

const wifiOnly = MeshStatus(
  bluetoothOn: false,
  permissionsGranted: true,
  peersInRange: 3,
  wifiAvailable: true,
  wifiPeers: 3,
);

void main() {
  group('home', () {
    testWidgets('says how many people are reachable over Wi-Fi', (
      tester,
    ) async {
      await show(
        tester,
        const HomeScreen(status: wifiWorking, peers: [], conversations: []),
      );

      expect(find.byKey(const Key('wifi-indicator')), findsOneWidget);
      expect(find.textContaining('3 on Wi-Fi'), findsOneWidget);
    });

    testWidgets('says nothing about Wi-Fi when there is none', (tester) async {
      // A permanently visible "Wi-Fi: off" would be noise. The indicator earns
      // its place only when it changes what the user can expect.
      await show(
        tester,
        const HomeScreen(status: bluetoothOnly, peers: [], conversations: []),
      );

      expect(find.byKey(const Key('wifi-indicator')), findsNothing);
    });

    testWidgets('with only Wi-Fi, the banner explains what is lost', (
      tester,
    ) async {
      await show(
        tester,
        const HomeScreen(status: wifiOnly, peers: [], conversations: []),
      );

      expect(find.byKey(const Key('status-banner')), findsOneWidget);
      expect(
        find.textContaining('still reach people on this Wi-Fi'),
        findsOneWidget,
      );
    });

    testWidgets('with only Wi-Fi, it does not claim to be disconnected', (
      tester,
    ) async {
      // Messages are moving. "Not connected" would send someone looking for a
      // problem that does not exist.
      await show(
        tester,
        const HomeScreen(status: wifiOnly, peers: [], conversations: []),
      );

      expect(find.text('Not connected'), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('explains the router-with-no-internet case in plain words', (
      tester,
    ) async {
      await show(
        tester,
        const SettingsScreen(status: wifiWorking, nickname: 'me'),
      );

      expect(find.byKey(const Key('wifi-switch')), findsOneWidget);
      expect(find.textContaining('no internet'), findsOneWidget);
    });

    testWidgets('the Wi-Fi switch reports changes', (tester) async {
      bool? changed;
      await show(
        tester,
        SettingsScreen(
          status: wifiWorking,
          nickname: 'me',
          wifiEnabled: true,
          onWifiChanged: (value) => changed = value,
        ),
      );

      await tester.tap(find.byKey(const Key('wifi-switch')));
      await tester.pumpAndSettle();

      expect(changed, isFalse);
    });

    testWidgets('says why Wi-Fi is unusable rather than just showing off', (
      tester,
    ) async {
      await show(
        tester,
        const SettingsScreen(
          status: MeshStatus(
            bluetoothOn: true,
            permissionsGranted: true,
            peersInRange: 0,
            wifiDetail: 'Not connected to Wi-Fi',
          ),
          nickname: 'me',
        ),
      );

      expect(find.textContaining('Not connected to Wi-Fi'), findsOneWidget);
    });

    testWidgets('the threat model admits what the network owner sees', (
      tester,
    ) async {
      // This is the honest cost of the Wi-Fi transport and it must not be left
      // out just because the feature is otherwise a straight win.
      await show(
        tester,
        const SettingsScreen(status: wifiWorking, nickname: 'me'),
      );

      await tester.tap(find.byKey(const Key('threat-model')));
      await tester.pumpAndSettle();

      expect(find.textContaining('whoever runs the Wi-Fi'), findsOneWidget);
    });
  });

  group('diagnostics', () {
    testWidgets('counts Wi-Fi peers separately from Bluetooth ones', (
      tester,
    ) async {
      await show(
        tester,
        const DiagnosticsScreen(
          status: wifiWorking,
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      );

      expect(find.text('People on this Wi-Fi'), findsOneWidget);
      expect(find.text('3'), findsWidgets);
    });

    testWidgets('shows why the local network is unusable', (tester) async {
      await show(
        tester,
        const DiagnosticsScreen(
          status: MeshStatus(
            bluetoothOn: true,
            permissionsGranted: true,
            peersInRange: 0,
            wifiDetail: 'Not connected to Wi-Fi',
          ),
          stats: BleRelayStats.empty,
          outboxDepth: 0,
        ),
      );

      expect(find.textContaining('Not connected to Wi-Fi'), findsOneWidget);
    });
  });
}
