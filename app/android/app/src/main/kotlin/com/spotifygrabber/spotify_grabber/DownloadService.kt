package com.spotifygrabber.spotify_grabber

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps a running download queue alive while the app is not on screen.
 *
 * Android freezes and eventually kills background apps, and with the screen
 * off the CPU and radio can go back to sleep mid-track. A foreground service
 * with a wake lock is the supported way to say "this work is still going":
 * the queue keeps downloading with the screen off or the app in the
 * background, and the notification says which track is in flight.
 */
class DownloadService : Service() {

    private val notifications by lazy {
        getSystemService(NotificationManager::class.java)
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private var position = 0
    private var total = 0
    private var label = ""
    private var percent = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_BEGIN -> {
                total = intent.getIntExtra(EXTRA_TOTAL, 0)
                position = 1
                percent = 0
                startForeground(progress())
                holdLocks()
            }

            ACTION_PROGRESS -> {
                position = intent.getIntExtra(EXTRA_POSITION, position)
                total = intent.getIntExtra(EXTRA_TOTAL, total)
                label = intent.getStringExtra(EXTRA_LABEL) ?: label
                percent = intent.getIntExtra(EXTRA_PERCENT, percent)
                notifications.notify(FOREGROUND_ID, progress())
            }

            ACTION_END -> {
                val saved = intent.getIntExtra(EXTRA_SAVED, 0)
                releaseLocks()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                if (saved > 0) notifications.notify(DONE_ID, finished(saved))
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun startForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                FOREGROUND_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
    }

    private fun holdLocks() {
        if (wakeLock == null) {
            val power = getSystemService(PowerManager::class.java)
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:download")
                .apply { setReferenceCounted(false); acquire(MAX_RUNTIME_MS) }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$TAG:wifi")
                .apply { setReferenceCounted(false); acquire() }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
    }

    private fun progress(): Notification {
        val title = if (total > 1) "Downloading $position of $total" else "Downloading"
        return builder(title, label)
            .setProgress(100, percent.coerceIn(0, 100), percent <= 0)
            .setOngoing(true)
            .build()
    }

    private fun finished(saved: Int): Notification {
        val title = "Saved $saved track${if (saved == 1) "" else "s"} to Music"
        return builder(title, "In Music/SpotifyGrabber")
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
    }

    private fun builder(title: String, text: String): NotificationCompat.Builder {
        channel()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp())
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
    }

    private fun channel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (notifications.getNotificationChannel(CHANNEL_ID) != null) return
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Progress of the tracks being saved" },
        )
    }

    private fun openApp(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        private const val TAG = "GRABBER_SERVICE"
        private const val CHANNEL_ID = "downloads"
        private const val FOREGROUND_ID = 7301
        private const val DONE_ID = 7302
        private const val MAX_RUNTIME_MS = 6 * 60 * 60 * 1000L

        private const val ACTION_BEGIN = "begin"
        private const val ACTION_PROGRESS = "progress"
        private const val ACTION_END = "end"
        private const val EXTRA_TOTAL = "total"
        private const val EXTRA_POSITION = "position"
        private const val EXTRA_LABEL = "label"
        private const val EXTRA_PERCENT = "percent"
        private const val EXTRA_SAVED = "saved"

        /** Starts the service for a queue of [total] tracks. */
        fun begin(context: Context, total: Int) {
            val intent = Intent(context, DownloadService::class.java)
                .setAction(ACTION_BEGIN)
                .putExtra(EXTRA_TOTAL, total)
            ContextCompat.startForegroundService(context, intent)
        }

        /** Moves the notification to the track currently being fetched. */
        fun update(context: Context, position: Int, total: Int, label: String, percent: Int) {
            val intent = Intent(context, DownloadService::class.java)
                .setAction(ACTION_PROGRESS)
                .putExtra(EXTRA_POSITION, position)
                .putExtra(EXTRA_TOTAL, total)
                .putExtra(EXTRA_LABEL, label)
                .putExtra(EXTRA_PERCENT, percent)
            runCatching { context.startService(intent) }
        }

        /** Ends the queue and leaves a short "saved" notification behind. */
        fun end(context: Context, saved: Int) {
            val intent = Intent(context, DownloadService::class.java)
                .setAction(ACTION_END)
                .putExtra(EXTRA_SAVED, saved)
            runCatching { context.startService(intent) }
        }
    }
}
