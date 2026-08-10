import Foundation

/// Wire protocol constants. These MUST match `core_protocol` in Dart and
/// `RelayEngine.kt`. The shared vectors in `testvectors/` are the contract.
enum Wire {
    static let protocolVersion: UInt8 = 0x01
    static let headerLength = 20
    static let maxTtl: UInt8 = 7
    static let broadcastHash: UInt32 = 0
    static let fragmentHeaderLength = 5
    static let dedupMaxEntries = 2000
    static let dedupExpiry: TimeInterval = 600
    static let jitterMin: TimeInterval = 0.020
    static let jitterMax: TimeInterval = 0.150
    static let suppressionThreshold = 2
    static let witnessExpiry: TimeInterval = 30
}

enum FrameType: UInt8 {
    case announce = 0x01
    case handshake = 0x02
    case message = 0x03
    case ack = 0x04
    case fragment = 0x05
    case room = 0x06
    case voice = 0x07
    case leave = 0x08

    // Room catch-up and owner claims. An unknown type is dropped rather than
    // relayed, so every type Dart can emit has to be listed here or it stops
    // dead at the first iOS hop.
    case historyRequest = 0x09
    case historyReply = 0x0A
    case roomControl = 0x0B
    case batch = 0x0C

    // Somebody else's mail, handed over in person. Always arrives with ttl 1,
    // so it is recognised here and then dropped by the ordinary ttl rule
    // rather than by a special case.
    case courier = 0x0D
}

struct FrameFlags: Equatable {
    var encrypted = false
    var fragmented = false
    var compressed = false
    var urgent = false

    /// All flags clear. Needed explicitly because declaring `init(byte:)`
    /// suppresses the memberwise initialiser Swift would otherwise synthesise.
    init() {}

    init(byte: UInt8) {
        encrypted = byte & 0x01 != 0
        fragmented = byte & 0x02 != 0
        compressed = byte & 0x04 != 0
        urgent = byte & 0x08 != 0
    }

    var byte: UInt8 {
        (encrypted ? 0x01 : 0) | (fragmented ? 0x02 : 0)
            | (compressed ? 0x04 : 0) | (urgent ? 0x08 : 0)
    }
}

/// One frame on the wire. The relay reads only the header; `payload` stays
/// opaque and is never decrypted here.
struct Frame {
    let version: UInt8
    let type: FrameType
    let ttl: UInt8
    let flags: FrameFlags
    let msgId: Data
    let srcHash: UInt32
    let dstHash: UInt32
    let payload: Data

    var isBroadcast: Bool { dstHash == Wire.broadcastHash }

    static func decode(_ bytes: Data) -> Frame? {
        guard bytes.count >= Wire.headerLength else { return nil }
        let b = [UInt8](bytes)
        guard b[0] == Wire.protocolVersion else { return nil }
        guard let type = FrameType(rawValue: b[1]) else { return nil }
        let ttl = b[2]
        guard ttl <= Wire.maxTtl else { return nil }

        func u32(_ offset: Int) -> UInt32 {
            (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16)
                | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
        }

        return Frame(
            version: b[0],
            type: type,
            ttl: ttl,
            flags: FrameFlags(byte: b[3]),
            msgId: bytes.subdata(in: 4..<12),
            srcHash: u32(12),
            dstHash: u32(16),
            payload: bytes.subdata(in: Wire.headerLength..<bytes.count)
        )
    }

    func encode() -> Data {
        var out = Data(capacity: Wire.headerLength + payload.count)
        out.append(version)
        out.append(type.rawValue)
        out.append(ttl)
        out.append(flags.byte)
        out.append(msgId)
        for shift in [24, 16, 8, 0] { out.append(UInt8((srcHash >> UInt32(shift)) & 0xFF)) }
        for shift in [24, 16, 8, 0] { out.append(UInt8((dstHash >> UInt32(shift)) & 0xFF)) }
        out.append(payload)
        return out
    }

    func withDecrementedTtl() -> Frame {
        Frame(version: version, type: type, ttl: ttl - 1, flags: flags,
              msgId: msgId, srcHash: srcHash, dstHash: dstHash, payload: payload)
    }
}

/// Deduplication key.
///
/// Keying on `msgId` alone is wrong: all fragments of one message share a
/// `msgId` by design, so a msgId-only table drops every fragment after the
/// first and no multi-fragment message ever crosses a relay.
struct FrameKey: Hashable {
    let msgId: Data
    let fragmentIndex: Int

    init(msgId: Data, fragmentIndex: Int) {
        self.msgId = msgId
        self.fragmentIndex = fragmentIndex
    }

    init(frame: Frame) {
        msgId = frame.msgId
        if frame.flags.fragmented, frame.payload.count >= Wire.fragmentHeaderLength {
            let b = [UInt8](frame.payload)
            let index = Int(b[0]) << 8 | Int(b[1])
            let total = Int(b[2]) << 8 | Int(b[3])
            fragmentIndex = (total == 0 || index >= total) ? -1 : index
        } else {
            fragmentIndex = -1
        }
    }
}

enum RelayDrop: String {
    case duplicate
    case ownFrame
    case hopLimitReached
}

struct RelayDecision {
    var deliverLocally = false
    var relayFrame: Frame?
    var jitter: TimeInterval = 0
    var excludePeer: String?
    var drop: RelayDrop?
}

/// Bounded, expiring set of frame keys.
///
/// A repeated key deliberately does not refresh its position, or a peer
/// flooding one id could pin the table and evict everything else.
final class DedupSet {
    private var entries: [FrameKey: TimeInterval] = [:]
    private var order: [FrameKey] = []
    private let maxEntries: Int
    private let expiry: TimeInterval
    private let clock: () -> TimeInterval

    init(maxEntries: Int = Wire.dedupMaxEntries,
         expiry: TimeInterval = Wire.dedupExpiry,
         clock: @escaping () -> TimeInterval) {
        self.maxEntries = maxEntries
        self.expiry = expiry
        self.clock = clock
    }

    var count: Int { sweep(); return entries.count }

    func contains(_ key: FrameKey) -> Bool { sweep(); return entries[key] != nil }

    @discardableResult
    func addIfNew(_ key: FrameKey) -> Bool {
        sweep()
        if entries[key] != nil { return false }
        entries[key] = clock()
        order.append(key)
        while order.count > maxEntries {
            entries.removeValue(forKey: order.removeFirst())
        }
        return true
    }

    func clear() { entries.removeAll(); order.removeAll() }

    private func sweep() {
        let cutoff = clock() - expiry
        while let first = order.first, let at = entries[first], at <= cutoff {
            entries.removeValue(forKey: first)
            order.removeFirst()
        }
    }
}

/// Native relay. Mirrors `RelayEngine` in Dart exactly; both are pinned by
/// `testvectors/relay/decisions.json`.
///
/// This runs even when the Flutter engine is not alive, which is the whole
/// reason it exists in native code.
final class RelayEngine {
    private let localHash: UInt32
    private let seen: DedupSet
    private let clock: () -> TimeInterval
    private let jitterSource: (TimeInterval, TimeInterval) -> TimeInterval
    private var witnesses: [FrameKey: [String: TimeInterval]] = [:]

    private(set) var relayedCount = 0
    private(set) var droppedCount = 0

    init(localHash: UInt32,
         clock: @escaping () -> TimeInterval,
         jitter: ((TimeInterval, TimeInterval) -> TimeInterval)? = nil,
         dedup: DedupSet? = nil) {
        self.localHash = localHash
        self.clock = clock
        self.jitterSource = jitter ?? { min, max in TimeInterval.random(in: min...max) }
        self.seen = dedup ?? DedupSet(clock: clock)
    }

    func receive(_ frame: Frame, fromPeer: String) -> RelayDecision {
        sweepWitnesses()

        if frame.srcHash == localHash {
            droppedCount += 1
            return RelayDecision(drop: .ownFrame)
        }

        let key = FrameKey(frame: frame)

        if !seen.addIfNew(key) {
            recordWitness(key, peer: fromPeer)
            droppedCount += 1
            return RelayDecision(drop: .duplicate)
        }
        recordWitness(key, peer: fromPeer)

        let isForUs = frame.dstHash == localHash
        let deliverLocally = isForUs || frame.isBroadcast

        if isForUs {
            return RelayDecision(deliverLocally: true, excludePeer: fromPeer)
        }

        if frame.ttl == 0 {
            droppedCount += 1
            return RelayDecision(
                deliverLocally: deliverLocally,
                excludePeer: fromPeer,
                drop: deliverLocally ? nil : .hopLimitReached
            )
        }

        relayedCount += 1
        return RelayDecision(
            deliverLocally: deliverLocally,
            relayFrame: frame.withDecrementedTtl(),
            jitter: jitterSource(Wire.jitterMin, Wire.jitterMax),
            excludePeer: fromPeer
        )
    }

    func witness(_ key: FrameKey, fromPeer: String) { recordWitness(key, peer: fromPeer) }

    /// Whether a pending relay should be abandoned because enough other peers
    /// were heard carrying the same frame during the jitter window.
    func shouldSuppress(_ key: FrameKey, origin: String) -> Bool {
        sweepWitnesses()
        guard let heard = witnesses[key] else { return false }
        return heard.keys.filter { $0 != origin }.count >= Wire.suppressionThreshold
    }

    func clear() { seen.clear(); witnesses.removeAll() }

    private func recordWitness(_ key: FrameKey, peer: String) {
        witnesses[key, default: [:]][peer] = clock()
    }

    private func sweepWitnesses() {
        let cutoff = clock() - Wire.witnessExpiry
        for (key, peers) in witnesses {
            let live = peers.filter { $0.value > cutoff }
            if live.isEmpty { witnesses.removeValue(forKey: key) } else { witnesses[key] = live }
        }
    }
}
