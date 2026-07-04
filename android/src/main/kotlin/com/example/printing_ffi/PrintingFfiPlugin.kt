package com.example.printing_ffi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * Hybrid FFI + method-channel plugin for the Android CUPS / DNP USB port.
 *
 * This one Kotlin class owns everything the app used to host in its MainActivity:
 *
 *  - `printing_ffi/cups`  (MethodChannel): getCupsPaths — extracts the bundled
 *    share/cups + share/gutenprint + docroot assets into the app sandbox and hands
 *    Dart the paths it needs to boot the bundled cupsd (nativeLibDir/serverRoot/
 *    dataDir/docRoot).
 *  - `printing_ffi/usb`   (MethodChannel) + `printing_ffi/usb_events` (EventChannel):
 *    the DNP USB auto-detect layer (see [DnpUsbManager]) — attach/detach, permission,
 *    fd handoff, and the foreground service.
 *
 * The channel names + method/arg/event shapes are UNCHANGED from the example's
 * MainActivity/DnpUsbManager, so the app's existing Dart (CupsAndroidBoot / DnpUsb)
 * keeps working with zero changes.
 *
 * Lifecycle (FlutterPlugin + ActivityAware):
 *  - onAttachedToEngine: stash the application context, register the cups channel and
 *    the USB channels ([DnpUsbManager.attachChannels]). Engine-scoped, so the USB
 *    stack survives an Activity config change.
 *  - onAttachedToActivity: stash the Activity, register the USB receivers, feed the
 *    initial launch intent (cold start from USB_DEVICE_ATTACHED), wire onNewIntent for
 *    hotplug replug, and request POST_NOTIFICATIONS (C10) for the FGS notification.
 *  - onDetachedFromActivityForConfigChanges: DOES NOT tear down USB / receivers /
 *    executor (rotation/backgrounding must not kill an active print — C11). Only drops
 *    the transient onNewIntent listener; the live USB connection + FGS survive.
 *  - onDetachedFromActivity (real detach): unregister receivers, drop the Activity ref.
 *  - onDetachedFromEngine: full shutdown (close connections + executor).
 *
 * Logs: cups under "PrintingFfiCups", USB under "PrintingFfiUsb". Watch with:
 *   adb logcat -s PrintingFfiCups PrintingFfiUsb
 */
class PrintingFfiPlugin : FlutterPlugin, ActivityAware {

    private val tag = "PrintingFfiCups"
    private val cupsChannelName = "printing_ffi/cups"

    private lateinit var appContext: Context
    private var cupsChannel: MethodChannel? = null
    private var usb: DnpUsbManager? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var newIntentListener: PluginRegistry.NewIntentListener? = null

    // --- FlutterPlugin -------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val messenger = binding.binaryMessenger

        // USB manager: engine-scoped so the USB stack (channels, executor, open
        // connections) survives an Activity config change and doesn't kill an
        // in-flight print (C11). Receivers are registered later, at Activity attach.
        usb = DnpUsbManager(appContext, messenger).also { it.attachChannels() }

        cupsChannel = MethodChannel(messenger, cupsChannelName).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCupsPaths" -> handleGetCupsPaths(result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cupsChannel?.setMethodCallHandler(null)
        cupsChannel = null
        usb?.shutdown()
        usb = null
    }

    // --- ActivityAware -------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        usb?.registerReceivers()

        // Cold start: the app may have been launched by Android's "open with" for a
        // plugged-in DNP printer (USB_DEVICE_ATTACHED). Feed that launch intent.
        usb?.handleIntent(binding.activity.intent)

        // Hotplug: the launcher Activity is singleTop (C9), so a subsequent
        // USB_DEVICE_ATTACHED (replug while the app is open) arrives as a new intent.
        val listener = PluginRegistry.NewIntentListener { intent ->
            usb?.handleIntent(intent)
            false // don't consume; let other listeners see it
        }
        newIntentListener = listener
        binding.addOnNewIntentListener(listener)

        // C10: the FGS posts a notification; on Android 13+ POST_NOTIFICATIONS is a
        // runtime permission. Request it up front so the print notification isn't
        // silently blocked. Degraded path if not granted: printing still works (the
        // FGS keeps the process alive), only the notification may be suppressed.
        maybeRequestPostNotifications(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // Re-wire the transient Activity refs after a config change. USB receivers +
        // executor were intentionally NOT torn down (C11), so nothing else to restore.
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // C11: rotation / backgrounding. Do NOT unregister USB receivers or shut the
        // executor — an in-flight dye-sub print (held alive by the FGS + the live
        // UsbDeviceConnection) must survive. Only drop the transient onNewIntent
        // listener + Activity ref; the USB stack stays live.
        detachActivityRefs(unregisterUsb = false)
    }

    override fun onDetachedFromActivity() {
        // Real detach (app finishing). Now it's safe to unregister the USB receivers
        // and drop the Activity ref. Open connections + executor are torn down at
        // engine detach (onDetachedFromEngine).
        detachActivityRefs(unregisterUsb = true)
    }

    private fun detachActivityRefs(unregisterUsb: Boolean) {
        newIntentListener?.let { activityBinding?.removeOnNewIntentListener(it) }
        newIntentListener = null
        if (unregisterUsb) usb?.unregisterReceivers()
        activityBinding = null
        activity = null
    }

    private fun maybeRequestPostNotifications(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val perm = android.Manifest.permission.POST_NOTIFICATIONS
        if (activity.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED) return
        try {
            // requestPermissions is available from API 23; minSdk is 24, and this path
            // is guarded to SDK 33+ above, so calling it directly needs no androidx.core.
            activity.requestPermissions(arrayOf(perm), REQ_POST_NOTIFICATIONS)
        } catch (t: Throwable) {
            // Degraded path: printing still works; the FGS notification may be
            // suppressed until the user grants it in system settings.
            Log.w(tag, "POST_NOTIFICATIONS request failed: ${t.message}")
        }
    }

    // --- cups: getCupsPaths + asset extraction (moved from MainActivity) ------

    private fun handleGetCupsPaths(result: MethodChannel.Result) {
        // Extraction copies several MB / hundreds of asset files. It MUST run off the
        // platform main thread or it ANRs the app (and, being blocking on every
        // launch, ANR-kills into a relaunch loop). Run on a worker thread and reply on
        // the main thread. Extraction is also idempotent (see extractIfStale) so it
        // only actually copies after an app update.
        val context = appContext
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            try {
                val nativeDir = context.applicationInfo.nativeLibraryDir
                val serverRoot = File(context.filesDir, "cups").apply { mkdirs() }.absolutePath
                val dataDir = extractCupsData(context)
                val docRoot = extractCupsDocRoot(context)
                Log.i(tag, "getCupsPaths nativeDir=$nativeDir serverRoot=$serverRoot dataDir=$dataDir docRoot=$docRoot")
                val payload = mapOf(
                    "nativeLibDir" to nativeDir,
                    "serverRoot" to serverRoot,
                    "dataDir" to dataDir,
                    "docRoot" to docRoot
                )
                main.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(tag, "getCupsPaths failed: ${t.message}", t)
                main.post { result.error("CUPS_PATHS", t.message, null) }
            }
        }.start()
    }

    /**
     * A stamp value that changes when the APK (and thus its bundled assets) changes.
     * Using the package's lastUpdateTime means we re-extract exactly once after an
     * install/update, and skip the copy on every normal launch.
     */
    private fun assetStamp(context: Context): String =
        try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        } catch (_: Throwable) {
            "0"
        }

    /**
     * Runs [copy] into [outRoot] only if the assets haven't already been extracted for
     * the current APK version (tracked by a `.asset_stamp` file). Returns outRoot's path.
     */
    private fun extractIfStale(context: Context, outRoot: File, label: String, copy: () -> Unit): String {
        val stamp = File(outRoot, ".asset_stamp")
        val want = assetStamp(context)
        if (stamp.exists() && runCatching { stamp.readText() }.getOrNull() == want) {
            Log.i(tag, "$label already extracted (stamp=$want), skipping")
            return outRoot.absolutePath
        }
        Log.i(tag, "$label extracting (stamp=$want)...")
        copy()
        outRoot.mkdirs()
        runCatching { stamp.writeText(want) }
        Log.i(tag, "$label extracted to ${outRoot.absolutePath}")
        return outRoot.absolutePath
    }

    /**
     * Copies the bundled share/cups/{mime,data,templates} + share/gutenprint assets
     * into an app-private dir. Idempotent per APK version (see extractIfStale).
     */
    private fun extractCupsData(context: Context): String {
        val outRoot = File(context.filesDir, "cupsdata")
        return extractIfStale(context, outRoot, "cups+gutenprint data") {
            // share/cups/{mime,data} (needed to boot) AND share/cups/templates
            // (the web-interface CGIs find these at $CUPS_DATADIR/templates).
            copyAssetDir(context.assets, "cups/share/cups", File(outRoot, "share/cups"))
            // Gutenprint driver DATA (share/gutenprint/5.3/xml/, ~6.6 MB): the DNP
            // dye-sub filter/backend/genppd read it at runtime. Extract it as a
            // SIBLING of share/cups so the FFI side can derive
            // STP_DATA_PATH = <dataDir>/share/gutenprint/5.3/xml (see start_cups_server).
            copyAssetDir(context.assets, "gutenprint/share/gutenprint", File(outRoot, "share/gutenprint"))
        }
    }

    /**
     * Extracts the static web DocumentRoot (index.html, css, images, help) that
     * cupsd serves for the web interface. Idempotent per APK version.
     */
    private fun extractCupsDocRoot(context: Context): String {
        val docRoot = File(context.filesDir, "cupsdoc")
        return extractIfStale(context, docRoot, "cups docroot") {
            copyAssetDir(context.assets, "cups/share/doc/cups", docRoot)
        }
    }

    private fun copyAssetDir(am: AssetManager, assetPath: String, dest: File) {
        val children = am.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            // It's a file (or empty dir). Try copying as a file.
            try {
                am.open(assetPath).use { input ->
                    dest.parentFile?.mkdirs()
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                // cupsd's get_file() serves the DocumentRoot (cups.css, images, help)
                // only if each file is world-readable (S_IROTH); app-private files are
                // created 0600, so without this the web UI loads completely unstyled
                // (every /cups.css, /images/* 404s: "must be world-readable"). Same-uid
                // reads work regardless — this bit only satisfies cupsd's own check.
                dest.setReadable(true, false)
            } catch (_: Throwable) {
                // not a file; ignore
            }
            return
        }
        dest.mkdirs()
        // Dirs on the served path likewise need world read+traverse for get_file().
        dest.setReadable(true, false)
        dest.setExecutable(true, false)
        for (child in children) {
            copyAssetDir(am, "$assetPath/$child", File(dest, child))
        }
    }

    companion object {
        private const val REQ_POST_NOTIFICATIONS = 0x4712
    }
}
