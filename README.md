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

## Release shrinking

Release APKs are shrunk by R8, and yt-dlp's bundle is unpacked with
commons-compress: its extra-field registry builds every class reflectively with
`Class.newInstance()`, so nothing calls those constructors directly. R8 removed
them, the registry threw `is not a concrete class` on the first zip, and every
*fresh* install of a release build died at startup — while the same build
worked when installed over the debug build that had already unpacked the bundle.
`app/android/app/proguard-rules.pro` keeps that package for that reason.

A consequence worth remembering: release builds have to be tested with
`adb uninstall` first. Installing over the previous build hides anything that
only happens on a clean install.

## Signing

Release builds are signed with the project's own key, which stays out of git:

- `app/android/upload-keystore.jks` — the key
- `app/android/key.properties` — its passwords and alias

Keep both. Android only installs an update over an app signed with the same
key, so losing them means uninstalling before a new build can be installed.
`app/android/app/build.gradle.kts` reads them when present and falls back to
the debug key otherwise, so a fresh clone still builds and runs.

The app id stays `com.spotifygrabber.spotify_grabber` even though it is the
Flutter template's shape: Android treats a different id as a different app, so
renaming it would leave the installed one — with its preferences and saved
track history — behind.

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
   percentage. `Stop after this track` ends the queue once the file in flight
   is done and keeps the list, so the rest is still ticked if you come back to
   it; `Cancel` abandons the queue and its stored record and returns to the
   start screen. The queue keeps running with the screen off or the app in the
   background: a foreground service holds a wake lock and shows the current
   track in a notification, so Android does not freeze the app or let the CPU
   sleep mid-track. When the queue ends it leaves a "Saved N tracks"
   notification.
5. Files land in `Music/SpotifyGrabber/<artist> - <title>.<ext>`, indexed by the
   system so any music player sees them. Re-downloading a song replaces the old
   file — including when the format changed — instead of adding a second copy.
6. The 🕘 button opens **Saved tracks**: every finished download with its
   artist, format, file size and time, grouped by day. *Clear history* empties
   the list after asking; the audio files are not touched.

Failures show the reason under the track (usually "No audio found for ..." when
YouTube has no close-duration match). Once the queue has ended, `Retry 1 failed
track` in the bottom bar runs just the tracks that failed — the ones that
already saved are not downloaded again.

A queue that Android interrupts — the process is killed, the phone reboots, or
the foreground service was refused and the app closed before it could retry —
is written to the app's store before it starts and after every track, so the
next launch restores the link and downloads only what is still missing. Stop
and Cancel clear that record, so neither comes back later. Swiping the app out
of recents counts as an interruption, not as a cancel: a half-finished queue
resumes on the next launch.

The list on screen is kept too, with the tracks that were ticked: kill the app
or reboot the phone while choosing what to download, and the next launch
reopens that link without starting anything. Clearing the link forgets it.

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

## Wi-Fi only

Off by default, next to auto-download in the settings. With it on, no track is
ever downloaded over mobile data: a queue waits on the list with "Waiting for
Wi-Fi" until the phone is back on Wi-Fi, and one that loses Wi-Fi between two
tracks pauses there and carries on by itself. The queue is written to the app's
store before the wait, so a queue parked for Wi-Fi also survives the app being
killed. Stop and Cancel release the wait; ethernet counts as Wi-Fi, since a
docked phone is not on mobile data.

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

## Updates

Settings shows the installed version and has **Check for updates**: it asks
GitHub for the newest release of `Kaderraji/spotify_grabber`, compares the tag
with the installed version, and when it is newer offers the release's APK in
the browser. That needs the repository to be public (the app carries no token)
and published releases: a tag such as `v1.1.0` with the signed APK as an
asset. When nothing is published GitHub answers 404 and the sheet says so; the
APK it downloads has to be signed with the same key as the installed app.

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
