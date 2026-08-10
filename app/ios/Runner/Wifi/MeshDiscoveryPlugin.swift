import Flutter
import Foundation

/// Implements the Pigeon discovery host API on Apple platforms.
///
/// The only Swift file that knows the generated discovery types exist, mirror
/// of `MeshBlePlugin` on the Bluetooth side. It translates and hops threads
/// and holds no state of its own.
final class MeshDiscoveryPlugin: NSObject, DiscoveryHostApi {

  static func register(with messenger: FlutterBinaryMessenger) -> MeshDiscoveryPlugin {
    let plugin = MeshDiscoveryPlugin(messenger: messenger)
    DiscoveryHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
    return plugin
  }

  private let flutter: DiscoveryFlutterApi
  private let discoverer = LanDiscoverer()

  init(messenger: FlutterBinaryMessenger) {
    flutter = DiscoveryFlutterApi(binaryMessenger: messenger)
    super.init()

    discoverer.onFound = { [weak self] found in
      guard let self else { return }
      let service = ServiceInfo(
        instanceId: found.instanceId,
        host: found.host,
        port: Int64(found.port),
        addressHash: Int64(found.addressHash)
      )
      // Bonjour delegates already run on the main run loop, but the path
      // monitor does not, and Pigeon requires the main thread for all of them.
      self.onMain { self.flutter.onServiceFound(service: service) { _ in } }
    }

    discoverer.onLost = { [weak self] instanceId in
      guard let self else { return }
      self.onMain { self.flutter.onServiceLost(instanceId: instanceId) { _ in } }
    }

    discoverer.onAvailabilityChanged = { [weak self] available, reason in
      guard let self else { return }
      let translated = Self.translate(reason)
      self.onMain {
        self.flutter.onAvailabilityChanged(available: available, reason: translated) { _ in }
      }
    }

    discoverer.startMonitoring()
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  // MARK: - Host API

  func isAvailable() throws -> Bool {
    discoverer.isAvailable
  }

  func unavailableReason() throws -> DiscoveryUnavailable? {
    Self.translate(discoverer.unavailableReason)
  }

  func advertise(
    instanceId: String,
    addressHash: Int64,
    port: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Pigeon widens every integer to 64 bits. Both values are 32-bit and must
    // be narrowed before they reach the platform, or the advertised address
    // will never match a frame header.
    discoverer.advertise(
      instanceId: instanceId,
      addressHash: UInt32(truncatingIfNeeded: addressHash),
      port: Int(port)
    )
    completion(.success(()))
  }

  func stopAdvertising(completion: @escaping (Result<Void, Error>) -> Void) {
    discoverer.stopAdvertising()
    completion(.success(()))
  }

  func browse(completion: @escaping (Result<Void, Error>) -> Void) {
    discoverer.browse()
    completion(.success(()))
  }

  func stopBrowsing(completion: @escaping (Result<Void, Error>) -> Void) {
    discoverer.stopBrowsing()
    completion(.success(()))
  }

  private static func translate(
    _ reason: LanDiscoverer.Unavailable?
  ) -> DiscoveryUnavailable? {
    switch reason {
    case .permissionDenied: return .permissionDenied
    case .noNetwork: return .noNetwork
    case nil: return nil
    }
  }
}
