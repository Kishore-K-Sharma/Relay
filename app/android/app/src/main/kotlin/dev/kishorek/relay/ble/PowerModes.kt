package dev.kishorek.relay.ble

/**
 * The cross-platform half of the power modes.
 *
 * Deliberately free of Android imports so it can be compiled and checked on its
 * own against `testvectors/power/modes.json`, which also pins the Dart and
 * Swift figures. [estimatedDrainPercentPerHour] is printed on screen next to
 * the user's choice, so a drift between it and the duty cycle actually run is
 * the app misquoting its own cost — and a background app that lies about
 * battery is a background app that gets uninstalled.
 *
 * The scan and advertise constants live in [PowerPolicy] instead: they are
 * Android enums with no counterpart on the other platforms, so there is nothing
 * to compare them against.
 */
object PowerModes {
    const val PERFORMANCE = "performance"
    const val BALANCED = "balanced"
    const val SAVER = "saver"

    /**
     * The floor. Reachable, barely: one announce every five minutes and a scan
     * window short enough to be nearly free. For somebody on 4% who still needs
     * to be found.
     */
    const val ULTRA_LOW = "ultraLow"

    val all = listOf(PERFORMANCE, BALANCED, SAVER, ULTRA_LOW)

    /** Rough hourly battery cost, shown in settings so the choice is informed. */
    fun estimatedDrainPercentPerHour(mode: String): Double = when (mode) {
        PERFORMANCE -> 12.0
        SAVER -> 2.5
        ULTRA_LOW -> 1.0
        else -> 5.0
    }

    /**
     * How often to rebroadcast the presence beacon.
     *
     * Announces are cheap individually and ruinous in aggregate: in a crowd of
     * two hundred, every beacon is heard by everyone. This interval is the main
     * thing between the mesh and self-inflicted congestion.
     */
    fun announceIntervalMs(mode: String): Long = when (mode) {
        PERFORMANCE -> 15_000
        SAVER -> 120_000
        ULTRA_LOW -> 300_000
        else -> 45_000
    }

    /** How long to scan in each duty cycle. */
    fun scanWindowMs(mode: String): Long = when (mode) {
        PERFORMANCE -> 10_000
        SAVER -> 2_000
        ULTRA_LOW -> 1_000
        else -> 5_000
    }

    /** How long to stay quiet between scan windows. */
    fun scanIdleMs(mode: String): Long = when (mode) {
        PERFORMANCE -> 0
        SAVER -> 25_000
        ULTRA_LOW -> 60_000
        else -> 8_000
    }
}
