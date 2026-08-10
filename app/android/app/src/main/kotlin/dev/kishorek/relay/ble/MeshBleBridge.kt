package dev.kishorek.relay.ble

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * Connects the foreground mesh service to the Pigeon-generated host API.
 *
 * Deliberately thin. It holds no protocol knowledge; it starts and stops the
 * service, forwards outbound frames, and hands inbound frames up to Dart when —
 * and only when — the Flutter engine is actually alive. When it is not, frames
 * accumulate in [PacketStore] and Dart collects them on next launch.
 */
object MeshBleBridge {

    @Volatile
    private var service: MeshForegroundService? = null

    @Volatile
    private var flutterApi: BleFlutterApiSink? = null

    /** Set by the service as it starts and stops. */
    fun attach(instance: MeshForegroundService?) { service = instance }

    /** Set by the Flutter plugin when the engine attaches and detaches. */
    fun attachFlutter(sink: BleFlutterApiSink?) { flutterApi = sink }

    /**
     * Delivers a frame to Dart if the engine is running.
     *
     * Frames are persisted by the caller regardless — a delivery attempt here is
     * an optimisation for the foreground case, never the durability mechanism.
     */
    fun deliverToDartIfRunning(frame: ByteArray, fromPeer: String) {
        flutterApi?.onFrameReceived(frame, fromPeer)
    }

    fun start(context: Context, addressHash: Int, powerMode: String) {
        val intent = Intent(context, MeshForegroundService::class.java).apply {
            action = MeshForegroundService.ACTION_START
            putExtra(MeshForegroundService.EXTRA_ADDRESS_HASH, addressHash)
            putExtra(MeshForegroundService.EXTRA_POWER_MODE, powerMode)
        }
        context.startForegroundService(intent)
    }

    fun stop(context: Context) {
        context.startService(
            Intent(context, MeshForegroundService::class.java).apply {
                action = MeshForegroundService.ACTION_STOP
            }
        )
    }

    fun sendFrame(frame: ByteArray, targetPeerId: String?, excludePeerId: String?) {
        service?.broadcast(frame, targetPeerId, excludePeerId)
    }

    fun drainInbox(): List<ByteArray> = service?.drainInbox() ?: emptyList()

    fun stats(): RelayStatsSnapshot =
        service?.stats() ?: RelayStatsSnapshot(0, 0, 0, 0, 0, 0)

    fun setStealth(enabled: Boolean) = service?.setStealth(enabled) ?: Unit

    fun setPowerMode(mode: String) = service?.setPowerMode(mode) ?: Unit

    fun setAnnounce(nickname: String, signedSessionKey: ByteArray) =
        service?.setAnnounce(nickname, signedSessionKey) ?: Unit

    fun wipe() = service?.wipe() ?: Unit

    fun connectedPeerCount(): Int = service?.connectedPeerCount() ?: 0

    fun canAdvertise(): Boolean = service?.canAdvertise ?: true

    fun peers(): List<PeerSnapshot> = service?.peerSnapshots() ?: emptyList()

    /** Null when the service is not running, which is itself the status. */
    fun status(): ServiceStatus? = service?.statusSnapshot()

    /** Pushed by the service whenever peers or radio state change. */
    fun notifyPeerDiscovered(peer: PeerSnapshot) = flutterApi?.onPeerDiscovered(peer)

    fun notifyPeerLost(peerId: String) = flutterApi?.onPeerLost(peerId)

    fun notifyStatusChanged() = flutterApi?.onStatusChanged()

    /**
     * Whether this device is likely to have the relay service killed.
     *
     * Several manufacturers terminate foreground services regardless of
     * correctness. Detecting it lets onboarding ask for an exemption instead of
     * the user concluding the app is broken.
     */
    fun needsBatteryExemption(context: Context): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val exempt = powerManager.isIgnoringBatteryOptimizations(context.packageName)
        if (exempt) return false

        val aggressive = setOf(
            "xiaomi", "redmi", "poco", "oppo", "realme", "oneplus",
            "vivo", "iqoo", "huawei", "honor", "samsung", "meizu", "asus",
        )
        return Build.MANUFACTURER.lowercase() in aggressive || Build.BRAND.lowercase() in aggressive
    }

    /**
     * Opens the most specific battery settings screen available.
     *
     * Manufacturer-specific activities are not part of the public SDK and are
     * renamed between versions, so each attempt is guarded and falls back to
     * the standard system screen.
     */
    fun openBatterySettings(context: Context) {
        val candidates = listOf(
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
        )

        for ((pkg, activity) in candidates) {
            val intent = Intent().apply {
                setClassName(pkg, activity)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(context.packageManager) != null) {
                runCatching { context.startActivity(intent); return }
            }
        }

        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}

/** Narrow sink so the bridge does not depend on generated Pigeon types. */
interface BleFlutterApiSink {
    fun onFrameReceived(frame: ByteArray, fromPeerId: String)
    fun onPeerDiscovered(peer: PeerSnapshot)
    fun onPeerLost(peerId: String)

    /** Carries no payload: the plugin re-reads status from the bridge. */
    fun onStatusChanged()
}

/**
 * A peer as native sees it.
 *
 * [hopDistance] is 1 for anything we hold a radio link to. Anything further is
 * inferred from relayed traffic, which is why it is a separate field rather
 * than derived from [isDirect].
 */
data class PeerSnapshot(
    val peerId: String,
    val hopDistance: Int,
    val isDirect: Boolean,
    val lastSeenMillis: Long,
    val rssi: Int?,
    val nickname: String?,
    val sessionKeyHash: Int?,
)

data class ServiceStatus(
    val running: Boolean,
    val adapterOn: Boolean,
    val advertising: Boolean,
    val scanning: Boolean,
    val connectedPeerCount: Int,
    val canAdvertise: Boolean,
    val powerMode: String,
    val detail: String?,
)
