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
     * Searches YouTube for [query] and saves the best audio match in the chosen
     * [format] into the phone's music library. When [durationSec] is known the
     * result is filtered to a close duration, which drops sped-up/slowed/cover
     * versions.
     */
    fun download(
        query: String,
        durationSec: Int,
        baseName: String,
        title: String,
        artist: String,
        format: String,
        onProgress: (Float) -> Unit,
    ): SavedFile {
        initEngines()
        val spec = AudioSpec.of(format)

        val workDir = File(context.cacheDir, "downloads").apply { mkdirs() }
        workDir.listFiles { file -> file.name.startsWith(baseName) }?.forEach { it.delete() }

        fun run(search: String, filtered: Boolean): YoutubeDLResponse {
            val request = YoutubeDLRequest("$search:$query")
            request.addOption("-x")
            request.addOption("--audio-format", spec.container)
            request.addOption("--audio-quality", spec.quality)
            // Pick a source that is already in the target container when
            // YouTube has one. yt-dlp then remuxes instead of re-encoding:
            // on a phone an AAC encode of a 4-minute track costs ~20 s and
            // inflates 3.5 MB of AAC into 12 MB, for no audible gain.
            request.addOption("-f", spec.source)
            request.addOption("--no-playlist")
            request.addOption("--embed-metadata")
            // YouTube's own title reads "(Official Video) (4K Remaster)" and
            // its channel name is not always the artist. Overwrite both with
            // the Spotify values before the tags are written.
            request.addCommands(
                listOf(
                    "--replace-in-metadata", "title", "^.*", literal(title),
                    "--replace-in-metadata", "artist", "^.*", literal(artist),
                ),
            )
            request.addOption("--embed-thumbnail")
            request.addOption("--convert-thumbnails", "jpg")
            request.addOption("-o", File(workDir, "$baseName.%(ext)s").absolutePath)
            if (filtered && durationSec > 30) {
                request.addOption(
                    "--match-filter",
                    "duration > ${durationSec - 20} & duration < ${durationSec + 20}",
                )
                // Search five candidates but keep the first one that fits.
                // The top hit is often the music video, which runs long.
                request.addOption("--max-downloads", "1")
            }
            return YoutubeDL.getInstance().execute(request, null) { progress, _, _ ->
                if (progress >= 0f) onProgress(progress)
            }
        }

        fun produced(): File? = workDir.listFiles { file -> file.name.startsWith(baseName) }
            ?.filter { it.isFile && it.length() > 0 }
            ?.maxByOrNull { it.length() }

        // A rejected candidate is not an error: yt-dlp exits cleanly having
        // saved nothing, so look for the file rather than for an exception.
        var file: File? = null
        if (durationSec > 30) {
            try {
                run("ytsearch5", filtered = true)
            } catch (error: Exception) {
                Log.i(TAG, "no result inside the duration window for $query", error)
            }
            file = produced()
        }
        if (file == null) {
            run("ytsearch1", filtered = false)
            file = produced()
        }

        val produced = file ?: throw IllegalStateException("No audio found for \"$query\".")

        val extension = produced.extension.ifEmpty { spec.container }
        val saved = publish(
            source = produced,
            name = "$baseName.$extension",
            title = title,
            artist = artist,
            mimeType = spec.mimeType(extension),
        )
        produced.delete()
        return saved
    }

    /** yt-dlp reads the replacement as a regex template; a stray backslash throws. */
    private fun literal(value: String) = value.replace("\\", "\\\\")

    private fun initEngines() {
        if (initialized) return
        YoutubeDL.getInstance().init(context)
        FFmpeg.getInstance().init(context)
        initialized = true
    }

    /** Copies the finished track into Music/SpotifyGrabber so players see it. */
    private fun publish(
        source: File,
        name: String,
        title: String,
        artist: String,
        mimeType: String,
    ): SavedFile {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val relative = "${Environment.DIRECTORY_MUSIC}/$FOLDER"
            val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            // Drop an earlier download of the same song, whatever its format.
            removePrevious(relative, name.substringBeforeLast('.'))

            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
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

    /** Deletes previous copies of this song (any audio extension) on Android 10+. */
    private fun removePrevious(relativePath: String, stem: String) {
        val resolver = context.contentResolver
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val pattern = stem
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_") + ".%"
        val ids = mutableListOf<Long>()
        runCatching {
            resolver.query(
                collection,
                arrayOf(MediaStore.Audio.Media._ID),
                "${MediaStore.Audio.Media.RELATIVE_PATH} = ? AND " +
                    "${MediaStore.Audio.Media.DISPLAY_NAME} LIKE ? ESCAPE '\\'",
                arrayOf("$relativePath/", pattern),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) ids.add(cursor.getLong(0))
            }
        }
        for (id in ids) {
            runCatching {
                resolver.delete(
                    collection,
                    "${MediaStore.Audio.Media._ID} = ?",
                    arrayOf(id.toString()),
                )
            }
        }
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

    /**
     * One output format. [container] is passed to yt-dlp, [quality] to its
     * audio encoder ("0" = best for the codec).
     */
    private data class AudioSpec(
        val container: String,
        val quality: String,
        val mime: String,
        val source: String,
    ) {
        fun mimeType(extension: String): String = when (extension) {
            "m4a", "aac", "mp4" -> "audio/mp4"
            "mp3" -> "audio/mpeg"
            "opus" -> "audio/opus"
            "ogg", "oga" -> "audio/ogg"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            else -> mime
        }

        companion object {
            // 256K only applies when no m4a source exists and the file has
            // to be re-encoded; "0" would spend seconds on a 430 kbps AAC.
            private val M4A = AudioSpec(
                "m4a", "256K", "audio/mp4", "bestaudio[ext=m4a]/bestaudio",
            )
            private val MP3 = AudioSpec("mp3", "192K", "audio/mpeg", "bestaudio/best")
            private val OPUS = AudioSpec(
                "opus", "0", "audio/opus", "bestaudio[ext=webm]/bestaudio",
            )
            private val FLAC = AudioSpec(
                "flac", "0", "audio/flac", "bestaudio[ext=m4a]/bestaudio",
            )

            fun of(id: String): AudioSpec = when (id) {
                "mp3" -> MP3
                "opus" -> OPUS
                "flac" -> FLAC
                else -> M4A
            }
        }
    }

    private companion object {
        const val TAG = "GRABBER_DEVICE"
        const val FOLDER = "SpotifyGrabber"
    }
}
