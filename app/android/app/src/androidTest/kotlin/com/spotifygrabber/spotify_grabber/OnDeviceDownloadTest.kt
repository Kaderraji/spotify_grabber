package com.spotifygrabber.spotify_grabber

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.youtubedl_android.YoutubeDL.UpdateChannel
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Proves whether the phone can download audio on its own: no server, no PC.
 * Run with: ./gradlew :app:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class OnDeviceDownloadTest {

    @Test
    fun downloadsAudioWithoutPc() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        YoutubeDL.getInstance().init(context)
        Log.i(TAG, "bundled ytdlp version: ${YoutubeDL.getInstance().version(context)}")

        // The bundled yt-dlp is months old and YouTube rejects it (SABR/403),
        // so pull the nightly build before trying anything.
        YoutubeDL.getInstance().updateYoutubeDL(context, UpdateChannel.NIGHTLY)
        Log.i(TAG, "updated ytdlp version: ${YoutubeDL.getInstance().version(context)}")

        val outDir = File(context.getExternalFilesDir(null), "probe").apply { mkdirs() }
        outDir.listFiles()?.forEach { it.delete() }

        val request = YoutubeDLRequest("https://www.youtube.com/watch?v=uqrKgjvP1hA")
        request.addOption("-x")
        request.addOption("--audio-format", "m4a")
        request.addOption("--no-playlist")
        request.addOption("-o", File(outDir, "%(title)s.%(ext)s").absolutePath)

        val response = YoutubeDL.getInstance().execute(request, null) { progress, eta, line ->
            Log.i(TAG, "progress=$progress etaInSecs=$eta $line")
        }

        Log.i(TAG, "exit=${response.exitCode}")
        Log.i(TAG, "out=${response.out}")
        Log.i(TAG, "err=${response.err}")

        val files = outDir.listFiles() ?: emptyArray()
        files.forEach { Log.i(TAG, "file=${it.name} bytes=${it.length()}") }
        assertTrue(
            "yt-dlp produced no audio. err=${response.err}",
            files.any { it.length() > 100_000 },
        )
    }

    private companion object {
        const val TAG = "GRABBER_PROBE"
    }
}
