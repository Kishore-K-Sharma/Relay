import Foundation

/// Durable native storage for frames. Mirrors `PacketStore.kt`.
///
/// Two bounded queues:
///  - **inbox** — frames addressed to this device that arrived while the Dart
///    isolate was not running. Drained on next launch.
///  - **store-and-forward** — frames held for peers that were unreachable.
///
/// The bounds are mandatory, not defensive: without them a nearby device can
/// fill the disk by transmitting continuously to a phone whose app is never
/// opened.
final class PacketStore {

    static let maxInboxFrames = 2000
    static let maxInboxBytes = 4 * 1024 * 1024
    static let maxForwardFrames = 500
    static let maxForwardBytes = 4 * 1024 * 1024
    static let forwardExpiry: TimeInterval = 24 * 60 * 60

    private struct Held {
        let frame: Data
        let storedAt: TimeInterval
        let targetHash: UInt32
    }

    private let lock = NSLock()
    private let inboxURL: URL
    private let forwardURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        inboxURL = base.appendingPathComponent("relay_inbox.bin")
        forwardURL = base.appendingPathComponent("relay_forward.bin")
    }

    // MARK: - Inbox

    func appendInbox(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        var items = readAll(inboxURL)
        items.append(Held(frame: frame, storedAt: Date().timeIntervalSince1970, targetHash: 0))
        writeAll(inboxURL, trim(items, Self.maxInboxFrames, Self.maxInboxBytes))
    }

    func drainInbox() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let items = readAll(inboxURL)
        try? FileManager.default.removeItem(at: inboxURL)
        return items.map(\.frame)
    }

    var inboxDepth: Int {
        lock.lock(); defer { lock.unlock() }
        return readAll(inboxURL).count
    }

    // MARK: - Store and forward

    func hold(_ frame: Data, targetHash: UInt32) {
        lock.lock(); defer { lock.unlock() }
        var items = expire(readAll(forwardURL))
        items.append(
            Held(frame: frame, storedAt: Date().timeIntervalSince1970, targetHash: targetHash)
        )
        writeAll(forwardURL, trim(items, Self.maxForwardFrames, Self.maxForwardBytes))
    }

    func takeFor(targetHash: UInt32) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let items = expire(readAll(forwardURL))
        let matching = items.filter { $0.targetHash == targetHash }
        writeAll(forwardURL, items.filter { $0.targetHash != targetHash })
        return matching.map(\.frame)
    }

    var forwardDepth: Int {
        lock.lock(); defer { lock.unlock() }
        return expire(readAll(forwardURL)).count
    }

    func wipe() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: inboxURL)
        try? FileManager.default.removeItem(at: forwardURL)
    }

    // MARK: - Private

    private func expire(_ items: [Held]) -> [Held] {
        let cutoff = Date().timeIntervalSince1970 - Self.forwardExpiry
        return items.filter { $0.storedAt > cutoff }
    }

    private func trim(_ items: [Held], _ maxFrames: Int, _ maxBytes: Int) -> [Held] {
        var out = items
        while out.count > maxFrames { out.removeFirst() }
        var total = out.reduce(0) { $0 + $1.frame.count }
        while total > maxBytes, !out.isEmpty {
            total -= out.removeFirst().frame.count
        }
        return out
    }

    private func readAll(_ url: URL) -> [Held] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [Held] = []
        var offset = 0

        // A truncated or corrupt store must never stop the mesh running:
        // whatever parses is kept, the remainder is discarded.
        while offset + 16 <= data.count {
            let length = Int(readU32(data, offset))
            let target = readU32(data, offset + 4)
            let stored = readU64(data, offset + 8)
            offset += 16
            guard length > 0, offset + length <= data.count else { break }
            out.append(
                Held(
                    frame: data.subdata(in: offset..<(offset + length)),
                    storedAt: TimeInterval(stored),
                    targetHash: target
                )
            )
            offset += length
        }
        return out
    }

    private func writeAll(_ url: URL, _ items: [Held]) {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var out = Data()
        for item in items {
            appendU32(&out, UInt32(item.frame.count))
            appendU32(&out, item.targetHash)
            appendU64(&out, UInt64(item.storedAt))
            out.append(item.frame)
        }
        try? out.write(to: url, options: .atomic)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data[data.startIndex + offset..<data.startIndex + offset + 4])
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        for shift in [24, 16, 8, 0] { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    private func appendU64(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
