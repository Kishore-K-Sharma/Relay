/// Test doubles for the local-network transport.
///
/// Kept out of the main library so nothing shipping in the app can reach a
/// fake by accident.
library;

export 'src/fake_lan_discovery.dart' show FakeLanDiscovery, FakeLanNetwork;
