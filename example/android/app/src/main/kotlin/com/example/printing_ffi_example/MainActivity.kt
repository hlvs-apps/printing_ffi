package com.example.printing_ffi_example

import android.content.Intent
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Phase 1: bundled cupsd inside the app.
 *
 * Exposes a MethodChannel ("printing_ffi/cups") that hands Dart the paths it needs
 * to boot the bundled cupsd from the app sandbox (at the app uid):
 *   - nativeLibraryDir: where AGP extracted the bundled lib*.so executables.
 *   - filesDir:         app-writable root for cupsd config/spool/logs (serverRoot).
 *   - dataDir:          where we extract the bundled share/cups assets (mime+data).
 *
 * Logs under the "PrintingFfiCups" tag. Watch with: adb logcat -s PrintingFfiCups
 */
class MainActivity : FlutterActivity() {
    private val tag = "PrintingFfiCups"
    private val channelName = "printing_ffi/cups"

    // DNP USB auto-detect layer (attach/detach/permission/fd + FGS control).
    private var usbManager: DnpUsbManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Wire the USB manager (printing_ffi/usb MethodChannel + printing_ffi/usb_events
        // EventChannel). Then feed it the launch intent, in case the app was opened by
        // Android's "open with" for a plugged-in DNP printer (USB_DEVICE_ATTACHED).
        usbManager = DnpUsbManager(this, flutterEngine.dartExecutor.binaryMessenger).also {
            it.register()
            it.handleIntent(intent)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCupsPaths" -> {
                    // Extraction copies several MB / hundreds of asset files. It MUST run
                    // off the platform main thread or it ANRs the app (and, being blocking
                    // on every launch, ANR-kills into a relaunch loop). Run on a worker
                    // thread and reply on the main thread. Extraction is also idempotent
                    // (see extractIfStale) so it only actually copies after an app update.
                    Thread {
                        try {
                            val nativeDir = applicationInfo.nativeLibraryDir
                            val serverRoot = File(filesDir, "cups").apply { mkdirs() }.absolutePath
                            val dataDir = extractCupsData()
                            val docRoot = extractCupsDocRoot()
                            Log.i(tag, "getCupsPaths nativeDir=$nativeDir serverRoot=$serverRoot dataDir=$dataDir docRoot=$docRoot")
                            val payload = mapOf(
                                "nativeLibDir" to nativeDir,
                                "serverRoot" to serverRoot,
                                "dataDir" to dataDir,
                                "docRoot" to docRoot
                            )
                            runOnUiThread { result.success(payload) }
                        } catch (t: Throwable) {
                            Log.e(tag, "getCupsPaths failed: ${t.message}", t)
                            runOnUiThread { result.error("CUPS_PATHS", t.message, null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    // The activity is singleTop, so a subsequent USB_DEVICE_ATTACHED (device replug
    // while the app is already open) arrives here rather than a fresh launch.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        usbManager?.handleIntent(intent)
    }

    override fun onDestroy() {
        usbManager?.unregister()
        usbManager = null
        super.onDestroy()
    }

    /**
     * A stamp value that changes when the APK (and thus its bundled assets) changes.
     * Using the package's lastUpdateTime means we re-extract exactly once after an
     * install/update, and skip the copy on every normal launch.
     */
    private fun assetStamp(): String =
        try {
            packageManager.getPackageInfo(packageName, 0).lastUpdateTime.toString()
        } catch (_: Throwable) {
            "0"
        }

    /**
     * Runs [copy] into [outRoot] only if the assets haven't already been extracted for
     * the current APK version (tracked by a `.asset_stamp` file). Returns outRoot's path.
     */
    private fun extractIfStale(outRoot: File, label: String, copy: () -> Unit): String {
        val stamp = File(outRoot, ".asset_stamp")
        val want = assetStamp()
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
    private fun extractCupsData(): String {
        val outRoot = File(filesDir, "cupsdata")
        return extractIfStale(outRoot, "cups+gutenprint data") {
            // share/cups/{mime,data} (needed to boot) AND share/cups/templates
            // (the web-interface CGIs find these at $CUPS_DATADIR/templates).
            copyAssetDir("cups/share/cups", File(outRoot, "share/cups"))
            // Gutenprint driver DATA (share/gutenprint/5.3/xml/, ~6.6 MB): the DNP
            // dye-sub filter/backend/genppd read it at runtime. Extract it as a
            // SIBLING of share/cups so the FFI side can derive
            // STP_DATA_PATH = <dataDir>/share/gutenprint/5.3/xml (see start_cups_server).
            copyAssetDir("gutenprint/share/gutenprint", File(outRoot, "share/gutenprint"))
        }
    }

    /**
     * Extracts the static web DocumentRoot (index.html, css, images, help) that
     * cupsd serves for the web interface. Idempotent per APK version.
     */
    private fun extractCupsDocRoot(): String {
        val docRoot = File(filesDir, "cupsdoc")
        return extractIfStale(docRoot, "cups docroot") {
            copyAssetDir("cups/share/doc/cups", docRoot)
        }
    }

    private fun copyAssetDir(assetPath: String, dest: File) {
        val am = assets
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
            copyAssetDir("$assetPath/$child", File(dest, child))
        }
    }
}
