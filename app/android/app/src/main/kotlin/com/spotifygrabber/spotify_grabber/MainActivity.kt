package com.spotifygrabber.spotify_grabber

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var progressSink: EventChannel.EventSink? = null
    private var shareChannel: MethodChannel? = null
    private var pendingLink: String? = null
    private var pendingRejected: String? = null
    private var notifiedPercent = -1
    private lateinit var downloader: OnDeviceDownloader
    private val prefs by lazy { getSharedPreferences("grabber", MODE_PRIVATE) }

    private companion object {
        const val MAX_PREVIEW = 160

        val SPOTIFY_LINK = Regex(
            """(?:https?://)?open\.spotify\.com/(?:intl-[a-z-]+/)?""" +
                """(?:track|playlist|album)/[A-Za-z0-9]{22}""" +
                """|spotify:(?:track|playlist|album):[A-Za-z0-9]{22}""",
            RegexOption.IGNORE_CASE,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        downloader = OnDeviceDownloader(applicationContext)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grabber/on_device/progress",
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            },
        )

        // Links shared into the app: the launch intent before Flutter asks for
        // it, and later shares pushed over the channel.
        val share = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grabber/share",
        )
        share.setMethodCallHandler { call, result ->
            when (call.method) {
                // Both halves of a share: a link to use, or text to complain
                // about because it holds no Spotify link.
                "getInitialShare" -> {
                    result.success(
                        mapOf("link" to pendingLink, "rejected" to pendingRejected),
                    )
                    pendingLink = null
                    pendingRejected = null
                }

                else -> result.notImplemented()
            }
        }
        shareChannel = share
        if (pendingLink == null && pendingRejected == null) takeShare(intent)

        // Theme mode and the saved-track history live in the same preferences;
        // the app owns their JSON shape, this side only stores the strings.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grabber/store",
        ).setMethodCallHandler { call, result ->
            val key = call.argument<String>("key")
            when (call.method) {
                "read" -> result.success(
                    if (key == null) null else prefs.getString("store.$key", null),
                )

                "write" -> {
                    val value = call.argument<String>("value")
                    if (key == null || value == null) {
                        result.error("bad_args", "key and value are required", null)
                    } else {
                        prefs.edit().putString("store.$key", value).apply()
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "grabber/on_device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> worker.execute {
                    try {
                        val version = downloader.prepare { status ->
                            main.post { progressSink?.success(mapOf("status" to status)) }
                        }
                        main.post { result.success(version) }
                    } catch (error: Exception) {
                        main.post { result.error("prepare_failed", error.message, null) }
                    }
                }

                "download" -> {
                    val query = call.argument<String>("query")
                    val name = call.argument<String>("name")
                    if (query == null || name == null) {
                        result.error("bad_args", "query and name are required", null)
                        return@setMethodCallHandler
                    }
                    val title: String = call.argument<String>("title") ?: name
                    val artist: String = call.argument<String>("artist") ?: ""
                    val id: String = call.argument<String>("id") ?: name
                    val duration: Int = call.argument<Int>("duration") ?: 0
                    val format: String = call.argument<String>("format") ?: "m4a"
                    val position: Int = call.argument<Int>("position") ?: 1
                    val total: Int = call.argument<Int>("total") ?: 1
                    val label = listOf(artist, title).filter { it.isNotBlank() }.joinToString(" - ")
                    notifiedPercent = -1
                    DownloadService.update(applicationContext, position, total, label, 0)
                    worker.execute {
                        try {
                            val file = downloader.download(
                                query = query,
                                durationSec = duration,
                                baseName = name,
                                title = title,
                                artist = artist,
                                format = format,
                            ) { progress ->
                                // The notification does not need every percent,
                                // and each update is a service call.
                                val percent = (progress * 100).toInt()
                                if (percent >= notifiedPercent + 5) {
                                    notifiedPercent = percent
                                    DownloadService.update(
                                        applicationContext,
                                        position,
                                        total,
                                        label,
                                        percent,
                                    )
                                }
                                main.post {
                                    progressSink?.success(
                                        mapOf("id" to id, "progress" to progress),
                                    )
                                }
                            }
                            main.post {
                                result.success(
                                    mapOf("path" to file.path, "size" to file.size),
                                )
                            }
                        } catch (error: Exception) {
                            main.post { result.error("download_failed", error.message, null) }
                        }
                    }
                }

                // A queue holds the phone awake through DownloadService, so the
                // screen can go off or the app can be backgrounded mid-download.
                "startQueue" -> {
                    // false when Android 12+ refuses a background start; the
                    // app then waits until it is on screen again.
                    DownloadService.begin(applicationContext, call.argument<Int>("total") ?: 0)
                        .let { started ->
                            if (started) askForNotifications()
                            result.success(started)
                        }
                }

                "stopQueue" -> {
                    DownloadService.end(applicationContext, call.argument<Int>("saved") ?: 0)
                    result.success(null)
                }

                "getFormat" -> result.success(prefs.getString("format", "m4a"))

                "setFormat" -> {
                    val format = call.argument<String>("format") ?: "m4a"
                    prefs.edit().putString("format", format).apply()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    /** Android 13+ hides the download notification without this permission. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedText(intent) ?: return
        val link = spotifyLinkIn(text)
        val channel = shareChannel
        if (link == null) {
            if (channel == null) pendingRejected = text.take(MAX_PREVIEW) else
                channel.invokeMethod("sharedRejected", text.take(MAX_PREVIEW))
            return
        }
        if (channel == null) {
            pendingLink = link
        } else {
            channel.invokeMethod("sharedLink", link)
        }
    }

    /** Remembers what a launching share intent carried, if anything. */
    private fun takeShare(intent: Intent?) {
        val text = sharedText(intent) ?: return
        val link = spotifyLinkIn(text)
        if (link != null) pendingLink = link else pendingRejected = text.take(MAX_PREVIEW)
    }

    /** The text body of a shared item, or null when this is not a share. */
    private fun sharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/") != true) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        return if (text.isNullOrEmpty()) null else text
    }

    /**
     * Pulls the first Spotify link out of a shared text body. Spotify wraps the
     * link in a sentence ("Never Gonna Give You Up – Rick Astley ..."), and
     * some clients drop the https:// prefix.
     */
    private fun spotifyLinkIn(text: String): String? {
        val match = SPOTIFY_LINK.find(text)?.value ?: return null
        return when {
            match.startsWith("spotify:") -> match
            // The scheme is optional in the pattern, so it may already be there.
            match.startsWith("http", ignoreCase = true) -> match
            else -> "https://$match"
        }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}
