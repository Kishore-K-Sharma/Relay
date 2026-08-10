package dev.kishorek.relay.ble

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger

/**
 * Implements the Pigeon host API and pushes native events back to Dart.
 *
 * The only place in the Android sources that knows generated Pigeon types
 * exist. Everything below it — the service, the relay, the store — is plain
 * Kotlin that can be unit tested without a Flutter engine.
 */
class MeshBlePlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : BleHostApi, BleFlutterApiSink {

    private val flutter = BleFlutterApi(messenger)

    /**
     * Pigeon callbacks must be invoked on the main thread. BLE callbacks arrive
     * on a binder thread, so every push is hopped across.
     */
    private val main = Handler(Looper.getMainLooper())

    /**
     * The activity, when one is attached.
     *
     * Only needed to show a permission dialog: Android will not display one
     * from an application context. Everything else works headless, which is
     * what lets the relay keep running with no UI.
     */
    private var activity: Activity? = null

    private var pendingPermissionResult: ((Result<Boolean>) -> Unit)? = null

    fun attach(activity: Activity? = null) {
        this.activity = activity
        BleHostApi.setUp(messenger, this)
        MeshBleBridge.attachFlutter(this)
    }

    fun detach() {
        BleHostApi.setUp(messenger, null)
        MeshBleBridge.attachFlutter(null)
        activity = null
        // Never leave Dart awaiting a future that can no longer complete.
        pendingPermissionResult?.invoke(Result.success(false))
        pendingPermissionResult = null
    }

    /** Forwarded from the activity; Pigeon has no notion of activity results. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != BlePermissions.REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.invoke(Result.success(granted))
        pendingPermissionResult = null
        MeshBleBridge.notifyStatusChanged()
        return true
    }

    // ------------------------------------------------------------- host api

    override fun hasPermissions(): Boolean = BlePermissions.allGranted(context)

    override fun requestPermissions(callback: (Result<Boolean>) -> Unit) {
        if (BlePermissions.allGranted(context)) {
            callback(Result.success(true))
            return
        }
        val activity = this.activity
        if (activity == null) {
            // Reporting failure is right: the caller asked for a dialog and no
            // dialog can be shown. Silently returning true would be a lie.
            callback(Result.success(false))
            return
        }
        // A second request while one is outstanding would strand the first.
        pendingPermissionResult?.invoke(Result.success(false))
        pendingPermissionResult = callback
        BlePermissions.request(activity)
    }

    override fun isBluetoothEnabled(): Boolean = BlePermissions.isBluetoothEnabled(context)

    override fun requestEnableBluetooth() = BlePermissions.requestEnable(activity ?: context)

    override fun start(addressHash: Long, powerMode: String) {
        // Pigeon widens every integer to 64 bits. The address hash is a
        // truncated 32-bit value and must be narrowed back before it reaches
        // the relay, or it will never match a frame header.
        MeshBleBridge.start(context, addressHash.toInt(), powerMode)
    }

    override fun stop() = MeshBleBridge.stop(context)

    override fun sendFrame(
        frame: ByteArray,
        targetPeerId: String?,
        excludePeerId: String?,
    ) = MeshBleBridge.sendFrame(frame, targetPeerId, excludePeerId)

    override fun getPeers(): List<PeerInfo> = MeshBleBridge.peers().map(::toPigeon)

    override fun getStatus(): TransportStatus {
        val status = MeshBleBridge.status()
        if (status == null) {
            // The service not running is a real, reportable state — not an
            // error and not something to paper over with defaults.
            return TransportStatus(
                running = false,
                adapterOn = false,
                permissionsGranted = BlePermissions.allGranted(context),
                advertising = false,
                scanning = false,
                connectedPeerCount = 0,
                canAdvertise = true,
                powerMode = PowerPolicy.BALANCED,
                detail = "The mesh service is not running",
            )
        }
        return TransportStatus(
            running = status.running,
            adapterOn = status.adapterOn,
            permissionsGranted = BlePermissions.allGranted(context),
            advertising = status.advertising,
            scanning = status.scanning,
            connectedPeerCount = status.connectedPeerCount.toLong(),
            canAdvertise = status.canAdvertise,
            powerMode = status.powerMode,
            detail = status.detail,
        )
    }

    override fun getStats(): RelayStats {
        val s = MeshBleBridge.stats()
        return RelayStats(
            framesReceived = s.framesReceived.toLong(),
            framesRelayed = s.framesRelayed.toLong(),
            framesDropped = s.framesDropped.toLong(),
            framesSuppressed = s.framesSuppressed.toLong(),
            storedForForward = s.storedForForward.toLong(),
            inboxDepth = s.inboxDepth.toLong(),
        )
    }

    override fun drainInbox(): List<ByteArray> = MeshBleBridge.drainInbox()

    override fun setPowerMode(mode: String) = MeshBleBridge.setPowerMode(mode)

    override fun setStealthMode(enabled: Boolean) = MeshBleBridge.setStealth(enabled)

    override fun setAnnounce(nickname: String, signedSessionKey: ByteArray) =
        MeshBleBridge.setAnnounce(nickname, signedSessionKey)

    override fun wipe() = MeshBleBridge.wipe()

    override fun needsBatteryExemption(): Boolean =
        MeshBleBridge.needsBatteryExemption(context)

    override fun openBatterySettings() = MeshBleBridge.openBatterySettings(context)

    // --------------------------------------------------------- native events

    override fun onFrameReceived(frame: ByteArray, fromPeerId: String) {
        main.post { flutter.onFrameReceived(frame, fromPeerId) { } }
    }

    override fun onPeerDiscovered(peer: PeerSnapshot) {
        main.post { flutter.onPeerDiscovered(toPigeon(peer)) { } }
    }

    override fun onPeerLost(peerId: String) {
        main.post { flutter.onPeerLost(peerId) { } }
    }

    override fun onStatusChanged() {
        main.post { flutter.onStatusChanged(getStatus()) { } }
    }

    private fun toPigeon(peer: PeerSnapshot) = PeerInfo(
        peerId = peer.peerId,
        hopDistance = peer.hopDistance.toLong(),
        isDirect = peer.isDirect,
        lastSeenMillis = peer.lastSeenMillis,
        rssi = peer.rssi?.toLong(),
        nickname = peer.nickname,
        sessionKeyHash = peer.sessionKeyHash?.toLong(),
    )
}
