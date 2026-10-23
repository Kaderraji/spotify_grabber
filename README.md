# Spotify Grabber

Paste a Spotify track, album or playlist link on your phone, and the audio is
downloaded to your PC — then copied onto the phone with one tap.

Two parts:

| Part | Where it runs | What it does |
|---|---|---|
| `server/` | your PC (Python + spotdl) | reads Spotify metadata, downloads the audio, serves the finished files |
| `app/` | Android phone (Flutter) | paste link, pick tracks, watch progress, copy files to phone storage |

The phone never talks to Spotify or YouTube itself; it only talks to the PC
over your local network. That keeps the app small and means the downloader is
the same spotdl setup you already use (Deno-enabled yt-dlp, YouTube first then
SoundCloud, M4A 256k).

## Requirements

On the PC:

- `spotdl` installed with its own venv (this project uses that venv's Python,
  because it already ships `fastapi` and `uvicorn`)
- `ffmpeg`
- Deno for spotdl (optional but needed for many YouTube videos):
  `spotdl --download-deno`
- `~/.config/spotdl/config.json` with your preferred format/bitrate (the server
  sets its own output folder; format and bitrate are read from env, see below)

- To build the app: Flutter 3.44+, an Android SDK with `platforms;android-36`
  and `build-tools;36.0.0`, a **JDK 21 with `javac`** (JRE-only packages fail),
  and the **Android NDK 28.2.13676358** — AGP 9 asks for it even though this app
  has no native code.

## Run the server

```bash
cd server
./run.sh
```

It prints the address to use, e.g. `grabber listening on http://192.168.1.20:8787`.
Keep the PC and phone on the same Wi-Fi (or a Tailscale network).

Environment variables (all optional):

| Variable | Default | Meaning |
|---|---|---|
| `GRABBER_PORT` | `8787` | listen port |
| `GRABBER_ROOT` | `~/Music/spotify_grabber` | where audio is saved |
| `GRABBER_FORMAT` | `m4a` | output container |
| `GRABBER_BITRATE` | `256k` | audio bitrate |
| `GRABBER_AUDIO_PROVIDERS` | `youtube,soundcloud` | provider order |
| `GRABBER_FILENAME` | `{artists} - {title}` | file name template |
| `GRABBER_TRANSFER_TTL_HOURS` | `24` | how long uncollected phone-only files stay |

Files land in `GRABBER_ROOT/<date>/<spotify-id>/`, one folder per link.

## Build and install the app

```bash
cd app
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Or run it straight onto a connected phone with `flutter run`.

Three build details are non-obvious and already configured here:

- `android/local.properties` (git-ignored) holds `ndk.dir=/mnt/windows/android-ndk/android-ndk-r28c`
  because the NDK is installed outside the SDK. Without that line Gradle tries
  to download a fresh NDK into the SDK.
- `disable-abi-filtering=true` in `android/gradle.properties` stops Flutter
  from adding an `ndk { abiFilters }` block, which is what triggers the NDK
  requirement in the first place. The APK is built arm64-only anyway.
- `pubspec.yaml` pins `path_provider_android` and `shared_preferences_android`
  to their last non-JNI releases; the current ones need the NDK to compile C.

If your JDK is not on the system path, pass it in:
`JAVA_HOME=/path/to/jdk21 flutter build apk --release --target-platform android-arm64`.

The PC address defaults to `http://192.168.11.147:8787`. If yours differs,
either change it inside the app (gear icon → Server → Test → Save) or build
with it baked in:

```bash
flutter build apk --release --dart-define=GRABBER_SERVER=http://192.168.1.20:8787
```

## Using it

1. Start the server on the PC.
2. Paste a link (copy it from the Spotify share menu).
3. **Fetch tracks** — the app lists every track with its length; untick any you
   don't want. Tracks already in the PC library show a green tick and are
   skipped.
4. **Download** — the PC downloads them; the app polls progress every 2 s.
   Failed tracks show the reason (usually "no match found").
5. **Copy files to this phone** — pulls the finished files over Wi-Fi into
   `Android/data/com.spotifygrabber.spotify_grabber/files/spotify_grabber/<title>/`.

### Phone only (default)

The **Phone only** switch is on by default: files are downloaded into
`<GRABBER_ROOT>/transfer/<job>/`, never added to the PC library, and deleted
while the phone copies them (the app calls `POST /jobs/{id}/release` when the
copy finishes). Anything the phone never collects is swept after 24 hours, so
nothing accumulates on the PC.

Turn the switch off to keep a copy in the PC library as well; those files land
in `<GRABBER_ROOT>/<date>/<spotify-id>/` and are never touched by a release.

That folder is reachable over USB (MTP) and from most file managers. Copying
into the shared `Music` collection is not implemented yet — Android's scoped
storage needs MediaStore or a folder picker for that.

## How metadata works

Spotify now requires a Premium account for new developer API keys, so this
project does not use the Spotify Web API at all. It reads the public embed page
(`open.spotify.com/embed/{kind}/{id}`) which returns the full track list in one
request, and spotdl's own Spotify client calls are bypassed by filling every
field spotdl would otherwise re-fetch.

Consequence: title, artist, cover and track order are exact, but **album and
release year tags are empty** because the embed page does not expose them.

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | providers, format, Deno status, indexed file count |
| `POST` | `/resolve` | `{"url": "..."}` → title, cover, tracks with state |
| `POST` | `/jobs` | `{"url": "...", "track_ids": [...]}` → starts a download |
| `GET` | `/jobs/{id}` | status, counts and per-track state |
| `GET` | `/jobs/{id}/files` | finished files and their download URLs |
| `GET` | `/jobs/{id}/files/{song_id}` | the audio file itself |
| `POST` | `/jobs/{id}/release` | deletes a phone-only job's files from the PC |

Downloads run in one background worker, so jobs queue rather than collide.

## Tests

```bash
cd app && flutter test && flutter analyze
```

## Notes

- Personal use only; downloading from Spotify/YouTube is against their terms
  and this app is not meant for redistribution.
- The server must stay running while the phone uses it. If the PC sleeps, the
  app reports "Could not reach ...".
- Spotify throttles anonymous embed requests if you hammer it; a 504 from
  `/resolve` means wait a minute and retry.
