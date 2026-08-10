/// The local-network transport: mDNS to find peers on the same Wi-Fi, TCP to
/// carry frames between them.
///
/// Runs beside the Bluetooth mesh, never instead of it. See [WifiTransport] for
/// what it is and is not good for.
library;

export 'src/lan_discovery.dart'
    show DiscoveredService, LanDiscovery, LanUnavailable;
export 'src/link_codec.dart' show LinkProtocolException;
export 'src/platform_lan_discovery.dart' show PlatformLanDiscovery;
export 'src/wifi_transport.dart' show WifiTransport;
