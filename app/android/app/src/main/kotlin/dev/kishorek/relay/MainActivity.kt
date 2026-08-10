package dev.kishorek.relay

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import dev.kishorek.relay.ble.MeshBlePlugin
import dev.kishorek.relay.wifi.MeshDiscoveryPlugin

class MainActivity : FlutterActivity() {

    private var ble: MeshBlePlugin? = null

    /**
     * Local-network discovery. Attached only while the activity lives, unlike
     * the Bluetooth relay, because Wi-Fi discovery stops being useful the
     * moment the app is not running — nothing keeps the sockets open.
     */
    private var discovery: MeshDiscoveryPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ble = MeshBlePlugin(applicationContext, messenger).also { it.attach(this) }
        discovery = MeshDiscoveryPlugin(applicationContext, messenger)
            .also { it.attach() }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        ble?.detach()
        ble = null
        discovery?.detach()
        discovery = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Pigeon has no notion of an activity result, so the permission outcome has
     * to be handed back by hand. Without this the Dart future never completes
     * and onboarding hangs on the permission step forever.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ble?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
