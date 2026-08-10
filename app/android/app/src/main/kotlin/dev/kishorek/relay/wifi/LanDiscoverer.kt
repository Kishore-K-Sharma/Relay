package dev.kishorek.relay.wifi

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.util.ArrayDeque

/**
 * mDNS discovery over Android's NsdManager.
 *
 * Plain Android, no Flutter: everything Pigeon-shaped lives in
 * [MeshDiscoveryPlugin]. Two things here are less obvious than they look.
 *
 * First, resolves are serialised. `NsdManager.resolveService` fails with
 * `FAILURE_ALREADY_ACTIVE` if a second resolve starts before the first
 * finishes, and a crowded network produces found-callbacks far faster than
 * resolves complete. Without the queue most peers are simply never resolved,
 * on exactly the busy networks where the transport matters most.
 *
 * Second, an unresolved service is useless. `onServiceFound` carries a name and
 * a type but no address or port, so nothing can be dialled until the resolve
 * returns.
 */
class LanDiscoverer(private val context: Context) {

    interface Events {
        fun onFound(instanceId: String, host: String, port: Int, addressHash: Int)
        fun onLost(instanceId: String)
        fun onAvailabilityChanged(available: Boolean, reason: Unavailable?)
    }

    enum class Unavailable { PERMISSION_DENIED, NO_NETWORK }

    companion object {
        /** Must match the iOS side exactly or the two platforms never meet. */
        const val SERVICE_TYPE = "_kishorek-relay._tcp"

        /** TXT key carrying the truncated mesh address. */
        const val TXT_HASH = "h"

        /** TXT key carrying the per-run instance id. */
        const val TXT_INSTANCE = "i"
    }

    private val nsd: NsdManager? =
        context.getSystemService(Context.NSD_SERVICE) as? NsdManager

    private val connectivity: ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    var events: Events? = null

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** The name the system actually registered, which may be renamed on conflict. */
    private var registeredName: String? = null

    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    // ---------------------------------------------------------- availability

    fun isAvailable(): Boolean = nsd != null && onWifi()

    fun unavailableReason(): Unavailable? = when {
        nsd == null -> Unavailable.PERMISSION_DENIED
        !onWifi() -> Unavailable.NO_NETWORK
        else -> null
    }

    /**
     * Wi-Fi or Ethernet only. Cellular is deliberately excluded: there are no
     * peers on a carrier network, and advertising there would be pure battery
     * cost for a discovery that can never succeed.
     */
    private fun onWifi(): Boolean {
        val manager = connectivity ?: return false
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    fun watchNetwork() {
        if (networkCallback != null) return
        val manager = connectivity ?: return

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = publishAvailability()
            override fun onLost(network: Network) = publishAvailability()
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = publishAvailability()
        }
        networkCallback = callback

        manager.registerNetworkCallback(
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
                .build(),
            callback,
        )
    }

    fun stopWatchingNetwork() {
        val callback = networkCallback ?: return
        networkCallback = null
        try {
            connectivity?.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        }
    }

    private fun publishAvailability() {
        events?.onAvailabilityChanged(isAvailable(), unavailableReason())
    }

    // ----------------------------------------------------------- advertising

    fun advertise(instanceId: String, addressHash: Int, port: Int) {
        val manager = nsd ?: return
        stopAdvertising()

        val info = NsdServiceInfo().apply {
            serviceName = instanceId
            serviceType = SERVICE_TYPE
            this.port = port
            setAttribute(TXT_INSTANCE, instanceId)
            // Unsigned hex rather than the raw integer: TXT values are bytes,
            // and a negative decimal would have to be parsed differently on
            // each platform.
            setAttribute(TXT_HASH, (addressHash.toLong() and 0xFFFFFFFFL).toString(16))
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredName = info.serviceName
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                events?.onAvailabilityChanged(false, Unavailable.NO_NETWORK)
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                registeredName = null
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }

        registrationListener = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: IllegalArgumentException) {
            registrationListener = null
        }
    }

    fun stopAdvertising() {
        val listener = registrationListener ?: return
        registrationListener = null
        registeredName = null
        try {
            nsd?.unregisterService(listener)
        } catch (_: IllegalArgumentException) {
            // Not registered. Nothing to undo.
        }
    }

    // -------------------------------------------------------------- browsing

    fun browse() {
        val manager = nsd ?: return
        if (discoveryListener != null) return

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                discoveryListener = null
                events?.onAvailabilityChanged(false, Unavailable.NO_NETWORK)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                discoveryListener = null
            }

            override fun onDiscoveryStopped(serviceType: String) {
                discoveryListener = null
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                // Our own advertisement comes back to us; Dart filters on the
                // instance id too, but dropping it here saves a resolve on
                // every device in the room.
                if (info.serviceName == registeredName) return
                enqueueResolve(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                events?.onLost(info.serviceName)
            }
        }

        discoveryListener = listener
        try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: IllegalArgumentException) {
            discoveryListener = null
        }
    }

    fun stopBrowsing() {
        val listener = discoveryListener ?: return
        discoveryListener = null
        resolveQueue.clear()
        try {
            nsd?.stopServiceDiscovery(listener)
        } catch (_: IllegalArgumentException) {
            // Discovery already stopped.
        }
    }

    // -------------------------------------------------------------- resolves

    @Synchronized
    private fun enqueueResolve(info: NsdServiceInfo) {
        resolveQueue.addLast(info)
        pumpResolves()
    }

    @Synchronized
    private fun finishResolve() {
        resolving = false
        pumpResolves()
    }

    private fun pumpResolves() {
        if (resolving) return
        val manager = nsd ?: return
        val next = resolveQueue.pollFirst() ?: return
        resolving = true

        @Suppress("DEPRECATION")
        manager.resolveService(
            next,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    // Routine. A device can vanish between being announced and
                    // being resolved, and mDNS caches outlive their devices.
                    finishResolve()
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    publishResolved(info)
                    finishResolve()
                }
            },
        )
    }

    private fun publishResolved(info: NsdServiceInfo) {
        val host = info.host?.hostAddress ?: return
        val instanceId = attribute(info, TXT_INSTANCE) ?: info.serviceName ?: return
        if (instanceId == registeredName) return

        val hash = attribute(info, TXT_HASH)?.toLongOrNull(16)?.toInt() ?: return

        events?.onFound(instanceId, host, info.port, hash)
    }

    private fun attribute(info: NsdServiceInfo, key: String): String? =
        info.attributes[key]?.let { String(it, Charsets.UTF_8) }
}
