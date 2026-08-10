import Foundation

// Standalone parity runner: verifies RelayEngine.swift against the shared
// vectors that also pin the Dart and Kotlin implementations.
//
//   swift app/ios/Runner/Ble/RelayEngine.swift \
//         tools/parity/swift/relay/main.swift \
//         testvectors/relay/decisions.json
//
// Exits non-zero on any mismatch so CI can gate on it.

func unhex(_ hex: String) -> Data {
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

func hexOf(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

struct Failure: Error { let message: String }

func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(message: message()) }
}

let arguments = CommandLine.arguments
let vectorPath = arguments.count > 1 ? arguments[1] : "testvectors/relay/decisions.json"

guard let raw = FileManager.default.contents(atPath: vectorPath),
      let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let vectors = root["vectors"] as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("cannot read \(vectorPath)\n".utf8))
    exit(2)
}

// Constants must agree with the vector file, or the implementations have
// silently diverged on policy even if every decision happens to match.
var failures: [String] = []

func checkConstant(_ name: String, _ actual: Int, _ expected: Any?) {
    guard let expected = expected as? Int else { return }
    if actual != expected {
        failures.append("constant \(name): swift=\(actual) vectors=\(expected)")
    }
}

checkConstant("suppressionThreshold", Wire.suppressionThreshold, root["suppressionThreshold"])
checkConstant("jitterMinMs", Int(Wire.jitterMin * 1000), root["jitterMinMs"])
checkConstant("jitterMaxMs", Int(Wire.jitterMax * 1000), root["jitterMaxMs"])
checkConstant("dedupMaxEntries", Wire.dedupMaxEntries, root["dedupMaxEntries"])
checkConstant("dedupExpirySeconds", Int(Wire.dedupExpiry), root["dedupExpirySeconds"])

var passed = 0

for vector in vectors {
    let name = vector["name"] as? String ?? "<unnamed>"
    do {
        guard let localHash = vector["localHash"] as? Int,
              let input = vector["input"] as? [String: Any],
              let expected = vector["expect"] as? [String: Any],
              let priorSeen = vector["priorSeen"] as? [[String: String]],
              let fromPeer = input["fromPeer"] as? String,
              let encodedHex = input["encodedHex"] as? String
        else { throw Failure(message: "malformed vector") }

        let now: TimeInterval = 0
        let dedup = DedupSet(clock: { now })
        for entry in priorSeen {
            dedup.addIfNew(FrameKey(
                msgId: unhex(entry["msgId"]!),
                fragmentIndex: Int(entry["fragmentIndex"]!)!
            ))
        }

        let engine = RelayEngine(
            localHash: UInt32(localHash),
            clock: { now },
            jitter: { min, _ in min },
            dedup: dedup
        )

        guard let frame = Frame.decode(unhex(encodedHex)) else {
            throw Failure(message: "frame failed to decode")
        }

        // Round-tripping the frame proves the Swift codec agrees with Dart's.
        try check(hexOf(frame.encode()) == encodedHex,
                  "re-encode mismatch\n  expected \(encodedHex)\n  actual   \(hexOf(frame.encode()))")

        let decision = engine.receive(frame, fromPeer: fromPeer)

        try check(decision.deliverLocally == (expected["deliverLocally"] as! Bool),
                  "deliverLocally: got \(decision.deliverLocally)")
        try check((decision.relayFrame != nil) == (expected["relay"] as! Bool),
                  "relay: got \(decision.relayFrame != nil)")

        let expectedDrop = expected["drop"] as? String
        try check(decision.drop?.rawValue == expectedDrop,
                  "drop: got \(decision.drop?.rawValue ?? "nil"), want \(expectedDrop ?? "nil")")

        if let expectedTtl = expected["relayTtl"] as? Int {
            try check(Int(decision.relayFrame!.ttl) == expectedTtl,
                      "relayTtl: got \(decision.relayFrame!.ttl), want \(expectedTtl)")
        }
        if let excludePeer = expected["excludePeer"] as? String, decision.drop == nil {
            try check(decision.excludePeer == excludePeer, "excludePeer mismatch")
        }

        passed += 1
    } catch let error as Failure {
        failures.append("\(name): \(error.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

if failures.isEmpty {
    print("relay parity: \(passed)/\(vectors.count) vectors passed")
    exit(0)
} else {
    for failure in failures { print("FAIL \(failure)") }
    print("relay parity: \(passed)/\(vectors.count) passed, \(failures.count) failures")
    exit(1)
}
