import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/testing.dart';

import 'support/mesh_devices.dart';

/// The router-with-no-internet case, end to end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLanNetwork network;
  late Device alice;
  late Device bob;

  setUp(() async {
    network = FakeLanNetwork();
    alice = await Device.create('alice', network);
    bob = await Device.create('bob', network);
    await until(
      () => alice.wifi.linkCount == 1 && bob.wifi.linkCount == 1,
      'the two devices to link over Wi-Fi',
    );
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  test('a message crosses a router with no internet, encrypted', () async {
    await alice.runtime.announcePresence();
    final conversation = await conversationOnceAnnounced(bob);

    await bob.runtime.sendText(conversation, 'the north gate at nine');
    await until(
      () => alice.state.conversations.any(
        (c) => c.messages.any((m) => m.body == 'the north gate at nine'),
      ),
      'the message to arrive at alice',
    );
  });

  test('nothing readable crosses the wire', () async {
    // The router owner, and everyone else on the network, sees this traffic.
    // A plaintext body here would mean the whole transport is a downgrade.
    await alice.runtime.announcePresence();
    final conversation = await conversationOnceAnnounced(bob);

    final captured = <int>[];
    alice.wifi.inbound.listen((frame) => captured.addAll(frame.bytes));

    await bob.runtime.sendText(conversation, 'the north gate at nine');
    await until(
      () => alice.state.conversations.any(
        (c) => c.messages.any((m) => m.body == 'the north gate at nine'),
      ),
      'the message to arrive',
    );

    expect(
      String.fromCharCodes(captured.where((b) => b >= 32 && b < 127)),
      isNot(contains('north gate')),
    );
  });

  test('Bluetooth off and Wi-Fi working is reported as two facts', () async {
    // One merged verdict would be wrong about at least one of them, and the
    // user's next action differs completely: turn Bluetooth on, or do nothing.
    await alice.runtime.refreshStatus();

    expect(alice.state.status.bluetoothOn, isFalse);
    expect(alice.state.status.wifiAvailable, isTrue);
    expect(alice.state.status.wifiPeers, 1);
  });

  test('the mesh is not called dead when only Wi-Fi is up', () async {
    await alice.runtime.refreshStatus();

    expect(alice.state.status.isHealthy, isTrue);
  });

  test('the problem message says what is actually lost', () async {
    await alice.runtime.refreshStatus();

    expect(
      alice.state.status.problem,
      contains('Wi-Fi'),
      reason:
          'telling someone Bluetooth is off, with no mention that Wi-Fi is '
          'carrying their messages, misdescribes what is happening',
    );
  });

  test('with Bluetooth on as well, there is nothing to report', () async {
    final carol = await Device.create('carol', network, bluetooth: true);
    addTearDown(carol.dispose);

    await carol.runtime.refreshStatus();

    expect(carol.state.status.problem, isNull);
  });

  test('stealth mode withdraws the Wi-Fi advertisement too', () async {
    // Silencing the Bluetooth beacon while still announcing on Wi-Fi would
    // make stealth mode worse than useless: it would look like it worked.
    await alice.runtime.setStealth(true);

    expect(alice.wifi.status.advertising, isFalse);
  });

  test('leaving stealth mode brings Wi-Fi back', () async {
    await alice.runtime.setStealth(true);

    await alice.runtime.setStealth(false);

    expect(alice.wifi.status.advertising, isTrue);
  });

  test('the Wi-Fi state survives a peer-list update', () async {
    // The peer list changes constantly. A status rebuilt field by field drops
    // whichever one was added last, and the Wi-Fi chip would flicker off every
    // time somebody walked past.
    await alice.runtime.refreshStatus();
    expect(alice.state.status.wifiAvailable, isTrue);

    alice.state.updatePeers(const []);

    expect(alice.state.status.wifiAvailable, isTrue);
    expect(alice.state.status.wifiPeers, 1);
  });

  test('a peer reachable on both radios is one person, not two', () async {
    // The peer table is keyed on the mesh address, which both transports carry,
    // so the same person over Bluetooth and Wi-Fi collapses to one entry.
    await alice.runtime.announcePresence();
    await until(() => bob.state.peers.isNotEmpty, 'bob to see alice');

    await alice.runtime.announcePresence();
    await settle();

    expect(bob.state.peers, hasLength(1));
  });
}
