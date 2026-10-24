package com.spotifygrabber.spotify_grabber

import android.content.Intent
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
    private lateinit var downloader: OnDeviceDownloader
    private val prefs by lazy { getSharedPreferences("grabber", MODE_PRIVATE) }

    private companion object {
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
            if (call.method == "getInitialLink") {
                result.success(pendingLink)
                pendingLink = null
            } else {
                result.notImplemented()
            }
        }
        shareChannel = share
        pendingLink = pendingLink ?: spotifyLinkIn(intent)

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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = spotifyLinkIn(intent) ?: return
        val channel = shareChannel
        if (channel == null) {
            pendingLink = link
        } else {
            channel.invokeMethod("sharedLink", link)
        }
    }

    /**
     * Pulls the first Spotify link out of a shared text body. Spotify wraps the
     * link in a sentence ("Never Gonna Give You Up – Rick Astley ..."), and
     * some clients drop the https:// prefix.
     */
    private fun spotifyLinkIn(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/") != true) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (text.isNullOrEmpty()) return null
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
