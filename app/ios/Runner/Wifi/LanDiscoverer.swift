import Foundation
import Network

/// Bonjour discovery on Apple platforms.
///
/// Two deliberate choices, both worth knowing before changing anything here.
///
/// **Bonjour, not a UDP beacon.** Since iOS 14, sending or receiving multicast
/// and broadcast requires the `com.apple.developer.networking.multicast`
/// entitlement, which Apple grants by application. Bonjour needs only a usage
/// string, and Android's NsdManager speaks the same protocol, so one mechanism
/// serves both platforms with no approval process.
///
/// **`NetService`, not `NWBrowser`.** The sockets belong to Dart, so this class
/// has to publish a service on a port it does not own and resolve a peer to a
/// plain IP and port. `NetService` does both directly. `NWBrowser` returns
/// endpoints that only resolve into an address by opening an `NWConnection`,
/// which would mean a second, pointless connection to every peer. `NetService`
/// is soft-deprecated as of iOS 15 but not removed; if it ever is, the
/// replacement is `NWBrowser` plus that extra connection.
final class LanDiscoverer: NSObject {

  /// Must match the Android side exactly or the two platforms never meet.
  static let serviceType = "_kishorek-relay._tcp"
  static let domain = "local."

  /// TXT keys, likewise shared with Android.
  static let txtHash = "h"
  static let txtInstance = "i"

  enum Unavailable {
    case permissionDenied
    case noNetwork
  }

  struct Found {
    let instanceId: String
    let host: String
    let port: Int
    let addressHash: UInt32
  }

  var onFound: ((Found) -> Void)?
  var onLost: ((String) -> Void)?
  var onAvailabilityChanged: ((Bool, Unavailable?) -> Void)?

  private var published: NetService?
  private var browser: NetServiceBrowser?

  /// Resolving services, held because `NetService` does no work unless someone
  /// keeps a strong reference to it for the duration of the resolve.
  private var resolving: [String: NetService] = [:]

  private var registeredName: String?

  private let monitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "dev.kishorek.relay.wifi.path")

  private var onWifi = false

  /// True once a browse has failed in a way that looks like a refused
  /// local-network permission.
  ///
  /// iOS provides no API to ask. This is the best signal available, and it is
  /// a guess: a refused permission usually produces silence rather than an
  /// error, so the app can find itself unable to say why nothing is happening.
  private var browseFailed = false

  // ---------------------------------------------------------- availability

  func startMonitoring() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      // Wi-Fi and wired only. Cellular carries no peers, and advertising there
      // would cost battery for a discovery that cannot succeed.
      let usable = path.status == .satisfied
        && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
      guard usable != self.onWifi else { return }
      self.onWifi = usable
      self.onAvailabilityChanged?(self.isAvailable, self.unavailableReason)
    }
    monitor.start(queue: monitorQueue)
  }

  func stopMonitoring() {
    monitor.cancel()
  }

  var isAvailable: Bool { onWifi && !browseFailed }

  var unavailableReason: Unavailable? {
    if !onWifi { return .noNetwork }
    if browseFailed { return .permissionDenied }
    return nil
  }

  // ----------------------------------------------------------- advertising

  func advertise(instanceId: String, addressHash: UInt32, port: Int) {
    stopAdvertising()

    let service = NetService(
      domain: Self.domain,
      type: Self.serviceType,
      name: instanceId,
      port: Int32(port)
    )
    service.delegate = self

    var txt: [String: Data] = [:]
    txt[Self.txtInstance] = Data(instanceId.utf8)
    // Hex rather than a raw integer: TXT values are bytes, and a signed decimal
    // would have to be parsed differently on each platform.
    txt[Self.txtHash] = Data(String(addressHash, radix: 16).utf8)
    service.setTXTRecord(NetService.data(fromTXTRecord: txt))

    published = service
    registeredName = instanceId
    service.publish()
  }

  func stopAdvertising() {
    published?.stop()
    published = nil
    registeredName = nil
  }

  // -------------------------------------------------------------- browsing

  func browse() {
    guard browser == nil else { return }
    browseFailed = false

    let browser = NetServiceBrowser()
    browser.delegate = self
    self.browser = browser
    browser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
  }

  func stopBrowsing() {
    browser?.stop()
    browser = nil
    resolving.removeAll()
  }
}

// MARK: - NetServiceDelegate

extension LanDiscoverer: NetServiceDelegate {

  func netServiceDidPublish(_ sender: NetService) {
    // The system renames on conflict, so the authoritative name is the one it
    // gives back. Filtering our own advertisement depends on having it right.
    registeredName = sender.name
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    onAvailabilityChanged?(false, .noNetwork)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    defer { resolving.removeValue(forKey: sender.name) }

    guard
      let data = sender.txtRecordData(),
      let host = Self.firstAddress(of: sender)
    else { return }

    let txt = NetService.dictionary(fromTXTRecord: data)
    let instanceId = txt[Self.txtInstance].flatMap { String(data: $0, encoding: .utf8) }
      ?? sender.name
    guard instanceId != registeredName else { return }

    guard
      let hashText = txt[Self.txtHash].flatMap({ String(data: $0, encoding: .utf8) }),
      let hash = UInt32(hashText, radix: 16)
    else { return }

    onFound?(
      Found(instanceId: instanceId, host: host, port: sender.port, addressHash: hash)
    )
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    // Routine. mDNS caches outlive the devices behind them.
    resolving.removeValue(forKey: sender.name)
  }

  /// The first IPv4 address, as dotted quad.
  ///
  /// IPv4 only, deliberately. A link-local IPv6 address needs a scope id to be
  /// dialled, `dart:io` has no way to attach one, and every router that matters
  /// here hands out IPv4.
  private static func firstAddress(of service: NetService) -> String? {
    guard let addresses = service.addresses else { return nil }

    for data in addresses {
      let host: String? = data.withUnsafeBytes { raw -> String? in
        guard let base = raw.bindMemory(to: sockaddr.self).baseAddress else { return nil }
        guard base.pointee.sa_family == sa_family_t(AF_INET) else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
          getnameinfo(
            base,
            socklen_t(data.count),
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
          ) == 0
        else { return nil }
        return String(cString: buffer)
      }
      if let host { return host }
    }
    return nil
  }
}

// MARK: - NetServiceBrowserDelegate

extension LanDiscoverer: NetServiceBrowserDelegate {

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    guard service.name != registeredName else { return }
    // Held strongly for the duration: a NetService with no owner stops
    // resolving and the delegate is never called.
    resolving[service.name] = service
    service.delegate = self
    service.resolve(withTimeout: 5)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didRemove service: NetService,
    moreComing: Bool
  ) {
    resolving.removeValue(forKey: service.name)
    onLost?(service.name)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    browseFailed = true
    self.browser = nil
    onAvailabilityChanged?(false, .permissionDenied)
  }
}
