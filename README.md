# Spotify Grabber

Paste a Spotify track, album or playlist link on your phone and the audio is
downloaded **on the phone itself** into `Music/SpotifyGrabber`. No PC, no
server, no Wi-Fi requirement beyond the phone's own connection.

## How it works

| Step | What runs |
|---|---|
| Read the link | `lib/spotify_meta.dart` fetches `open.spotify.com/embed/{kind}/{id}` and parses the track list |
| Download | `youtubedl-android` (yt-dlp + ffmpeg bundled in the APK) runs `ytsearch1:<artist> - <title>` and extracts the chosen format |
| Save | `OnDeviceDownloader.kt` copies the finished file into the music library through MediaStore |

The details that make this work:

- **yt-dlp keeps itself current.** The bundled copy is whatever shipped in the
  library (2025.x) and YouTube refuses it. On startup the app updates yt-dlp to
  the nightly channel and afterwards re-checks every 30 days. The first launch
  needs a network connection for that.
- **No Deno needed.** On a PC, yt-dlp wants Deno for YouTube's JS challenge; on
  Android there is no Deno build. yt-dlp falls back to its built-in quickjs
  runtime, which is enough for the audio formats used here.
- **Search is duration-filtered.** When the Spotify track length is known, the
  top five YouTube results are searched and the first one within ±20 s is kept,
  which drops sped-up, slowed and cover versions — and skips the music video
  that runs a minute longer than the song. Only if none of the five fits does
  the download retry without the filter. A rejected candidate exits cleanly
  with no file, so the code checks for the file rather than for an exception.
- **Spotify metadata comes from the embed page**, not the Web API (which now
  needs a Premium account to create keys). Title, artists and track order are
  exact; album and release year are not exposed there. The page is small
  (~10 KB), so the wait is Spotify's own response time: one keep-alive
  connection is opened at launch and reused for every fetch, and a link that
  was resolved in the last ten minutes is answered from memory.
- **File tags are rewritten to the Spotify values.** yt-dlp's own tags carry the
  YouTube title (`... (Official Video) (4K Remaster)`) and the channel name, so
  `--replace-in-metadata` overwrites title and artist before the tags are
  written. Without it a player would show the upload name, not the song name.
- **One copy per song.** Each save first deletes any earlier file with the same
  `artist - title` stem in `Music/SpotifyGrabber`, whatever extension, so
  switching formats replaces the old download instead of duplicating it.

## Requirements

- Flutter 3.44+ and an Android SDK with `platforms;android-36`,
  `build-tools;36.0.0`
- A **JDK 21 with `javac`** for Gradle (a JRE-only package fails with
  `does not provide the required capabilities: [JAVA_COMPILER]`)
- Android NDK 28.2.13676358 — AGP 9 wants it even though this app has no native
  code of its own

## Build and install

```bash
./scripts/install-release.sh
```

Builds the arm64 release APK and installs it on the connected phone in one step.
For a debug build with hot reload, run `flutter run` in `app/` instead.

The APK is arm64 only: `ndk { abiFilters }` in `app/android/app/build.gradle.kts`
drops the three other ABIs that yt-dlp, ffmpeg and deno ship, which takes it from
~207 MB to ~62 MB. Remove that filter to build for an x86 emulator.

Gradle downloads the Flutter engine jars from `storage.googleapis.com`. If that
host is blocked the build hangs at `Running Gradle task 'assembleDebug'...`;
the jars are already in `$FLUTTER_ROOT/bin/cache/artifacts/engine/*/flutter.jar`,
so serve them as a local Maven repo and build with
`FLUTTER_STORAGE_BASE_URL=file://<that repo>`.

Two build details are already configured here:

- `android/local.properties` (git-ignored) holds
  `ndk.dir=/mnt/windows/android-ndk/android-ndk-r28c` because the NDK lives
  outside the SDK; without it Gradle downloads a fresh NDK into the SDK.
- `disable-abi-filtering=true` in `android/gradle.properties` stops Flutter
  from adding an `ndk { abiFilters }` block, which is what triggers the NDK
  requirement in the first place.

On MIUI, `adb install` is refused while the screen is locked; keep the phone
unlocked (and "Install via USB" enabled in Developer options).

## Using it

1. Copy the link from Spotify's share menu and paste it into the app — or
   share it straight to *Spotify Grabber* from Spotify's share sheet and the
   link is pasted and fetched for you.
2. **Fetch tracks** — every track is listed with its length; untick what you
   don't want, or use *Select all* / *Clear*.
3. Pick a **format** (see below). The choice is remembered.
4. **Download** — tracks are downloaded one after another with a live
   percentage. `Stop after this track` ends the queue after the current file.
   The queue keeps running with the screen off or the app in the background: a
   foreground service holds a wake lock and shows the current track in a
   notification, so Android does not freeze the app or let the CPU sleep
   mid-track. When the queue ends it leaves a "Saved N tracks" notification;
   swiping the app out of recents stops everything.
5. Files land in `Music/SpotifyGrabber/<artist> - <title>.<ext>`, indexed by the
   system so any music player sees them. Re-downloading a song replaces the old
   file — including when the format changed — instead of adding a second copy.
6. The 🕘 button opens **Saved tracks**: every finished download with its
   artist, format, file size and time, grouped by day. *Clear history* empties
   the list after asking; the audio files are not touched.

Failures show the reason under the track (usually "No audio found for ..." when
YouTube has no close-duration match).

The app registers for `ACTION_SEND` of `text/plain`, so it shows up in the
system share sheet for any text. The shared text is scanned for a track, album
or playlist link (Spotify usually wraps it in a “song – artist … #Spotify”
line) and the bare link is what fills the field. Sharing while a download is
running leaves the link in the field and asks you to fetch it afterwards
instead of interrupting the queue. Sharing anything without a Spotify link in
it says so on the home screen instead of opening to an empty field.

## Appearance

Follows the system light/dark setting by default. The ☀︎/☾ button in the top bar
overrides it with *Match system*, *Light* or *Dark*; the choice is stored and
applied on the next launch.

## Launch screen

The window Android shows while the engine starts is the icon writ large: the
same green field and the same note-and-arrow mark, then straight into the app.
Pre-Android 12 it comes from `drawable/launch_background.xml`; Android 12 and
later use the system splash attributes in `values-v31/styles.xml`, so the OS
animation and the app agree on the colours.

## Auto-download

The tune button opens the app settings. *Auto-download* is off by default: a
fetched link is only listed, and you press Download. Turn it on and the queue
starts by itself as soon as a link is fetched — including one that arrives from
the share sheet — using the format you last picked. The choice is remembered.

## Formats

The format sheet shows what each option is for and roughly how big a track gets:

| Format | Why pick it | Measured size |
|---|---|---|
| M4A (AAC) | Spotify's own codec; balanced, plays everywhere (default) | 3.8 MB |
| MP3 (192 kbps) | Opens on absolutely anything, old players included | 5.2 MB |
| Opus | Smallest file at the same quality; needs a recent player | 3.4 MB |
| FLAC | Saved without the lossy step, for archiving | 47 MB |

Those are real numbers from one 3:33 track on the phone, not estimates; the
in-app sheet rounds them to "per 4-minute track".

The format is passed to yt-dlp as `--audio-format`, and the source is chosen to
match it (`-f bestaudio[ext=m4a]`, `[ext=webm]` for Opus): when YouTube already
serves that container yt-dlp remuxes instead of re-encoding, which removes
~20 s of phone CPU per track and stops a 3.5 MB AAC stream from being inflated
to 12 MB. Only when no such source exists does ffmpeg encode — 256K for AAC,
192K for MP3. Cover art and tags are embedded for every option. The choice is
stored in the app's preferences, so it survives restarts.

## Tests

```bash
cd app && flutter test && flutter analyze
```

## Notes

- Personal use only; downloading from Spotify/YouTube is against their terms
  and this app is not meant for redistribution.
- `server/` is the older PC-based downloader. The app no longer talks to it —
  it is kept because it still works standalone from the command line.
- Downloads keep running while the app is in the background; the foreground
  service and its wake lock are what allow the screen to go off.
