package dev.kishorek.relay.wifi

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger

/**
 * Implements the Pigeon discovery host API.
 *
 * The only Android file that knows the generated discovery types exist, mirror
 * of `MeshBlePlugin` on the Bluetooth side. It holds no state of its own; it
 * translates and hops threads.
 */
class MeshDiscoveryPlugin(
    context: Context,
    private val messenger: BinaryMessenger,
) : DiscoveryHostApi, LanDiscoverer.Events {

    private val discoverer = LanDiscoverer(context).also { it.events = this }
    private val flutter = DiscoveryFlutterApi(messenger)

    /** NSD callbacks arrive on a binder thread; Pigeon requires the main one. */
    private val main = Handler(Looper.getMainLooper())

    fun attach() {
        DiscoveryHostApi.setUp(messenger, this)
        discoverer.watchNetwork()
    }

    fun detach() {
        DiscoveryHostApi.setUp(messenger, null)
        discoverer.stopBrowsing()
        discoverer.stopAdvertising()
        discoverer.stopWatchingNetwork()
        discoverer.events = null
    }

    // ------------------------------------------------------------- host api

    override fun isAvailable(): Boolean = discoverer.isAvailable()

    override fun unavailableReason(): DiscoveryUnavailable? = translate(
        discoverer.unavailableReason(),
    )

    override fun advertise(
        instanceId: String,
        addressHash: Long,
        port: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        // Pigeon widens every integer to 64 bits. Both values are 32-bit and
        // must be narrowed before they reach the platform, or the advertised
        // address will never match a frame header.
        discoverer.advertise(instanceId, addressHash.toInt(), port.toInt())
        callback(Result.success(Unit))
    }

    override fun stopAdvertising(callback: (Result<Unit>) -> Unit) {
        discoverer.stopAdvertising()
        callback(Result.success(Unit))
    }

    override fun browse(callback: (Result<Unit>) -> Unit) {
        discoverer.browse()
        callback(Result.success(Unit))
    }

    override fun stopBrowsing(callback: (Result<Unit>) -> Unit) {
        discoverer.stopBrowsing()
        callback(Result.success(Unit))
    }

    // --------------------------------------------------------- native events

    override fun onFound(instanceId: String, host: String, port: Int, addressHash: Int) {
        val service = ServiceInfo(
            instanceId = instanceId,
            host = host,
            port = port.toLong(),
            addressHash = addressHash.toLong() and 0xFFFFFFFFL,
        )
        main.post { flutter.onServiceFound(service) { } }
    }

    override fun onLost(instanceId: String) {
        main.post { flutter.onServiceLost(instanceId) { } }
    }

    override fun onAvailabilityChanged(
        available: Boolean,
        reason: LanDiscoverer.Unavailable?,
    ) {
        val translated = translate(reason)
        main.post { flutter.onAvailabilityChanged(available, translated) { } }
    }

    private fun translate(reason: LanDiscoverer.Unavailable?): DiscoveryUnavailable? =
        when (reason) {
            LanDiscoverer.Unavailable.PERMISSION_DENIED ->
                DiscoveryUnavailable.PERMISSION_DENIED
            LanDiscoverer.Unavailable.NO_NETWORK -> DiscoveryUnavailable.NO_NETWORK
            null -> null
        }
}
