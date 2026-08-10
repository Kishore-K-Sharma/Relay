import 'dart:async';

import 'lan_discovery.dart';

/// An in-memory stand-in for mDNS, so the transport can be tested end to end
/// against real sockets without a platform plugin.
///
/// Exported from `package:transport_wifi/testing.dart` rather than the main
/// library, so nothing in the app can reach it by accident.
class FakeLanNetwork {
  final _members = <FakeLanDiscovery>[];

  FakeLanDiscovery join() {
    final member = FakeLanDiscovery._(this);
    _members.add(member);
    return member;
  }

  /// Everything currently advertised, as it would look to a new browser.
  Iterable<DiscoveredService> get advertised =>
      _members.map((m) => m._published).nonNulls;

  void _publish(FakeLanDiscovery source) {
    final service = source._published;
    if (service == null) return;
    for (final member in _members) {
      if (member._browsing) member._found.add(service);
    }
  }

  void _withdraw(String instanceId) {
    for (final member in _members) {
      if (member._browsing) member._lost.add(instanceId);
    }
  }
}

/// One device's view of a [FakeLanNetwork].
class FakeLanDiscovery implements LanDiscovery {
  FakeLanDiscovery._(this._network);

  final FakeLanNetwork _network;

  final _found = StreamController<DiscoveredService>.broadcast();
  final _lost = StreamController<String>.broadcast();

  DiscoveredService? _published;
  bool _browsing = false;

  /// Set by tests that need to exercise the refused-permission path.
  LanUnavailable? failure;

  @override
  Stream<DiscoveredService> get found => _found.stream;

  @override
  Stream<String> get lost => _lost.stream;

  @override
  bool get isAvailable => failure == null;

  @override
  LanUnavailable? get unavailableReason => failure;

  bool get isAdvertising => _published != null;

  bool get isBrowsing => _browsing;

  @override
  Future<void> advertise({
    required String instanceId,
    required int addressHash,
    required int port,
  }) async {
    _published = DiscoveredService(
      instanceId: instanceId,
      host: '127.0.0.1',
      port: port,
      addressHash: addressHash,
    );
    _network._publish(this);
  }

  @override
  Future<void> stopAdvertising() async {
    final gone = _published;
    _published = null;
    if (gone != null) _network._withdraw(gone.instanceId);
  }

  @override
  Future<void> browse() async {
    _browsing = true;
    // A real browser reports what is already on the network, not only what
    // appears next. Getting this wrong in the fake would hide a whole class of
    // ordering bug in the transport.
    for (final service in _network.advertised.toList()) {
      if (service.instanceId != _published?.instanceId) _found.add(service);
    }
  }

  /// Reports a service that no real device is behind, for testing what happens
  /// when a peer dies between advertising and being found.
  void injectService(DiscoveredService service) => _found.add(service);

  @override
  Future<void> stopBrowsing() async => _browsing = false;

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await _found.close();
    await _lost.close();
  }
}
