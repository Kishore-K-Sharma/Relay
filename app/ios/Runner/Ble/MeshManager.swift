import CoreBluetooth
import Foundation
import Security

/// Drives the mesh on iOS in both BLE roles at once.
///
/// State Preservation and Restoration matters more here than on Android: iOS
/// relaunches the app **into the background** on a Bluetooth event, entering
/// Swift directly with no Flutter engine running. That is precisely why
/// `RelayEngine` and `PacketStore` are native — the relay has to work with Dart
/// absent.
///
/// ## Platform limits, stated plainly
///
/// While backgrounded, iOS moves the service UUID into the advertising
/// *overflow* area. That area is readable only by another iOS device explicitly
/// scanning for that exact UUID. **A backgrounded iPhone is effectively
/// invisible to Android scanners.** No amount of engineering removes this; it
/// is an Apple platform restriction shared by every BLE mesh app. The Phase 1.5
/// spike exists to measure how bad it is, and the UI must disclose it rather
/// than let users assume they are reachable when they are not.
final class MeshManager: NSObject {

    static let serviceUUID = CBUUID(string: "6F7B8A10-5C2D-4E91-9A3F-1D0E2C4B8A70")
    static let rxCharacteristicUUID = CBUUID(string: "6F7B8A11-5C2D-4E91-9A3F-1D0E2C4B8A70")
    static let txCharacteristicUUID = CBUUID(string: "6F7B8A12-5C2D-4E91-9A3F-1D0E2C4B8A70")

    /// Restoration identifiers must be stable across launches or iOS cannot
    /// hand the session back after relaunching the app.
    static let centralRestoreId = "dev.kishorek.relay.ble.central"
    static let peripheralRestoreId = "dev.kishorek.relay.ble.peripheral"

    /// Practical ceiling on simultaneous links before throughput collapses.
    static let maxConnections = 6

    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!

    private var relay: RelayEngine
    private let store: PacketStore
    private var power: PowerPolicy

    /// Outbound connections we initiated, keyed by peer id.
    private var connected: [String: CBPeripheral] = [:]
    private var writeCharacteristics: [String: CBCharacteristic] = [:]

    /// Centrals subscribed to our TX characteristic.
    private var subscribers: [CBCentral] = []
    private var txCharacteristic: CBMutableCharacteristic?

    /// Everyone currently reachable over a direct radio link.
    private(set) var peers: [String: PeerSnapshot] = [:]

    private var addressHash: UInt32 = 0
    private var stealth = false
    private var running = false
    private var scanning = false
    private var announceNickname = ""
    private var announcePayload = Data()
    private var announceTimer: DispatchSourceTimer?

    private(set) var framesReceived = 0
    private(set) var framesRelayed = 0
    private(set) var framesSuppressed = 0

    /// Called when a frame arrives for this device and Dart is running.
    var onFrameForUs: ((Data, String) -> Void)?
    var onPeerDiscovered: ((PeerSnapshot) -> Void)?
    var onPeerLost: ((String) -> Void)?
    var onStatusChanged: (() -> Void)?

    /// Kept for source compatibility with call sites that only care that
    /// *something* about the peer set changed.
    var onPeersChanged: (() -> Void)? {
        get { _onPeersChanged }
        set { _onPeersChanged = newValue }
    }
    private var _onPeersChanged: (() -> Void)?

    init(store: PacketStore, powerMode: String = PowerPolicy.balanced) {
        self.store = store
        self.power = PowerPolicy(mode: powerMode)
        self.relay = RelayEngine(localHash: 0, clock: { Date().timeIntervalSince1970 })
        super.init()
    }

    func start(addressHash: UInt32, powerMode: String) {
        self.addressHash = addressHash
        self.power = PowerPolicy(mode: powerMode)
        self.relay = RelayEngine(
            localHash: addressHash,
            clock: { Date().timeIntervalSince1970 }
        )

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreId]
        )
        peripheral = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreId]
        )
        running = true
        scheduleAnnounce()
        onStatusChanged?()
    }

    func stop() {
        central?.stopScan()
        peripheral?.stopAdvertising()
        connected.values.forEach { central?.cancelPeripheralConnection($0) }
        connected.removeAll()
        writeCharacteristics.removeAll()
        subscribers.removeAll()
        peers.keys.forEach { forgetPeer($0) }
        announceTimer?.cancel()
        announceTimer = nil
        running = false
        scanning = false
        onStatusChanged?()
    }

    var connectedPeerCount: Int { connected.count + subscribers.count }

    var isAdvertising: Bool { peripheral?.isAdvertising ?? false }

    func setStealth(_ enabled: Bool) {
        stealth = enabled
        if enabled {
            peripheral?.stopAdvertising()
            // A presence beacon would defeat the point of hiding.
            announceTimer?.cancel()
            announceTimer = nil
        } else {
            startAdvertising()
            scheduleAnnounce()
        }
        // Scanning and relaying continue regardless: carrying other people's
        // traffic is what provides cover for our own.
        onStatusChanged?()
    }

    /// Changes the duty cycle.
    ///
    /// Scanning must be restarted: `allowDuplicates` is fixed at scan start, and
    /// it is the setting that decides whether RSSI keeps updating as people
    /// move. Advertising needs no restart — CoreBluetooth gives no control over
    /// the advertising interval in the first place, which is why the iOS power
    /// modes differ less from each other than the Android ones do.
    func setPowerMode(_ mode: String) {
        guard power.mode != mode else { return }
        power = PowerPolicy(mode: mode)

        if central?.state == .poweredOn {
            central?.stopScan()
            scanning = false
            startScanning()
        }

        announceTimer?.cancel()
        announceTimer = nil
        scheduleAnnounce()
        onStatusChanged?()
    }

    func wipe() {
        relay.clear()
        store.wipe()
        announceNickname = ""
        announcePayload = Data()
        announceTimer?.cancel()
        announceTimer = nil
    }

    func drainInbox() -> [Data] { store.drainInbox() }

    func stats() -> RelayStatsSnapshot {
        RelayStatsSnapshot(
            framesReceived: framesReceived,
            framesRelayed: framesRelayed,
            framesDropped: relay.droppedCount,
            framesSuppressed: framesSuppressed,
            storedForForward: store.forwardDepth,
            inboxDepth: store.inboxDepth
        )
    }

    func statusSnapshot() -> ServiceStatus {
        let poweredOn = central?.state == .poweredOn
        return ServiceStatus(
            running: running,
            adapterOn: poweredOn,
            advertising: isAdvertising,
            scanning: scanning,
            connectedPeerCount: connectedPeerCount,
            // iOS always supports the peripheral role. Whether anyone can
            // actually see the advertisement while backgrounded is a different
            // and much worse problem, reported separately below.
            canAdvertise: true,
            powerMode: power.mode,
            detail: detailForStatus(poweredOn: poweredOn)
        )
    }

    private func detailForStatus(poweredOn: Bool) -> String? {
        if central?.state == .unauthorized || peripheral?.state == .unauthorized {
            return "This app is not allowed to use Bluetooth"
        }
        if central?.state == .unsupported {
            return "This device has no Bluetooth LE"
        }
        if !poweredOn { return "Bluetooth is off" }
        return nil
    }

    // -------------------------------------------------------------- presence

    /// Sets the presence beacon. An empty nickname suppresses it entirely.
    func setAnnounce(nickname: String, signedSessionKey: Data) {
        announceNickname = nickname
        announcePayload = signedSessionKey
        announceTimer?.cancel()
        announceTimer = nil
        scheduleAnnounce()
    }

    private func scheduleAnnounce() {
        guard !stealth, !announceNickname.isEmpty, running else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: power.announceInterval)
        timer.setEventHandler { [weak self] in self?.broadcastAnnounce() }
        timer.resume()
        announceTimer = timer
    }

    /// An announce is plaintext by necessity: strangers have to be able to read
    /// it or discovery cannot happen. It carries a nickname and a signed session
    /// key, never a long-term identifier.
    private func broadcastAnnounce() {
        var name = Array(announceNickname.utf8)
        if name.count > 32 { name = Array(name.prefix(32)) }

        var payload = Data([UInt8(name.count)])
        payload.append(contentsOf: name)
        payload.append(announcePayload)

        var msgId = Data(count: 8)
        _ = msgId.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 8, buffer.baseAddress!)
        }

        let frame = Frame(
            version: Wire.protocolVersion,
            type: .announce,
            // Presence is local. Flooding it seven hops would swamp the mesh
            // with beacons from people nobody can actually reach.
            ttl: 1,
            flags: FrameFlags(),
            msgId: msgId,
            srcHash: addressHash,
            dstHash: Wire.broadcastHash,
            payload: payload
        )
        broadcast(frame.encode())
    }

    // ---------------------------------------------------------- peer registry

    /// Records a sighting of a directly reachable peer.
    ///
    /// Only direct links are tracked, so `hopDistance` is always 1. Peers
    /// further out are known solely through announce frames, which this layer
    /// cannot interpret — Dart builds that wider view. Inferring distance from
    /// ttl would be wrong: a peer id here is a CoreBluetooth UUID while a frame
    /// header carries an address hash, and the two never meet.
    private func notePeer(_ peerId: String, rssi: Int?) {
        let existing = peers[peerId]
        let snapshot = PeerSnapshot(
            peerId: peerId,
            hopDistance: 1,
            isDirect: true,
            lastSeenMillis: Int64(Date().timeIntervalSince1970 * 1000),
            // Keep the last reading when an event carries none, rather than
            // blanking a signal bar the user is watching.
            rssi: rssi ?? existing?.rssi,
            nickname: existing?.nickname,
            sessionKeyHash: existing?.sessionKeyHash
        )
        peers[peerId] = snapshot
        onPeerDiscovered?(snapshot)
        _onPeersChanged?()
    }

    private func forgetPeer(_ peerId: String) {
        guard peers.removeValue(forKey: peerId) != nil else { return }
        onPeerLost?(peerId)
        _onPeersChanged?()
    }

    // ------------------------------------------------------------ relay path

    /// The hot path. May run with no Flutter engine alive. Operates entirely on
    /// opaque bytes and never decrypts.
    private func handleFrameFromRadio(_ bytes: Data, fromPeer: String) {
        framesReceived += 1
        guard let frame = Frame.decode(bytes) else { return }

        let decision = relay.receive(frame, fromPeer: fromPeer)

        if decision.deliverLocally {
            // Persist first, notify second. Durability must not depend on the
            // engine being alive to receive the callback.
            store.appendInbox(bytes)
            onFrameForUs?(bytes, fromPeer)
        }

        guard let relayFrame = decision.relayFrame else { return }
        let key = FrameKey(frame: frame)

        DispatchQueue.main.asyncAfter(deadline: .now() + decision.jitter) { [weak self] in
            guard let self else { return }
            if self.relay.shouldSuppress(key, origin: fromPeer) {
                self.framesSuppressed += 1
                return
            }
            self.framesRelayed += 1
            self.broadcast(relayFrame.encode(), excludePeerId: fromPeer)
        }
    }

    func broadcast(_ bytes: Data, targetPeerId: String? = nil, excludePeerId: String? = nil) {
        var delivered = 0

        if let tx = txCharacteristic, !subscribers.isEmpty {
            let targets = subscribers.filter { $0.identifier.uuidString != excludePeerId }
            if !targets.isEmpty {
                peripheral?.updateValue(bytes, for: tx, onSubscribedCentrals: targets)
                delivered += targets.count
            }
        }

        for (peerId, peer) in connected {
            if peerId == excludePeerId { continue }
            if let target = targetPeerId, peerId != target { continue }
            guard let characteristic = writeCharacteristics[peerId] else { continue }
            peer.writeValue(bytes, for: characteristic, type: .withoutResponse)
            delivered += 1
        }

        if delivered == 0, let frame = Frame.decode(bytes), !frame.isBroadcast {
            store.hold(bytes, targetHash: frame.dstHash)
        }
    }

    private func startAdvertising() {
        guard !stealth, peripheral?.state == .poweredOn else { return }
        // No local name: it is a stable identifier that would allow tracking
        // across sessions. Only the service UUID is published.
        peripheral?.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
    }

    private func startScanning() {
        guard central?.state == .poweredOn else { return }
        central?.scanForPeripherals(
            withServices: [Self.serviceUUID],
            // Duplicates are needed to track RSSI as people move, but they cost
            // battery, so the power policy decides.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: power.allowDuplicates]
        )
        scanning = true
        onStatusChanged?()
    }
}

/// A peer as native sees it. Mirrors `PeerSnapshot` in Kotlin.
struct PeerSnapshot {
    let peerId: String
    let hopDistance: Int
    let isDirect: Bool
    let lastSeenMillis: Int64
    let rssi: Int?
    let nickname: String?
    let sessionKeyHash: UInt32?
}

struct ServiceStatus {
    let running: Bool
    let adapterOn: Bool
    let advertising: Bool
    let scanning: Bool
    let connectedPeerCount: Int
    let canAdvertise: Bool
    let powerMode: String
    let detail: String?
}

struct RelayStatsSnapshot {
    let framesReceived: Int
    let framesRelayed: Int
    let framesDropped: Int
    let framesSuppressed: Int
    let storedForForward: Int
    let inboxDepth: Int
}

// MARK: - Central role

extension MeshManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            // Bluetooth going off is the commonest reason the mesh stops
            // working. Clearing the peers makes the UI say so instead of
            // showing people who can no longer be reached.
            scanning = false
            peers.keys.forEach { forgetPeer($0) }
        }
        onStatusChanged?()
    }

    /// Called when iOS relaunches the app into the background for a Bluetooth
    /// event. The connections handed back here are live and must be re-adopted.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        else { return }
        for peer in restored {
            peer.delegate = self
            connected[peer.identifier.uuidString] = peer
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let peerId = peripheral.identifier.uuidString
        // Recorded on every sighting, connected or not: signal strength is what
        // the radar screen draws, and it changes as people move.
        notePeer(peerId, rssi: RSSI.intValue)
        guard connected[peerId] == nil, connected.count < Self.maxConnections else { return }
        connected[peerId] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
        notePeer(peripheral.identifier.uuidString, rssi: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peerId = peripheral.identifier.uuidString
        connected.removeValue(forKey: peerId)
        writeCharacteristics.removeValue(forKey: peerId)
        if !subscribers.contains(where: { $0.identifier.uuidString == peerId }) {
            forgetPeer(peerId)
        }
    }
}

extension MeshManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics(
            [Self.rxCharacteristicUUID, Self.txCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let peerId = peripheral.identifier.uuidString
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.rxCharacteristicUUID:
                writeCharacteristics[peerId] = characteristic
            case Self.txCharacteristicUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }

        // Anything held for a peer goes out before new traffic.
        for held in store.takeFor(targetHash: 0) {
            broadcast(held, targetPeerId: peerId)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.txCharacteristicUUID,
              let value = characteristic.value else { return }
        handleFrameFromRadio(value, fromPeer: peripheral.identifier.uuidString)
    }
}

// MARK: - Peripheral role

extension MeshManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }

        let rx = CBMutableCharacteristic(
            type: Self.rxCharacteristicUUID,
            // Write-without-response: the mesh tolerates loss and retries, and
            // acknowledged writes would roughly halve throughput.
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: Self.txCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        peripheral.add(service)

        txCharacteristic = tx
        startAdvertising()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           let tx = services
               .compactMap({ $0.characteristics as? [CBMutableCharacteristic] })
               .flatMap({ $0 })
               .first(where: { $0.uuid == Self.txCharacteristicUUID }) {
            txCharacteristic = tx
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if subscribers.count >= Self.maxConnections {
            let dropped = subscribers.removeFirst()
            let droppedId = dropped.identifier.uuidString
            if connected[droppedId] == nil { forgetPeer(droppedId) }
        }
        subscribers.append(central)
        notePeer(central.identifier.uuidString, rssi: nil)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribers.removeAll { $0.identifier == central.identifier }
        let peerId = central.identifier.uuidString
        if connected[peerId] == nil { forgetPeer(peerId) }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.characteristic.uuid == Self.rxCharacteristicUUID,
                  let value = request.value else { continue }
            handleFrameFromRadio(value, fromPeer: request.central.identifier.uuidString)
        }
        // withoutResponse writes still arrive here; respond so the stack does
        // not stall on peers that requested a response.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
