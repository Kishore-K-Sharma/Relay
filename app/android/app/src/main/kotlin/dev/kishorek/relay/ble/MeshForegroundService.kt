package dev.kishorek.relay.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Keeps the mesh alive.
 *
 * This service exists because relaying must continue when the app is closed and
 * the Flutter engine is not running. It operates in **both** BLE roles at once:
 * advertising and serving a GATT characteristic so others can reach it, while
 * scanning and connecting outward so it can reach others.
 *
 * It never decrypts anything. Frames addressed elsewhere are forwarded as
 * opaque bytes; frames addressed here are persisted for Dart to collect.
 */
class MeshForegroundService : Service() {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("6f7b8a10-5c2d-4e91-9a3f-1d0e2c4b8a70")

        /** Peers write inbound frames here. */
        val RX_CHARACTERISTIC: UUID = UUID.fromString("6f7b8a11-5c2d-4e91-9a3f-1d0e2c4b8a70")

        /** Peers subscribe here to receive frames. */
        val TX_CHARACTERISTIC: UUID = UUID.fromString("6f7b8a12-5c2d-4e91-9a3f-1d0e2c4b8a70")

        const val CHANNEL_ID = "relay_mesh"
        const val NOTIFICATION_ID = 0x5A1

        /**
         * Practical ceiling on simultaneous GATT server connections. Real
         * chipsets vary between roughly 4 and 8; exceeding it fails silently on
         * some devices, so connections are rotated instead.
         */
        const val MAX_CONNECTIONS = 6

        const val ACTION_START = "dev.kishorek.relay.ble.START"
        const val ACTION_STOP = "dev.kishorek.relay.ble.STOP"
        const val EXTRA_ADDRESS_HASH = "addressHash"
        const val EXTRA_POWER_MODE = "powerMode"
    }

    private lateinit var store: PacketStore
    private lateinit var relay: RelayEngine
    private lateinit var power: PowerPolicy

    private val handler = Handler(Looper.getMainLooper())
    private val bluetoothManager by lazy {
        getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val adapter: BluetoothAdapter? get() = bluetoothManager.adapter

    private var gattServer: BluetoothGattServer? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null

    /** Devices subscribed to our TX characteristic, keyed by peer id. */
    private val subscribers = ConcurrentHashMap<String, BluetoothDevice>()

    /** Outbound GATT client connections, keyed by peer id. */
    private val outbound = ConcurrentHashMap<String, BluetoothGatt>()

    /** Everyone we have heard from, whether or not a link is currently open. */
    private val peers = ConcurrentHashMap<String, PeerSnapshot>()

    private var addressHash: Int = 0
    private var stealth = false
    var canAdvertise = true
        private set

    private var advertising = false
    private var scanning = false
    private var announceNickname: String = ""
    private var announcePayload: ByteArray = ByteArray(0)

    var framesReceived = 0; private set
    var framesRelayed = 0; private set
    var framesSuppressed = 0; private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        store = PacketStore(this)
        power = PowerPolicy()
        relay = RelayEngine(localHash = 0, clock = { System.currentTimeMillis() })
        createNotificationChannel()
        MeshBleBridge.attach(this)
        registerReceiver(
            adapterStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
        )
    }

    /**
     * The user turning Bluetooth off is the single most common cause of "the app
     * stopped working". Watching for it lets the UI say so rather than sit
     * silently with no peers.
     */
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> startMesh()
                BluetoothAdapter.STATE_OFF -> {
                    stopMesh()
                    peers.keys.toList().forEach { forgetPeer(it) }
                }
            }
            MeshBleBridge.notifyStatusChanged()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopMesh(); stopSelf(); return START_NOT_STICKY }
            else -> {
                addressHash = intent?.getIntExtra(EXTRA_ADDRESS_HASH, 0) ?: 0
                relay = RelayEngine(
                    localHash = addressHash,
                    clock = { System.currentTimeMillis() },
                )
                power.mode = intent?.getStringExtra(EXTRA_POWER_MODE) ?: PowerPolicy.BALANCED
                startForeground(NOTIFICATION_ID, buildNotification())
                startMesh()
            }
        }
        // START_STICKY so the OS restarts us after a low-memory kill. The dedup
        // table is persisted precisely so a restart does not cause a rebroadcast
        // storm of everything still in flight.
        return START_STICKY
    }

    override fun onDestroy() {
        stopMesh()
        runCatching { unregisterReceiver(adapterStateReceiver) }
        handler.removeCallbacks(announceTick)
        MeshBleBridge.attach(null)
        super.onDestroy()
    }

    // -------------------------------------------------------------- lifecycle

    private fun startMesh() {
        val adapter = this.adapter ?: return
        if (!adapter.isEnabled) return

        openGattServer()

        canAdvertise = adapter.isMultipleAdvertisementSupported
        if (canAdvertise && !stealth) startAdvertising() else canAdvertise = false

        startScanning()
        scheduleAnnounce()
        MeshBleBridge.notifyStatusChanged()
    }

    private fun stopMesh() {
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        advertising = false
        scanning = false
        outbound.values.forEach { runCatching { it.close() } }
        outbound.clear()
        subscribers.clear()
        runCatching { gattServer?.close() }
        gattServer = null
        handler.removeCallbacks(announceTick)
        MeshBleBridge.notifyStatusChanged()
    }

    /**
     * Restarts scanning and advertising under a new duty cycle.
     *
     * Both must be torn down and re-established: Android bakes the scan mode and
     * advertise interval into the settings object at start time, and changing
     * them any other way is silently ignored.
     */
    fun setPowerMode(mode: String) {
        if (power.mode == mode) return
        power.mode = mode

        val adapter = this.adapter
        if (adapter == null || !adapter.isEnabled) return

        runCatching { adapter.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
        startScanning()

        if (advertising) {
            runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
            advertising = false
            startAdvertising()
        }

        handler.removeCallbacks(announceTick)
        scheduleAnnounce()
        updateNotification()
        MeshBleBridge.notifyStatusChanged()
    }

    // -------------------------------------------------------------- presence

    /**
     * Sets the presence beacon. An empty nickname suppresses it entirely, which
     * is what stealth mode and an un-onboarded user both want.
     */
    fun setAnnounce(nickname: String, signedSessionKey: ByteArray) {
        announceNickname = nickname
        announcePayload = signedSessionKey
        handler.removeCallbacks(announceTick)
        scheduleAnnounce()
    }

    private fun scheduleAnnounce() {
        if (stealth || announceNickname.isEmpty()) return
        handler.post(announceTick)
    }

    private val announceTick = object : Runnable {
        override fun run() {
            if (!stealth && announceNickname.isNotEmpty()) broadcastAnnounce()
            handler.postDelayed(this, power.announceIntervalMs())
        }
    }

    /**
     * An announce is a plaintext broadcast: it has to be readable by strangers
     * for discovery to work at all. It carries a nickname and a signed session
     * key, never a long-term identifier.
     */
    private fun broadcastAnnounce() {
        val name = announceNickname.toByteArray(Charsets.UTF_8).let {
            if (it.size > 32) it.copyOfRange(0, 32) else it
        }
        val payload = ByteArray(1 + name.size + announcePayload.size)
        payload[0] = name.size.toByte()
        name.copyInto(payload, 1)
        announcePayload.copyInto(payload, 1 + name.size)

        val frame = Frame(
            version = Wire.PROTOCOL_VERSION.toInt(),
            type = FrameType.ANNOUNCE,
            // Presence is local. Flooding it seven hops would swamp the mesh
            // with beacons from people nobody can actually reach.
            ttl = 1,
            flags = FrameFlags(),
            msgId = randomMsgId(),
            srcHash = addressHash,
            dstHash = Wire.BROADCAST_HASH,
            payload = payload,
        )
        broadcast(frame.encode())
    }

    private fun randomMsgId(): ByteArray {
        val out = ByteArray(8)
        java.security.SecureRandom().nextBytes(out)
        return out
    }

    // ------------------------------------------------------- peripheral role

    private fun openGattServer() {
        val server = bluetoothManager.openGattServer(this, gattServerCallback) ?: return
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // Write-without-response: the mesh tolerates loss and retries, and
        // acknowledged writes would halve throughput.
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                RX_CHARACTERISTIC,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
        )

        val tx = BluetoothGattCharacteristic(
            TX_CHARACTERISTIC,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        service.addCharacteristic(tx)
        txCharacteristic = tx

        server.addService(service)
        gattServer = server
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val peerId = device.address
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                if (subscribers.size >= MAX_CONNECTIONS) {
                    // Rotate rather than refuse: dropping the least recently
                    // useful peer keeps the mesh fluid as people move.
                    subscribers.keys.firstOrNull()?.let {
                        subscribers.remove(it)
                        if (!outbound.containsKey(it)) forgetPeer(it)
                    }
                }
                subscribers[peerId] = device
                notePeer(peerId, rssi = null)
                flushHeldFor(peerId)
            } else {
                subscribers.remove(peerId)
                if (!outbound.containsKey(peerId)) forgetPeer(peerId)
            }
            updateNotification()
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == RX_CHARACTERISTIC) {
                onFrameFromRadio(value, device.address)
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    private fun startAdvertising() {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: run { canAdvertise = false; return }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(power.advertiseMode())
            .setTxPowerLevel(power.txPower())
            .setConnectable(true)
            .build()

        // Service UUID only. No device name: it is a stable identifier that
        // would let anyone track the device across sessions.
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .setIncludeDeviceName(false)
            .build()

        advertiser.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            advertising = true
            MeshBleBridge.notifyStatusChanged()
        }

        override fun onStartFailure(errorCode: Int) {
            canAdvertise = false
            advertising = false
            MeshBleBridge.notifyStatusChanged()
        }
    }

    // ----------------------------------------------------------- central role

    private fun startScanning() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(power.scanMode())
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        scanner.startScan(filters, settings, scanCallback)
        scanning = true
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            // Recorded on every sighting, connected or not: signal strength is
            // what the radar screen draws, and it changes as people move.
            notePeer(device.address, rssi = result.rssi)
            if (outbound.containsKey(device.address)) return
            if (outbound.size >= MAX_CONNECTIONS) return
            connectTo(device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            MeshBleBridge.notifyStatusChanged()
        }
    }

    private fun connectTo(device: BluetoothDevice) {
        val gatt = device.connectGatt(
            this,
            false,
            gattClientCallback,
            BluetoothDevice.TRANSPORT_LE,
        )
        outbound[device.address] = gatt
    }

    private val gattClientCallback = object : android.bluetooth.BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                gatt.requestMtu(517)
                notePeer(gatt.device.address, rssi = null)
            } else {
                val peerId = gatt.device.address
                outbound.remove(peerId)
                if (!subscribers.containsKey(peerId)) forgetPeer(peerId)
                gatt.close()
            }
            updateNotification()
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val tx = gatt.getService(SERVICE_UUID)?.getCharacteristic(TX_CHARACTERISTIC)
            if (tx != null) gatt.setCharacteristicNotification(tx, true)
            flushHeldFor(gatt.device.address)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid == TX_CHARACTERISTIC) {
                onFrameFromRadio(value, gatt.device.address)
            }
        }
    }

    // ------------------------------------------------------------ relay path

    /**
     * The hot path. Runs on a BLE callback thread, with the Flutter engine
     * possibly dead. Everything here operates on opaque bytes.
     */
    fun onFrameFromRadio(bytes: ByteArray, fromPeer: String) {
        framesReceived++
        val frame = Frame.decode(bytes) ?: return
        val decision = relay.receive(frame, fromPeer)

        if (decision.deliverLocally) {
            store.appendInbox(bytes)
            MeshBleBridge.deliverToDartIfRunning(bytes, fromPeer)
        }

        val relayFrame = decision.relayFrame ?: return
        val key = FrameKey.of(frame)

        handler.postDelayed({
            if (relay.shouldSuppress(key, fromPeer)) {
                framesSuppressed++
                return@postDelayed
            }
            framesRelayed++
            broadcast(relayFrame.encode(), excludePeerId = fromPeer)
        }, decision.jitterMs)
    }

    fun broadcast(bytes: ByteArray, targetPeerId: String? = null, excludePeerId: String? = null) {
        var delivered = 0

        subscribers.forEach { (peerId, device) ->
            if (peerId == excludePeerId) return@forEach
            if (targetPeerId != null && peerId != targetPeerId) return@forEach
            val tx = txCharacteristic ?: return@forEach
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gattServer?.notifyCharacteristicChanged(device, tx, false, bytes)
                } else {
                    @Suppress("DEPRECATION")
                    tx.value = bytes
                    @Suppress("DEPRECATION")
                    gattServer?.notifyCharacteristicChanged(device, tx, false)
                }
                delivered++
            }
        }

        outbound.forEach { (peerId, gatt) ->
            if (peerId == excludePeerId) return@forEach
            if (targetPeerId != null && peerId != targetPeerId) return@forEach
            val rx = gatt.getService(SERVICE_UUID)?.getCharacteristic(RX_CHARACTERISTIC)
                ?: return@forEach
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(
                        rx, bytes,
                        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                    )
                } else {
                    @Suppress("DEPRECATION")
                    rx.value = bytes
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(rx)
                }
                delivered++
            }
        }

        // Nowhere to send it right now. Hold it rather than lose it.
        if (delivered == 0) {
            val frame = Frame.decode(bytes)
            if (frame != null && !frame.isBroadcast) store.hold(bytes, frame.dstHash)
        }
    }

    private fun flushHeldFor(peerId: String) {
        // Peer id is a MAC, not an address hash, so everything held is retried
        // when any peer appears; the mesh discards what is not for it.
        val held = store.takeFor(0)
        held.forEach { broadcast(it, targetPeerId = peerId) }
    }

    // ----------------------------------------------------------- peer registry

    /**
     * Records a sighting of a directly reachable peer.
     *
     * Native only ever tracks *direct* links, so [PeerSnapshot.hopDistance] is
     * always 1 here. Peers further away are known only through announce frames,
     * which native cannot interpret — Dart builds that wider view from the
     * frames it decodes. Guessing distance from ttl would be wrong, because the
     * peer id is a MAC address and a frame header carries an address hash.
     */
    private fun notePeer(peerId: String, rssi: Int?) {
        val existing = peers[peerId]
        val snapshot = PeerSnapshot(
            peerId = peerId,
            hopDistance = 1,
            isDirect = true,
            lastSeenMillis = System.currentTimeMillis(),
            // Keep the last known reading when a connection event carries none,
            // rather than blanking a signal bar the user is watching.
            rssi = rssi ?: existing?.rssi,
            nickname = existing?.nickname,
            sessionKeyHash = existing?.sessionKeyHash,
        )
        peers[peerId] = snapshot
        MeshBleBridge.notifyPeerDiscovered(snapshot)
    }

    private fun forgetPeer(peerId: String) {
        if (peers.remove(peerId) == null) return
        MeshBleBridge.notifyPeerLost(peerId)
    }

    fun peerSnapshots(): List<PeerSnapshot> = peers.values.toList()

    fun statusSnapshot(): ServiceStatus = ServiceStatus(
        running = gattServer != null || scanning,
        adapterOn = adapter?.isEnabled == true,
        advertising = advertising,
        scanning = scanning,
        connectedPeerCount = connectedPeerCount(),
        canAdvertise = canAdvertise,
        powerMode = power.mode,
        detail = when {
            adapter == null -> "This device has no Bluetooth"
            adapter?.isEnabled != true -> "Bluetooth is off"
            !canAdvertise ->
                "This device can receive and relay, but cannot advertise, " +
                    "so others will not discover it first"
            else -> null
        },
    )

    // ------------------------------------------------------------------- api

    fun drainInbox(): List<ByteArray> = store.drainInbox()

    fun stats(): RelayStatsSnapshot = RelayStatsSnapshot(
        framesReceived = framesReceived,
        framesRelayed = framesRelayed,
        framesDropped = relay.droppedCount,
        framesSuppressed = framesSuppressed,
        storedForForward = store.forwardDepth(),
        inboxDepth = store.inboxDepth(),
    )

    fun setStealth(enabled: Boolean) {
        stealth = enabled
        if (enabled) {
            runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
            advertising = false
            // Presence beacons would defeat the point of hiding.
            handler.removeCallbacks(announceTick)
        } else {
            if (canAdvertise) startAdvertising()
            scheduleAnnounce()
        }
        // Scanning and relaying continue either way: continuing to carry other
        // people's traffic is what provides cover.
        MeshBleBridge.notifyStatusChanged()
    }

    fun wipe() {
        relay.clear()
        store.wipe()
        announceNickname = ""
        announcePayload = ByteArray(0)
        handler.removeCallbacks(announceTick)
    }

    fun connectedPeerCount(): Int = (subscribers.keys + outbound.keys).size

    // --------------------------------------------------------- notification

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mesh network",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Keeps nearby messaging working without internet" }
        (getSystemService(NotificationManager::class.java)).createNotificationChannel(channel)
    }

    /**
     * Keeps the ongoing notification truthful.
     *
     * It is the only thing the user sees while the app is closed, so it is the
     * only place they can tell whether the mesh is actually working.
     */
    private fun updateNotification() {
        runCatching {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification())
        }
    }

    private fun buildNotification(): Notification {
        val peers = connectedPeerCount()
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(if (peers == 0) "Looking for people nearby" else "$peers nearby")
            .setContentText("Relaying messages · ${power.mode} power")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }
}

data class RelayStatsSnapshot(
    val framesReceived: Int,
    val framesRelayed: Int,
    val framesDropped: Int,
    val framesSuppressed: Int,
    val storedForForward: Int,
    val inboxDepth: Int,
)
