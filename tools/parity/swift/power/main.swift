import Foundation

// Standalone parity runner: verifies PowerPolicy.swift against the shared
// power contract that also pins the Dart and Kotlin figures.
//
//   swiftc -O app/ios/Runner/Ble/PowerPolicy.swift \
//          tools/parity/swift/power/main.swift -o power_parity
//   ./power_parity testvectors/power/modes.json
//
// Only the cross-platform numbers are checked. `allowDuplicates` has no
// counterpart on Android; the battery figure is printed on screen in Settings,
// so a drift between it and what the app actually does is the app misquoting
// its own cost.
//
// Exits non-zero on any mismatch so CI can gate on it.

let arguments = CommandLine.arguments
let path = arguments.count > 1 ? arguments[1] : "testvectors/power/modes.json"

guard let raw = FileManager.default.contents(atPath: path),
      let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let modes = root["modes"] as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(2)
}

var failures: [String] = []

for vector in modes {
    guard let name = vector["name"] as? String,
          let drain = vector["estimatedDrainPercentPerHour"] as? Double,
          let interval = vector["announceIntervalMs"] as? Int
    else {
        failures.append("malformed vector: \(vector)")
        continue
    }

    let policy = PowerPolicy(mode: name)

    if policy.estimatedDrainPercentPerHour != drain {
        failures.append(
            "\(name) drain: got \(policy.estimatedDrainPercentPerHour), want \(drain)"
        )
    }
    if policy.announceIntervalMs != interval {
        failures.append(
            "\(name) announce: got \(policy.announceIntervalMs), want \(interval)"
        )
    }

    // Every `switch` here falls through to the balanced branch, so a mode name
    // that does not match any case would silently give balanced behaviour under
    // a different label. Comparing against balanced catches that.
    if name != PowerPolicy.balanced {
        let balanced = PowerPolicy(mode: PowerPolicy.balanced)
        if policy.estimatedDrainPercentPerHour == balanced.estimatedDrainPercentPerHour {
            failures.append("\(name) is indistinguishable from balanced — unknown mode name?")
        }
    }
}

// The set of modes must match too, or one platform could quietly offer a mode
// the others do not have.
let contractNames = Set(modes.compactMap { $0["name"] as? String })
if contractNames != Set(PowerPolicy.all) {
    failures.append("modes differ: Swift has \(PowerPolicy.all), contract has \(contractNames)")
}

if failures.isEmpty {
    print("power parity: \(modes.count)/\(modes.count) modes passed")
} else {
    for failure in failures {
        FileHandle.standardError.write(Data("FAIL \(failure)\n".utf8))
    }
    exit(1)
}
