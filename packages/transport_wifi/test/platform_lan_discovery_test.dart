import 'package:flutter_test/flutter_test.dart';
import 'package:transport_wifi/src/generated/discovery_api.g.dart' as g;
import 'package:transport_wifi/src/lan_discovery.dart';
import 'package:transport_wifi/src/platform_lan_discovery.dart';

/// The thin layer between the platform channel and the transport.
///
/// It has almost no logic, and the tests are here to keep it that way: the two
/// things it must never do are lose an availability change and let a platform
/// exception escape into the transport's socket handling.
class FakeHost extends g.DiscoveryHostApi {
  bool available = true;
  g.DiscoveryUnavailable? reason;
  Object? nextError;

  final calls = <String>[];
  String? advertisedInstance;
  int? advertisedPort;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<g.DiscoveryUnavailable?> unavailableReason() async => reason;

  @override
  Future<void> advertise(String instanceId, int addressHash, int port) async {
    calls.add('advertise');
    if (nextError != null) throw nextError!;
    advertisedInstance = instanceId;
    advertisedPort = port;
  }

  @override
  Future<void> stopAdvertising() async => calls.add('stopAdvertising');

  @override
  Future<void> browse() async {
    calls.add('browse');
    if (nextError != null) throw nextError!;
  }

  @override
  Future<void> stopBrowsing() async => calls.add('stopBrowsing');
}

void main() {
  late FakeHost host;
  late PlatformLanDiscovery discovery;

  setUp(() async {
    host = FakeHost();
    discovery = PlatformLanDiscovery(hostApi: host, registerHandler: false);
    await discovery.refresh();
  });

  tearDown(() => discovery.dispose());

  test('availability is read from the platform at startup', () async {
    host
      ..available = false
      ..reason = g.DiscoveryUnavailable.noNetwork;

    await discovery.refresh();

    expect(discovery.isAvailable, isFalse);
    expect(discovery.unavailableReason, LanUnavailable.noNetwork);
  });

  test('a refused permission is distinguished from no network', () async {
    // They need different words on screen: one is a settings toggle, the other
    // is "join a Wi-Fi network". A single "unavailable" would be useless.
    host
      ..available = false
      ..reason = g.DiscoveryUnavailable.permissionDenied;

    await discovery.refresh();

    expect(discovery.unavailableReason, LanUnavailable.permissionDenied);
    expect(discovery.unavailableReason!.message, contains('permission'));
  });

  test('advertising passes through what the platform needs', () async {
    await discovery.advertise(
      instanceId: 'abc',
      addressHash: 0x1234,
      port: 4747,
    );

    expect(host.advertisedInstance, 'abc');
    expect(host.advertisedPort, 4747);
  });

  test('a platform failure to advertise is reported, not thrown', () async {
    // Thrown here it would abort the transport's start and take the sockets
    // with it, so the device would stop relaying because it could not announce.
    host.nextError = Exception('registration failed');

    await expectLater(
      discovery.advertise(instanceId: 'a', addressHash: 1, port: 2),
      completes,
    );
    expect(discovery.isAvailable, isFalse);
  });

  test('a found service is republished to listeners', () async {
    final found = discovery.found.first;

    discovery.onServiceFound(
      g.ServiceInfo(
        instanceId: 'peer1',
        host: '192.168.1.9',
        port: 5000,
        addressHash: 0xBEEF,
      ),
    );

    final service = await found;
    expect(service.instanceId, 'peer1');
    expect(service.host, '192.168.1.9');
    expect(service.addressHash, 0xBEEF);
  });

  test('a lost service is republished by instance id', () async {
    final lost = discovery.lost.first;

    discovery.onServiceLost('peer1');

    expect(await lost, 'peer1');
  });

  test('the platform can revoke availability while running', () async {
    // Walking out of Wi-Fi range. Without this the app keeps claiming the
    // local network works long after it stopped.
    discovery.onAvailabilityChanged(false, g.DiscoveryUnavailable.noNetwork);

    expect(discovery.isAvailable, isFalse);
    expect(discovery.unavailableReason, LanUnavailable.noNetwork);
  });

  test('regaining the network clears the reason', () async {
    discovery.onAvailabilityChanged(false, g.DiscoveryUnavailable.noNetwork);

    discovery.onAvailabilityChanged(true, null);

    expect(discovery.isAvailable, isTrue);
    expect(discovery.unavailableReason, isNull);
  });

  test('browse and stop are passed straight through', () async {
    await discovery.browse();
    await discovery.stopBrowsing();
    await discovery.stopAdvertising();

    expect(
      host.calls,
      containsAll(['browse', 'stopBrowsing', 'stopAdvertising']),
    );
  });
}
