package dev.kishorek.relay.ble

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * The runtime permissions the mesh needs, and how to ask for them.
 *
 * Android 12 split Bluetooth into three separate permissions and made the old
 * location workaround unnecessary. Requesting location anyway still works, but
 * asking a privacy-focused app's users for their location in order to send a
 * chat message is exactly the kind of thing that makes people uninstall it.
 */
object BlePermissions {

    const val REQUEST_CODE = 0x5A11

    fun required(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) + notificationPermission()
        } else {
            // Before Android 12 the scan permission genuinely was location.
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }

    private fun notificationPermission(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Without it the foreground service notification is suppressed, and
            // on several OEMs a service with a hidden notification gets killed.
            arrayOf(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            emptyArray()
        }

    fun allGranted(context: Context): Boolean = required().all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    fun request(activity: Activity) {
        ActivityCompat.requestPermissions(activity, required(), REQUEST_CODE)
    }

    fun isBluetoothEnabled(context: Context): Boolean {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE)
            as? android.bluetooth.BluetoothManager
        return manager?.adapter?.isEnabled == true
    }

    /**
     * Asks the user to turn Bluetooth on.
     *
     * `ACTION_REQUEST_ENABLE` shows a system prompt the user can refuse. Apps
     * can no longer enable the adapter directly, and that is the right
     * behaviour — this only surfaces the request.
     */
    fun requestEnable(context: Context) {
        runCatching {
            context.startActivity(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}
