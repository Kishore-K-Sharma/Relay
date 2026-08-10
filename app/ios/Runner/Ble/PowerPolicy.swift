import Foundation

/// Trades discovery latency against battery. Mirrors `PowerModes.kt`.
///
/// Deliberately free of CoreBluetooth so it can be compiled and checked on its
/// own against `testvectors/power/modes.json`, which also pins the Dart and
/// Kotlin figures. `estimatedDrainPercentPerHour` is printed on screen next to
/// the user's choice, so a drift between it and what the app actually does is
/// the app misquoting its own cost.
///
/// iOS gives an app far less control here than Android does. There is no
/// advertising-interval setting and no transmit-power setting; `allowDuplicates`
/// and the announce interval are most of what can actually be varied. The
/// modes therefore differ less from each other on iOS than on Android, and the
/// battery figures are correspondingly rougher.
struct PowerPolicy {
    static let performance = "performance"
    static let balanced = "balanced"
    static let saver = "saver"

    /// The floor. Reachable, barely: one announce every five minutes. For
    /// somebody on 4% who still needs to be found.
    static let ultraLow = "ultraLow"

    static let all = [performance, balanced, saver, ultraLow]

    let mode: String

    init(mode: String = PowerPolicy.balanced) { self.mode = mode }

    /// Whether to report a peer on every advertisement rather than once.
    ///
    /// This is what keeps RSSI current as people move, and it is the single
    /// most expensive scanning option on iOS.
    var allowDuplicates: Bool { mode == PowerPolicy.performance }

    /// Rough hourly battery cost, shown in settings so the choice is informed.
    var estimatedDrainPercentPerHour: Double {
        switch mode {
        case PowerPolicy.performance: return 12.0
        case PowerPolicy.saver: return 2.5
        case PowerPolicy.ultraLow: return 1.0
        default: return 5.0
        }
    }

    /// How often to rebroadcast the presence beacon, in milliseconds.
    ///
    /// Announces are cheap individually and ruinous in aggregate: in a crowd of
    /// two hundred, every beacon is heard by everyone. This interval is the
    /// main thing between the mesh and self-inflicted congestion.
    var announceIntervalMs: Int {
        switch mode {
        case PowerPolicy.performance: return 15_000
        case PowerPolicy.saver: return 120_000
        case PowerPolicy.ultraLow: return 300_000
        default: return 45_000
        }
    }

    var announceInterval: DispatchTimeInterval { .milliseconds(announceIntervalMs) }
}
