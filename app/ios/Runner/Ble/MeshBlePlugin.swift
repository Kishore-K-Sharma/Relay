import CoreBluetooth
import Flutter
import Foundation
import UIKit

/// Implements the Pigeon host API and pushes native events back to Dart.
///
/// The only file in the iOS sources that knows generated Pigeon types exist.
/// Everything below it is plain Swift that runs with no Flutter engine alive —
/// which is the entire reason the relay is native.
final class MeshBlePlugin: NSObject, BleHostApi {

    private let mesh: MeshManager
    private let flutter: BleFlutterApi

    init(messenger: FlutterBinaryMessenger) {
        self.mesh = MeshManager(store: PacketStore())
        self.flutter = BleFlutterApi(binaryMessenger: messenger)
        super.init()

        // Pigeon callbacks must be made on the main thread. CoreBluetooth
        // delivers on its own queue, so every push hops across.
        mesh.onFrameForUs = { [weak self] frame, peerId in
            DispatchQueue.main.async {
                self?.flutter.onFrameReceived(
                    frame: FlutterStandardTypedData(bytes: frame),
                    fromPeerId: peerId
                ) { _ in }
            }
        }
        mesh.onPeerDiscovered = { [weak self] peer in
            DispatchQueue.main.async {
                self?.flutter.onPeerDiscovered(peer: Self.toPigeon(peer)) { _ in }
            }
        }
        mesh.onPeerLost = { [weak self] peerId in
            DispatchQueue.main.async {
                self?.flutter.onPeerLost(peerId: peerId) { _ in }
            }
        }
        mesh.onStatusChanged = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.flutter.onStatusChanged(status: self.currentStatus()) { _ in }
            }
        }
    }

    @discardableResult
    static func register(with messenger: FlutterBinaryMessenger) -> MeshBlePlugin {
        let plugin = MeshBlePlugin(messenger: messenger)
        BleHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
        return plugin
    }

    // -------------------------------------------------------------- host api

    /// On iOS the Bluetooth prompt appears the first time a manager is created,
    /// so authorisation is read rather than requested up front.
    func hasPermissions() throws -> Bool {
        CBManager.authorization == .allowedAlways
    }

    /// Resolves as soon as the user answers.
    ///
    /// There is no API to trigger the prompt directly: instantiating a
    /// `CBCentralManager` is what shows it. Polling is therefore the only way
    /// to observe the answer, and the poll is bounded so a user who walks away
    /// from the dialog does not leave a Dart future pending forever.
    func requestPermissions(completion: @escaping (Result<Bool, Error>) -> Void) {
        if CBManager.authorization != .notDetermined {
            completion(.success(CBManager.authorization == .allowedAlways))
            return
        }

        _ = probeManager
        pollAuthorization(remaining: 60, completion: completion)
    }

    /// Created solely to trigger the system prompt. Held so ARC does not
    /// destroy it — and the dialog with it — before the user answers.
    private lazy var probeManager = CBCentralManager(delegate: nil, queue: nil)

    private func pollAuthorization(
        remaining: Int,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        if CBManager.authorization != .notDetermined {
            completion(.success(CBManager.authorization == .allowedAlways))
            return
        }
        guard remaining > 0 else {
            completion(.success(false))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollAuthorization(remaining: remaining - 1, completion: completion)
        }
    }

    func isBluetoothEnabled() throws -> Bool {
        mesh.statusSnapshot().adapterOn
    }

    /// iOS deliberately offers no way to turn the radio on programmatically.
    /// Opening Settings is the most an app is permitted to do, and pretending
    /// otherwise would just leave the user waiting for something to happen.
    func requestEnableBluetooth() throws {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    func start(addressHash: Int64, powerMode: String) throws {
        // Pigeon widens every integer to 64 bits. The address hash is a
        // truncated 32-bit value and must be narrowed back before it reaches
        // the relay, or it will never match a frame header.
        mesh.start(addressHash: UInt32(truncatingIfNeeded: addressHash), powerMode: powerMode)
    }

    func stop() throws { mesh.stop() }

    func sendFrame(
        frame: FlutterStandardTypedData,
        targetPeerId: String?,
        excludePeerId: String?
    ) throws {
        mesh.broadcast(frame.data, targetPeerId: targetPeerId, excludePeerId: excludePeerId)
    }

    func getPeers() throws -> [PeerInfo] {
        mesh.peers.values.map(Self.toPigeon)
    }

    /// Separate from the protocol method: Swift will not let a throwing and a
    /// non-throwing overload share a signature, and the event callbacks need a
    /// version they can call without a `try`.
    private func currentStatus() -> TransportStatus {
        let s = mesh.statusSnapshot()
        return TransportStatus(
            running: s.running,
            adapterOn: s.adapterOn,
            permissionsGranted: CBManager.authorization == .allowedAlways,
            advertising: s.advertising,
            scanning: s.scanning,
            connectedPeerCount: Int64(s.connectedPeerCount),
            canAdvertise: s.canAdvertise,
            powerMode: s.powerMode,
            detail: s.detail
        )
    }

    func getStatus() throws -> TransportStatus { currentStatus() }

    func getStats() throws -> RelayStats {
        let s = mesh.stats()
        return RelayStats(
            framesReceived: Int64(s.framesReceived),
            framesRelayed: Int64(s.framesRelayed),
            framesDropped: Int64(s.framesDropped),
            framesSuppressed: Int64(s.framesSuppressed),
            storedForForward: Int64(s.storedForForward),
            inboxDepth: Int64(s.inboxDepth)
        )
    }

    func drainInbox() throws -> [FlutterStandardTypedData] {
        mesh.drainInbox().map { FlutterStandardTypedData(bytes: $0) }
    }

    func setPowerMode(mode: String) throws { mesh.setPowerMode(mode) }

    func setStealthMode(enabled: Bool) throws { mesh.setStealth(enabled) }

    func setAnnounce(nickname: String, signedSessionKey: FlutterStandardTypedData) throws {
        mesh.setAnnounce(nickname: nickname, signedSessionKey: signedSessionKey.data)
    }

    func wipe() throws { mesh.wipe() }

    /// iOS has no equivalent of Android's OEM battery killers. The system does
    /// throttle background Bluetooth, but there is no exemption to ask for, so
    /// prompting the user would only waste their time.
    func needsBatteryExemption() throws -> Bool { false }

    func openBatterySettings() throws {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    private static func toPigeon(_ peer: PeerSnapshot) -> PeerInfo {
        PeerInfo(
            peerId: peer.peerId,
            hopDistance: Int64(peer.hopDistance),
            isDirect: peer.isDirect,
            lastSeenMillis: peer.lastSeenMillis,
            rssi: peer.rssi.map(Int64.init),
            nickname: peer.nickname,
            sessionKeyHash: peer.sessionKeyHash.map(Int64.init)
        )
    }
}
