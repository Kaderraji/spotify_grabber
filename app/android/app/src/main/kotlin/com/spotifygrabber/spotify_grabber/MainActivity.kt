package com.spotifygrabber.spotify_grabber

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
    private lateinit var downloader: OnDeviceDownloader

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
                    val title = call.argument<String>("title") ?: name
                    val artist = call.argument<String>("artist") ?: ""
                    val id = call.argument<String>("id") ?: name
                    val duration = call.argument<Int>("duration") ?: 0
                    if (query == null || name == null) {
                        result.error("bad_args", "query and name are required", null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val file = downloader.download(
                                query = query,
                                durationSec = duration,
                                baseName = name,
                                title = title,
                                artist = artist,
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

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}
