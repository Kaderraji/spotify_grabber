package com.spotifygrabber.spotify_grabber

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDL.UpdateChannel
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.youtubedl_android.YoutubeDLResponse
import java.io.File
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * Downloads audio on the phone itself: yt-dlp + ffmpeg bundled in the APK.
 * No PC, no server.
 */
class OnDeviceDownloader(private val context: Context) {

    @Volatile
    private var initialized = false

    /** Initializes the engines and keeps yt-dlp fresh (YouTube changes often). */
    @Synchronized
    fun prepare(onStatus: (String) -> Unit): String {
        initEngines()
        onStatus("Checking downloader…")

        val current = runCatching { YoutubeDL.getInstance().version(context) }.getOrNull()
        if (isStale(current)) {
            onStatus("Updating downloader…")
            try {
                YoutubeDL.getInstance().updateYoutubeDL(context, UpdateChannel.NIGHTLY)
            } catch (error: Exception) {
                Log.w(TAG, "yt-dlp update failed, using $current", error)
            }
        }
        val version = runCatching { YoutubeDL.getInstance().version(context) }.getOrNull()
        onStatus("Downloader ready")
        return version ?: "unknown"
    }

    /**
     * Searches YouTube for [query] and saves the best audio match as m4a in the
     * phone's music library. When [durationSec] is known the result is filtered
     * to a close duration, which drops sped-up/slowed/cover versions.
     */
    fun download(
        query: String,
        durationSec: Int,
        baseName: String,
        title: String,
        artist: String,
        onProgress: (Float) -> Unit,
    ): SavedFile {
        initEngines()

        val workDir = File(context.cacheDir, "downloads").apply { mkdirs() }
        workDir.listFiles { file -> file.name.startsWith(baseName) }?.forEach { it.delete() }

        fun run(filtered: Boolean): YoutubeDLResponse {
            val request = YoutubeDLRequest("ytsearch1:$query")
            request.addOption("-x")
            request.addOption("--audio-format", "m4a")
            request.addOption("--audio-quality", "0")
            request.addOption("--no-playlist")
            request.addOption("--embed-metadata")
            request.addOption("--embed-thumbnail")
            request.addOption("--convert-thumbnails", "jpg")
            request.addOption("-o", File(workDir, "$baseName.%(ext)s").absolutePath)
            if (filtered && durationSec > 30) {
                request.addOption(
                    "--match-filter",
                    "duration > ${durationSec - 20} & duration < ${durationSec + 20}",
                )
            }
            return YoutubeDL.getInstance().execute(request, null) { progress, _, _ ->
                if (progress >= 0f) onProgress(progress)
            }
        }

        var failure: Exception? = null
        if (durationSec > 30) {
            try {
                run(true)
            } catch (error: Exception) {
                // No result matched the duration window; try again unfiltered.
                Log.i(TAG, "no match within duration window for $query", error)
                failure = error
            }
        }
        if (failure != null || durationSec <= 30) {
            run(false)
        }

        val produced = workDir.listFiles { file -> file.name.startsWith(baseName) }
            ?.filter { it.isFile && it.length() > 0 }
            ?.maxByOrNull { it.length() }
            ?: throw IllegalStateException("No audio found for \"$query\".")

        val name = "$baseName.m4a"
        val saved = publish(produced, name, title, artist)
        produced.delete()
        return saved
    }

    private fun initEngines() {
        if (initialized) return
        YoutubeDL.getInstance().init(context)
        FFmpeg.getInstance().init(context)
        initialized = true
    }

    /** Copies the finished track into Music/SpotifyGrabber so players see it. */
    private fun publish(source: File, name: String, title: String, artist: String): SavedFile {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val relative = "${Environment.DIRECTORY_MUSIC}/$FOLDER"
            val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            // Replace an earlier download of the same song instead of adding a copy.
            runCatching {
                resolver.delete(
                    collection,
                    "${MediaStore.Audio.Media.DISPLAY_NAME} = ? AND " +
                        "${MediaStore.Audio.Media.RELATIVE_PATH} = ?",
                    arrayOf(name, "$relative/"),
                )
            }

            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
                put(MediaStore.Audio.Media.RELATIVE_PATH, relative)
                put(MediaStore.Audio.Media.IS_MUSIC, 1)
                put(MediaStore.Audio.Media.TITLE, title)
                put(MediaStore.Audio.Media.ARTIST, artist)
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("Could not create a file in Music.")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("Could not write to Music.")
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
            } catch (error: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                throw error
            }
            return SavedFile("Music/$FOLDER/$name", source.length())
        }

        // Android 9 and older cannot write to public Music without a storage
        // permission, so keep the file in the app's own music folder instead.
        val dir = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MUSIC) ?: context.filesDir,
            FOLDER,
        ).apply { mkdirs() }
        val target = File(dir, name)
        source.copyTo(target, overwrite = true)
        return SavedFile(target.absolutePath, target.length())
    }

    private fun isStale(version: String?): Boolean {
        if (version.isNullOrBlank()) return true
        return try {
            val release = LocalDate.parse(version.take(10))
            ChronoUnit.DAYS.between(release, LocalDate.now()) > 30
        } catch (_: Exception) {
            false
        }
    }

    data class SavedFile(val path: String, val size: Long)

    private companion object {
        const val TAG = "GRABBER_DEVICE"
        const val FOLDER = "SpotifyGrabber"
    }
}
