package dev.sarahsforge.paero

import android.app.PendingIntent
import android.content.Intent
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Flutter ↔ Android USB Host API for RTL-SDR dongles.
 *
 * MethodChannel: "dev.sarahsforge.paero/usb"
 *
 *   listDevices()  → List<Map<String, Any>>
 *       [ { "name": "/dev/bus/usb/...", "vid": 3034, "pid": 10296 }, ... ]
 *
 *   openDevice(name: String) → Map<String, Any>
 *       Requests USB permission if needed, opens the device.
 *       Returns { "fd": <int>, "path": <String> }
 *       The fd is passed to rf_open() via Dart FFI.
 *
 *   closeDevice() → null
 *       Releases the UsbDeviceConnection (C library closes the fd).
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "dev.sarahsforge.paero/usb"
        private const val ACTION_USB_PERMISSION = "dev.sarahsforge.paero.USB_PERMISSION"
        private const val RTLSDR_VID = 0x0BDA
    }

    private var usbManager: UsbManager? = null
    private var openConnection: UsbDeviceConnection? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        usbManager = getSystemService(USB_SERVICE) as UsbManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listDevices" -> listDevices(result)
                    "openDevice"  -> {
                        val name = call.argument<String>("name")
                            ?: return@setMethodCallHandler result.error("BAD_ARGS", "name required", null)
                        openDevice(name, result)
                    }
                    "closeDevice" -> {
                        openConnection?.close()
                        openConnection = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onDestroy() {
        super.onDestroy()
        openConnection?.close()
    }

    private fun listDevices(result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val list = mgr.deviceList.values
            .filter { it.vendorId == RTLSDR_VID }
            .map { dev ->
                mapOf(
                    "name" to dev.deviceName,
                    "vid"  to dev.vendorId,
                    "pid"  to dev.productId
                )
            }
        result.success(list)
    }

    private fun openDevice(name: String, result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val dev = mgr.deviceList[name]
            ?: return result.error("NOT_FOUND", "Device $name not found", null)

        if (!mgr.hasPermission(dev)) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0
            val intent = PendingIntent.getBroadcast(
                this, 0,
                Intent(ACTION_USB_PERMISSION).apply { `package` = packageName },
                flags)
            mgr.requestPermission(dev, intent)
            result.error("PERMISSION_REQUESTED", "USB permission dialog shown", null)
        } else {
            openDeviceAndReturn(dev, result)
        }
    }

    private fun openDeviceAndReturn(dev: UsbDevice, result: MethodChannel.Result) {
        val mgr  = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val conn = mgr.openDevice(dev)
            ?: return result.error("OPEN_FAILED", "Failed to open ${dev.deviceName}", null)

        openConnection?.close()
        openConnection = conn

        result.success(mapOf(
            "fd"   to conn.fileDescriptor,
            "path" to dev.deviceName
        ))
    }
}

