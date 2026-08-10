package dev.kishorek.relay.ble

import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanSettings

/**
 * Trades discovery latency against battery.
 *
 * The mode is user-visible and user-chosen. Silently draining a phone to keep a
 * mesh lively is the fastest way to get uninstalled, so the app shows which
 * mode is active and what it costs rather than deciding on the user's behalf.
 *
 * The figures live in [PowerModes], which has no Android dependency and is
 * checked against the same contract as the Dart and Swift implementations.
 * What remains here is the mapping onto Android's own constants, which has no
 * equivalent on the other platforms and so nothing to be compared against.
 */
class PowerPolicy(var mode: String = PowerModes.BALANCED) {

    companion object {
        const val PERFORMANCE = PowerModes.PERFORMANCE
        const val BALANCED = PowerModes.BALANCED
        const val SAVER = PowerModes.SAVER
    }

    fun scanWindowMs(): Long = PowerModes.scanWindowMs(mode)

    fun scanIdleMs(): Long = PowerModes.scanIdleMs(mode)

    fun announceIntervalMs(): Long = PowerModes.announceIntervalMs(mode)

    fun estimatedDrainPercentPerHour(): Double =
        PowerModes.estimatedDrainPercentPerHour(mode)

    fun scanMode(): Int = when (mode) {
        PERFORMANCE -> ScanSettings.SCAN_MODE_LOW_LATENCY
        SAVER -> ScanSettings.SCAN_MODE_LOW_POWER
        else -> ScanSettings.SCAN_MODE_BALANCED
    }

    fun advertiseMode(): Int = when (mode) {
        PERFORMANCE -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
        SAVER -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
        else -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
    }

    fun txPower(): Int = when (mode) {
        PERFORMANCE -> AdvertiseSettings.ADVERTISE_TX_POWER_HIGH
        SAVER -> AdvertiseSettings.ADVERTISE_TX_POWER_LOW
        else -> AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
    }
}
