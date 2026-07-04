package com.example.printing_ffi_example

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Android USB auto-detect layer for DNP / Citizen dye-sub printers.
 *
 * Responsibilities:
 *  - Detect a matching DNP/Citizen printer on plug (from the launch intent AND a
 *    runtime BroadcastReceiver for USB_DEVICE_ATTACHED / DETACHED).
 *  - Request USB permission if not already held; proceed on grant.
 *  - Open the device, KEEP the UsbDeviceConnection referenced, expose its raw fd
 *    (UsbDeviceConnection.getFileDescriptor()) so Dart can hand it to the native
 *    USB fd-server (startUsbFdServer).
 *  - Emit attach {vendorId, productId, serial, productName, deviceName, fd} and
 *    detach {deviceName, vendorId, productId} events to Dart via an EventChannel.
 *  - Provide MethodChannel calls to (re)scan, close a device, and drive the
 *    foreground service.
 *
 * The DNP fd-handoff contract (see .context/usb-fd-server.md): after cupsd boots,
 * on permission grant Dart calls startUsbFdServer(sockPath, fd) then addCupsPrinter,
 * THEN prints; on teardown Dart calls stopUsbFdServer, then this manager closes the
 * connection.
 *
 * NOTE (follow-up): this lives in the EXAMPLE app. Promoting it into the plugin
 * proper (a FlutterPlugin Kotlin class + pubspec pluginClass) is a documented TODO.
 */
class DnpUsbManager(
    private val activity: Activity,
    methodMessenger: io.flutter.plugin.common.BinaryMessenger,
) {
    private val tag = "PrintingFfiUsb"
    private val usbManager: UsbManager =
        activity.getSystemService(Context.USB_SERVICE) as UsbManager

    private val methodChannel = MethodChannel(methodMessenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(methodMessenger, EVENT_CHANNEL)
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ALL USB work — enumeration, openDevice, fd extraction, close — runs on this
    // single-thread background executor, NEVER on the main thread. USB enumeration
    // and open can block for seconds; doing them on the main thread during startup
    // starved the focus window and caused an ANR ("Input dispatching timed out.
    // Waited 10000ms for FocusEvent"). MethodChannel handlers / receivers offload
    // here and return immediately; results/events are posted back via mainHandler.
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "dnp-usb-io").apply { isDaemon = true }
    }

    // Open connections keyed by device name (e.g. "/dev/bus/usb/001/002"). We keep
    // them open (long-lived) so their fd stays valid across dye-sub jobs. Accessed
    // only from ioExecutor + synchronized blocks.
    private val openConnections = HashMap<String, UsbDeviceConnection>()

    // DNP / Citizen VID/PIDs from the Gutenprint dnpds40 backend device table.
    // Mirrors res/xml/usb_device_filter.xml. Keep in sync.
    private data class DnpModel(val vid: Int, val pid: Int, val make: String, val name: String)

    private val supported = listOf(
        DnpModel(0x1343, 0x0002, "citizen-cw-01", "Citizen CW-01 / OP900"),
        DnpModel(0x1343, 0x0003, "dnp-ds40", "DNP DS40 / Citizen CX"),
        DnpModel(0x1343, 0x0004, "dnp-ds80", "DNP DS80 / Citizen CW"),
        DnpModel(0x1343, 0x0005, "dnp-dsrx1", "DNP DSRX1 / Citizen CY"),
        DnpModel(0x1343, 0x0006, "citizen-cw-02", "Citizen CW-02 / OP900ii"),
        DnpModel(0x1343, 0x0008, "dnp-ds80dx", "DNP DS80DX"),
        DnpModel(0x1343, 0x000a, "citizen-cx-02", "Citizen CX-02"),
        DnpModel(0x1343, 0x000b, "citizen-cx-02w", "Citizen CX-02W"),
        DnpModel(0x1343, 0x000c, "citizen-cz-01", "Citizen CZ-01"),
        DnpModel(0x1452, 0x8b01, "dnp-ds620", "DNP DS620"),
        DnpModel(0x1452, 0x9001, "dnp-ds820", "DNP DS820"),
        DnpModel(0x1452, 0x9201, "dnp-qw410", "DNP QW410"),
    )

    private fun modelFor(dev: UsbDevice): DnpModel? =
        supported.firstOrNull { it.vid == dev.vendorId && it.pid == dev.productId }

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            // Extract on the main thread (Intent is cheap); do the blocking open on
            // the io thread so we return from onReceive immediately.
            val device: UsbDevice? = getDeviceExtra(intent)
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            Log.i(tag, "permission result granted=$granted dev=${device?.deviceName}")
            ioExecutor.execute {
                if (granted && device != null) {
                    openAndEmit(device)
                } else if (device != null) {
                    emit(mapOf("event" to "permissionDenied") + deviceSignature(device))
                }
            }
        }
    }

    private val attachDetachReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device: UsbDevice = getDeviceExtra(intent) ?: return
            val action = intent.action
            // Offload all USB work to the io thread; return from onReceive at once.
            ioExecutor.execute {
                when (action) {
                    UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                        Log.i(tag, "ACTION_USB_DEVICE_ATTACHED ${device.deviceName} vid=${device.vendorId} pid=${device.productId}")
                        if (modelFor(device) != null) onMatchingAttach(device)
                    }
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        Log.i(tag, "ACTION_USB_DEVICE_DETACHED ${device.deviceName}")
                        onDetach(device)
                    }
                }
            }
        }
    }

    fun register() {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Enumerate currently-attached matching devices and auto-open the ones
                // we already have permission for (used on app start / for persistence).
                // USB enumeration + open block, so run on the io thread and reply via
                // mainHandler; never block the platform (main) thread.
                "scan" -> {
                    ioExecutor.execute {
                        try {
                            val out = scan()
                            mainHandler.post { result.success(out) }
                        } catch (t: Throwable) {
                            mainHandler.post { result.error("USB_SCAN", t.message, null) }
                        }
                    }
                }
                // Explicitly (re)request permission + open a device by deviceName.
                "requestDevice" -> {
                    val name = call.argument<String>("deviceName")
                    ioExecutor.execute {
                        val dev = name?.let { findAttached(it) }
                        if (dev == null) {
                            mainHandler.post { result.error("USB_NOT_FOUND", "device $name not attached", null) }
                        } else {
                            ensurePermissionAndOpen(dev)
                            mainHandler.post { result.success(true) }
                        }
                    }
                }
                "closeDevice" -> {
                    val name = call.argument<String>("deviceName")
                    ioExecutor.execute {
                        val ok = closeDevice(name)
                        mainHandler.post { result.success(ok) }
                    }
                }
                "startForegroundService" -> {
                    val text = call.argument<String>("text") ?: "Printing to DNP printer…"
                    DnpUsbForegroundService.start(activity, text)
                    result.success(true)
                }
                "stopForegroundService" -> {
                    DnpUsbForegroundService.stop(activity)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                Log.i(tag, "event channel listening")
                // NOTE: we deliberately do NOT scan() here. The Dart side drives the
                // initial scan explicitly via the "scan" MethodChannel once it starts
                // listening. Scanning here too caused a DOUBLE scan → the same device
                // was opened twice (fd=175 AND fd=171). One driver = the Dart-driven
                // scan; onListen only wires up the sink.
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        // Runtime receivers for hotplug + permission results.
        val attachFilter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        val permFilter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(attachDetachReceiver, attachFilter, Context.RECEIVER_NOT_EXPORTED)
            activity.registerReceiver(permissionReceiver, permFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(attachDetachReceiver, attachFilter)
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(permissionReceiver, permFilter)
        }
    }

    fun unregister() {
        try { activity.unregisterReceiver(attachDetachReceiver) } catch (_: Throwable) {}
        try { activity.unregisterReceiver(permissionReceiver) } catch (_: Throwable) {}
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        synchronized(this) {
            openConnections.values.forEach { try { it.close() } catch (_: Throwable) {} }
            openConnections.clear()
        }
        ioExecutor.shutdown()
    }

    /** Handle a USB_DEVICE_ATTACHED delivered via the Activity launch/new intent.
     *  Called on the main thread (configureFlutterEngine / onNewIntent); must NOT do
     *  blocking USB IO here — offload the open to the io thread and return at once. */
    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        val device: UsbDevice = getDeviceExtra(intent) ?: return
        Log.i(tag, "handleIntent USB_DEVICE_ATTACHED ${device.deviceName}")
        ioExecutor.execute {
            if (modelFor(device) != null) onMatchingAttach(device)
        }
    }

    // --- flow ---------------------------------------------------------------

    private fun onMatchingAttach(device: UsbDevice) {
        // If we already have permission (e.g. user ticked "use by default", or a
        // previously-granted device on replug), open silently. Otherwise emit an
        // "attached" event so Dart can decide (known -> requestDevice; new -> prompt).
        if (usbManager.hasPermission(device)) {
            openAndEmit(device)
        } else {
            emit(mapOf("event" to "attached", "hasPermission" to false) + deviceSignature(device))
        }
    }

    private fun ensurePermissionAndOpen(device: UsbDevice) {
        if (usbManager.hasPermission(device)) {
            openAndEmit(device)
            return
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(
            activity, 0,
            Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName),
            flags
        )
        Log.i(tag, "requesting USB permission for ${device.deviceName}")
        usbManager.requestPermission(device, pi)
    }

    // Must run on ioExecutor (openDevice blocks). Dedupes: if we already hold a valid
    // open connection for this device, re-emit its fd instead of opening a SECOND one
    // (the double-open that produced two fds, e.g. fd=175 AND fd=171).
    private fun openAndEmit(device: UsbDevice) {
        val model = modelFor(device)
        val existing = synchronized(this) { openConnections[device.deviceName] }
        if (existing != null && existing.fileDescriptor >= 0) {
            Log.i(tag, "openAndEmit: ${device.deviceName} already open fd=${existing.fileDescriptor}; re-emitting (deduped)")
            emitOpened(device, existing, model)
            return
        }
        val conn: UsbDeviceConnection? = try {
            usbManager.openDevice(device)
        } catch (t: Throwable) {
            Log.e(tag, "openDevice failed: ${t.message}", t)
            null
        }
        if (conn == null) {
            emit(mapOf("event" to "openFailed") + deviceSignature(device))
            return
        }
        synchronized(this) {
            // Replace any stale connection for the same device name.
            openConnections.remove(device.deviceName)?.let { try { it.close() } catch (_: Throwable) {} }
            openConnections[device.deviceName] = conn
        }
        emitOpened(device, conn, model)
    }

    private fun emitOpened(device: UsbDevice, conn: UsbDeviceConnection, model: DnpModel?) {
        val fd = conn.fileDescriptor // raw int; -1 if the connection is invalid
        val serial = try { if (usbManager.hasPermission(device)) device.serialNumber else null } catch (_: Throwable) { null }
        Log.i(tag, "opened ${device.deviceName} fd=$fd serial=$serial model=${model?.make}")
        emit(
            mapOf(
                "event" to "opened",
                "fd" to fd,
                "serial" to (serial ?: ""),
                "productName" to (device.productName ?: ""),
                "make" to (model?.make ?: ""),
                "modelName" to (model?.name ?: ""),
            ) + deviceSignature(device)
        )
    }

    private fun onDetach(device: UsbDevice) {
        closeDevice(device.deviceName)
        emit(mapOf("event" to "detached") + deviceSignature(device))
    }

    private fun closeDevice(deviceName: String?): Boolean {
        if (deviceName == null) return false
        val conn = synchronized(this) { openConnections.remove(deviceName) } ?: return false
        return try {
            conn.close()
            Log.i(tag, "closed connection for $deviceName")
            true
        } catch (t: Throwable) {
            Log.e(tag, "close failed for $deviceName: ${t.message}")
            false
        }
    }

    /** Enumerate matching attached devices; auto-open the permitted ones. */
    private fun scan(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (device in usbManager.deviceList.values) {
            val model = modelFor(device) ?: continue
            val has = usbManager.hasPermission(device)
            out.add(deviceSignature(device) + mapOf("hasPermission" to has, "make" to model.make, "modelName" to model.name))
            if (has) openAndEmit(device) // known/permitted -> auto-open, no prompt
        }
        Log.i(tag, "scan found ${out.size} matching device(s)")
        return out
    }

    private fun findAttached(deviceName: String): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { it.deviceName == deviceName }

    private fun deviceSignature(device: UsbDevice): Map<String, Any?> = mapOf(
        "deviceName" to device.deviceName,
        "vendorId" to device.vendorId,
        "productId" to device.productId,
    )

    private fun emit(payload: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    @Suppress("DEPRECATION")
    private fun getDeviceExtra(intent: Intent): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    companion object {
        const val METHOD_CHANNEL = "printing_ffi/usb"
        const val EVENT_CHANNEL = "printing_ffi/usb_events"
        private const val ACTION_USB_PERMISSION = "com.example.printing_ffi_example.USB_PERMISSION"

        // (unused helper retained for parity with backend endpoint selection docs)
        @Suppress("unused")
        private fun isPrinterInterface(cls: Int): Boolean = cls == UsbConstants.USB_CLASS_PER_INTERFACE
    }
}
