package com.example.printing_ffi_example

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Minimal foreground service kept alive while a DNP dye-sub USB job is in flight.
 *
 * Dye-sub jobs take many seconds (image -> raster -> USB), during which the app
 * must NOT be killed — cupsd, the USB fd-server, and the live UsbDeviceConnection
 * all live in this process. A foreground service with type `connectedDevice`
 * signals Android to keep the process resident.
 *
 * Lifecycle is driven from Dart via the `printing_ffi/usb` MethodChannel
 * (startForeground / stopForeground) around job submission, so it is only up while
 * actually printing. Keep it dumb: no USB logic here, just a persistent notice.
 */
class DnpUsbForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Printing to DNP printer…"
        startAsForeground(text)
        // START_NOT_STICKY: don't relaunch if the system kills us; the Dart layer
        // re-starts it on the next job.
        return START_NOT_STICKY
    }

    private fun startAsForeground(text: String) {
        ensureChannel(this)
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("DNP printing")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        Log.i(TAG, "foreground service started: $text")
    }

    companion object {
        private const val TAG = "DnpUsbFgs"
        private const val CHANNEL_ID = "dnp_usb_print"
        private const val NOTIFICATION_ID = 4711
        const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            val i = Intent(context, DnpUsbForegroundService::class.java).apply {
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DnpUsbForegroundService::class.java))
            Log.i(TAG, "foreground service stop requested")
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "DNP USB printing",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Shown while a photo is printing to a USB DNP printer." }
                nm.createNotificationChannel(ch)
            }
        }
    }
}
