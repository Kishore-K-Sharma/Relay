import 'dart:async';

import 'generated/discovery_api.g.dart' as g;
import 'lan_discovery.dart';

/// mDNS discovery, backed by the platform.
///
/// Android's NsdManager and Apple's Bonjour speak the same protocol, so one
/// contract covers both. This class translates between the generated Pigeon
/// types and the transport's own, and holds the last known availability so the
/// transport can read it without a platform round trip on every status query.
///
/// It contains no policy. Every decision about what to do with a discovered
/// peer belongs to the transport, which can be tested without a plugin loaded.
class PlatformLanDiscovery implements LanDiscovery, g.DiscoveryFlutterApi {
  PlatformLanDiscovery({
    g.DiscoveryHostApi? hostApi,

    /// Registers this object for native callbacks. Tests drive the callbacks
    /// directly and pass false to stay off the binary messenger.
    bool registerHandler = true,
  }) : _host = hostApi ?? g.DiscoveryHostApi() {
    if (registerHandler) g.DiscoveryFlutterApi.setUp(this);
  }

  final g.DiscoveryHostApi _host;

  final _found = StreamController<DiscoveredService>.broadcast();
  final _lost = StreamController<String>.broadcast();

  bool _available = false;
  LanUnavailable? _reason;

  @override
  Stream<DiscoveredService> get found => _found.stream;

  @override
  Stream<String> get lost => _lost.stream;

  @override
  bool get isAvailable => _available;

  @override
  LanUnavailable? get unavailableReason => _reason;

  /// Re-reads availability from the platform.
  ///
  /// Called before starting. Wi-Fi state changes arrive by callback afterwards,
  /// but the app can be launched already on or already off a network, and a
  /// first value of "unavailable" would be wrong half the time.
  Future<void> refresh() async {
    try {
      _available = await _host.isAvailable();
      _reason = _translate(await _host.unavailableReason());
    } on Object {
      // A platform that cannot answer is a platform that cannot discover.
      _available = false;
      _reason = LanUnavailable.noNetwork;
    }
  }

  @override
  Future<void> advertise({
    required String instanceId,
    required int addressHash,
    required int port,
  }) async {
    try {
      await _host.advertise(instanceId, addressHash, port);
    } on Object {
      // Registration can fail for reasons the app cannot fix — another service
      // holding the name, a network that dropped mid-call. Failing loudly here
      // would abort the transport's start and take the sockets with it, so the
      // device would stop relaying because it could not announce itself.
      _available = false;
      _reason ??= LanUnavailable.noNetwork;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    try {
      await _host.stopAdvertising();
    } on Object {
      // Nothing useful to do. The advertisement dies with the process anyway.
    }
  }

  @override
  Future<void> browse() async {
    try {
      await _host.browse();
    } on Object {
      _available = false;
      _reason ??= LanUnavailable.noNetwork;
    }
  }

  @override
  Future<void> stopBrowsing() async {
    try {
      await _host.stopBrowsing();
    } on Object {
      // As above.
    }
  }

  // ------------------------------------------------------- native callbacks

  @override
  void onServiceFound(g.ServiceInfo service) {
    if (_found.isClosed) return;
    _found.add(
      DiscoveredService(
        instanceId: service.instanceId,
        host: service.host,
        port: service.port,
        addressHash: service.addressHash,
      ),
    );
  }

  @override
  void onServiceLost(String instanceId) {
    if (!_lost.isClosed) _lost.add(instanceId);
  }

  @override
  void onAvailabilityChanged(bool available, g.DiscoveryUnavailable? reason) {
    _available = available;
    _reason = available ? null : _translate(reason);
  }

  static LanUnavailable? _translate(g.DiscoveryUnavailable? reason) =>
      switch (reason) {
        g.DiscoveryUnavailable.permissionDenied =>
          LanUnavailable.permissionDenied,
        g.DiscoveryUnavailable.noNetwork => LanUnavailable.noNetwork,
        null => null,
      };

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopBrowsing();
    await _found.close();
    await _lost.close();
  }
}
