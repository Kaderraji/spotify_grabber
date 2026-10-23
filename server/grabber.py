"""Local download service for the Spotify Grabber Android app.

Runs on the PC that has spotdl configured. The phone sends a Spotify URL,
polls download progress, and then fetches the finished audio files.

Metadata comes from Spotify's public embed pages (one fast request, no account,
no developer credentials). Downloading still goes through spotdl, but the
Spotify "reinit" step is disabled by filling every field it checks, because
spotdl's metadata API client (spotapi) is slow and unstable right now.

Run it with spotdl's own Python environment (it already ships fastapi/uvicorn):

    export HOME=/home/derka
    /home/derka/.local/share/uv/tools/spotdl/bin/python -m uvicorn grabber:app \
        --host 0.0.0.0 --port 8787
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import queue
import re
import threading
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

from spotdl import Spotdl
from spotdl.types.song import Song
from spotdl.utils.config import SPOTIFY_OPTIONS

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

ROOT = Path(
    os.environ.get("GRABBER_ROOT", Path.home() / "Music" / "spotify_grabber")
).expanduser()
FORMAT = os.environ.get("GRABBER_FORMAT", "m4a")
BITRATE = os.environ.get("GRABBER_BITRATE", "256k")
PROVIDERS = [
    p.strip()
    for p in os.environ.get(
        "GRABBER_AUDIO_PROVIDERS", "youtube,soundcloud"
    ).split(",")
    if p.strip()
]
# Placeholders understood by spotdl's formatter.
FILENAME = os.environ.get("GRABBER_FILENAME", "{artists} - {title}")
MANIFEST_PATH = ROOT / ".manifest.json"
EMBED_TIMEOUT = float(os.environ.get("GRABBER_EMBED_TIMEOUT", "25"))

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def log(msg: str, *args: Any) -> None:
    print(f"[grabber] {msg % args if args else msg}", flush=True)


# --------------------------------------------------------------------------- #
# spotdl setup
# --------------------------------------------------------------------------- #


class _ErrorCapture(logging.Handler):
    """Collects ERROR records so a failed track can report why it failed."""

    def __init__(self) -> None:
        super().__init__(level=logging.ERROR)
        self.messages: List[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.messages.append(record.getMessage())
        except Exception:  # pragma: no cover - logging must never break a job
            pass

    def drain(self) -> List[str]:
        out, self.messages = self.messages, []
        return out


ERRORS = _ErrorCapture()
logging.getLogger("spotdl").addHandler(ERRORS)

SPOTDL = Spotdl(
    client_id=SPOTIFY_OPTIONS["client_id"],
    client_secret=SPOTIFY_OPTIONS["client_secret"],
    downloader_settings={
        "audio_providers": PROVIDERS,
        "lyrics_providers": [],  # no lyrics lookups: they only add network calls
        "format": FORMAT,
        "bitrate": BITRATE,
        "output": str(ROOT / "{list-name}" / (FILENAME + ".{output-ext}")),
        "overwrite": "skip",
        "threads": 4,
        "print_errors": False,
        "simple_tui": False,
        "log_level": "WARNING",
        "ffmpeg": "ffmpeg",
    },
)

# --------------------------------------------------------------------------- #
# Manifest of already-downloaded tracks (song_id -> entry)
# --------------------------------------------------------------------------- #


class Manifest:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._data: Dict[str, Dict[str, Any]] = {}
        if path.is_file():
            try:
                self._data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                log("manifest unreadable, starting fresh: %s", path)
                self._data = {}

    def get(self, song_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            entry = self._data.get(song_id)
            if not entry:
                return None
            if not Path(entry.get("path", "")).is_file():
                self._data.pop(song_id, None)  # deleted behind our back
                return None
            return dict(entry)

    def count(self) -> int:
        with self._lock:
            return len(self._data)

    def put(self, song_id: str, entry: Dict[str, Any]) -> None:
        with self._lock:
            self._data[song_id] = entry
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self.path.with_suffix(".tmp")
                tmp.write_text(json.dumps(self._data, indent=2), encoding="utf-8")
                tmp.replace(self.path)
            except OSError as exc:
                log("could not write manifest: %s", exc)


MANIFEST = Manifest(MANIFEST_PATH)

# --------------------------------------------------------------------------- #
# Spotify metadata via the public embed page
# --------------------------------------------------------------------------- #


@dataclass
class Resolved:
    url: str
    kind: str
    ident: str
    title: str
    cover_url: Optional[str]
    songs: List[Song]
    tracks: List["TrackState"]


def _kind_of(url: str) -> str:
    if "/playlist/" in url or url.startswith("spotify:playlist:"):
        return "playlist"
    if "/album/" in url or url.startswith("spotify:album:"):
        return "album"
    if "/track/" in url or url.startswith("spotify:track:"):
        return "track"
    raise ValueError("That doesn't look like a Spotify track, album or playlist link.")


def _cover_from(entity: Dict[str, Any]) -> Optional[str]:
    sources = (entity.get("coverArt") or {}).get("sources") or []
    if sources:
        return sources[-1].get("url")
    images = (entity.get("visualIdentity") or {}).get("image") or []
    if images:
        return max(images, key=lambda i: (i.get("maxHeight") or 0)).get("url")
    return None


def _track_ids(address: str) -> Tuple[str, str]:
    """Return (kind, Spotify id) for a track/album/playlist link."""
    kind = _kind_of(address)
    match = re.search(r"(?:/|:)([A-Za-z0-9]{22})", address)
    if not match:
        raise ValueError("Could not read the Spotify id from that link.")
    return kind, match.group(1)


def fetch_metadata(address: str) -> Tuple[str, str, str, Optional[str], List[Dict[str, Any]]]:
    """Read a Spotify embed page and return (kind, id, title, cover, raw tracks)."""
    kind, ident = _track_ids(address)
    embed = f"https://open.spotify.com/embed/{kind}/{ident}"
    request = urllib.request.Request(
        embed,
        headers={
            "User-Agent": USER_AGENT,
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=EMBED_TIMEOUT) as response:
            html = response.read().decode("utf-8", "replace")
    except Exception as exc:
        raise TimeoutError(f"Could not reach Spotify: {exc}") from exc

    blob = re.search(
        r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
        html,
        re.S,
    )
    if not blob:
        raise ValueError("Spotify returned an unexpected page for that link.")

    data = json.loads(blob.group(1))
    entity = (
        data.get("props", {})
        .get("pageProps", {})
        .get("state", {})
        .get("data", {})
        .get("entity", {})
    )
    if not entity:
        raise ValueError("This link is private, region-locked or empty.")

    title = entity.get("name") or entity.get("title") or ident
    cover = _cover_from(entity)
    tracks = list(entity.get("trackList") or [])
    if not tracks and entity.get("uri"):
        tracks = [entity]
    if not tracks:
        raise ValueError("Spotify listed no playable tracks for this link.")
    return kind, ident, title, cover, tracks


def _artist_names(track: Dict[str, Any]) -> List[str]:
    artists = track.get("artists") or []
    names = [a.get("name") for a in artists if isinstance(a, dict) and a.get("name")]
    if not names and track.get("subtitle"):
        names = [part.strip() for part in str(track["subtitle"]).split(",") if part.strip()]
    return names or ["Unknown artist"]


def _to_song(
    track: Dict[str, Any],
    *,
    ident: str,
    list_title: str,
    list_url: str,
    cover: Optional[str],
    position: int,
    total: int,
) -> Song:
    names = _artist_names(track)
    track_id = str(track.get("uri", "")).split(":")[-1] or f"{ident}-{position}"
    duration_ms = track.get("duration") or 0
    return Song.from_missing_data(
        name=track.get("title") or track.get("name") or "Unknown title",
        artists=names,
        artist=names[0],
        genres=[],  # filled in so spotdl never re-fetches Spotify metadata
        disc_number=1,
        disc_count=1,
        album_name="",
        album_artist=names[0],
        duration=int(duration_ms / 1000),
        year=None,
        date="",
        track_number=position,
        tracks_count=total,
        song_id=track_id,
        explicit=bool(track.get("isExplicit")),
        publisher="",
        url=f"https://open.spotify.com/track/{track_id}",
        isrc=None,
        cover_url=cover,
        copyright_text=None,
        album_id=ident,
        list_name=list_title,
        list_url=list_url,
        list_position=position,
        list_length=total,
        album_type="album",
    )


def resolve(address: str) -> Resolved:
    kind, ident, title, cover, raw_tracks = fetch_metadata(address)
    total = len(raw_tracks)
    songs = [
        _to_song(
            track,
            ident=ident,
            list_title=title,
            list_url=address,
            cover=cover,
            position=index,
            total=total,
        )
        for index, track in enumerate(raw_tracks, start=1)
    ]
    tracks = [_track_state(song) for song in songs]
    return Resolved(
        url=address,
        kind=kind,
        ident=ident,
        title=title,
        cover_url=cover,
        songs=songs,
        tracks=tracks,
    )


# --------------------------------------------------------------------------- #
# Job model
# --------------------------------------------------------------------------- #


@dataclass
class TrackState:
    song_id: str
    title: str
    artists: str
    album: str
    duration: int
    url: str
    cover_url: Optional[str] = None
    state: str = "queued"  # queued | downloading | done | present | failed
    error: Optional[str] = None
    file: Optional[str] = None
    size: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.song_id,
            "title": self.title,
            "artists": self.artists,
            "album": self.album,
            "duration": self.duration,
            "url": self.url,
            "cover_url": self.cover_url,
            "state": self.state,
            "error": self.error,
            "file": self.file,
            "size": self.size,
        }


def _track_state(song: Song) -> TrackState:
    existing = MANIFEST.get(song.song_id)
    state = TrackState(
        song_id=song.song_id,
        title=song.name,
        artists=", ".join(song.artists),
        album=song.album_name or "",
        duration=int(song.duration or 0),
        url=song.url,
        cover_url=song.cover_url,
    )
    if existing:
        state.state = "present"
        state.file = Path(existing["path"]).name
        state.size = existing.get("size")
    return state


@dataclass
class Job:
    id: str
    url: str
    kind: str
    title: str
    dir: Path
    tracks: List[TrackState]
    songs: List[Song] = field(default_factory=list, repr=False)
    status: str = "queued"  # queued | running | done | failed
    error: Optional[str] = None
    created: str = field(
        default_factory=lambda: datetime.now().isoformat(timespec="seconds")
    )

    def counts(self) -> Dict[str, int]:
        done = sum(1 for t in self.tracks if t.state in ("done", "present"))
        return {
            "total": len(self.tracks),
            "done": done,
            "failed": sum(1 for t in self.tracks if t.state == "failed"),
            "pending": sum(
                1 for t in self.tracks if t.state in ("queued", "downloading")
            ),
        }

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "url": self.url,
            "kind": self.kind,
            "title": self.title,
            "dir": str(self.dir),
            "status": self.status,
            "error": self.error,
            "created": self.created,
            "counts": self.counts(),
            "tracks": [t.to_dict() for t in self.tracks],
        }


JOBS: Dict[str, Job] = {}
JOBS_LOCK = threading.RLock()
JOB_QUEUE: "queue.Queue[str]" = queue.Queue()


def _safe_component(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("._-")
    return cleaned[:80] or "playlist"


def _target_for(ident: str, title: str) -> Path:
    name = _safe_component(ident or title)
    return ROOT / datetime.now().strftime("%Y-%m-%d") / name


def _download_job(job: Job) -> None:
    job.status = "running"
    log("job %s starting: %s (%d tracks)", job.id, job.title, len(job.tracks))
    job.dir.mkdir(parents=True, exist_ok=True)
    SPOTDL.downloader.settings["output"] = str(
        job.dir / (FILENAME + ".{output-ext}")
    )

    for track, song in zip(job.tracks, job.songs):
        with JOBS_LOCK:
            if track.state in ("done", "present"):
                continue
            track.state = "downloading"
        ERRORS.drain()
        try:
            _, path = SPOTDL.download(song)
        except Exception as exc:  # spotdl usually swallows these itself
            path = None
            track.error = f"{type(exc).__name__}: {exc}"
        if path is None:
            messages = ERRORS.drain()
            track.state = "failed"
            track.error = track.error or (
                messages[-1] if messages else "no audio produced"
            )
            log("job %s failed track %s: %s", job.id, track.song_id, track.error)
            continue

        path = Path(path)
        if not path.is_file():
            track.state = "failed"
            track.error = "spotdl reported success but produced no file"
            continue

        track.state = "done"
        track.file = path.name
        try:
            track.size = path.stat().st_size
        except OSError:
            track.size = None
        MANIFEST.put(
            track.song_id,
            {
                "path": str(path),
                "size": track.size,
                "title": track.title,
                "artists": track.artists,
                "job": job.id,
                "playlist": job.title,
            },
        )
        log("job %s done track: %s", job.id, track.file)

    counts = job.counts()
    job.status = "done" if counts["failed"] < counts["total"] else "failed"
    log("job %s finished: %s", job.id, counts)


def _worker() -> None:
    # spotdl's downloader drives asyncio. Give this thread its own loop, since
    # uvicorn's loop belongs to another thread.
    worker_loop = asyncio.new_event_loop()
    asyncio.set_event_loop(worker_loop)
    SPOTDL.downloader.loop = worker_loop

    while True:
        job_id = JOB_QUEUE.get()
        try:
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None:
                continue
            _download_job(job)
        except Exception as exc:  # keep the worker alive whatever happens
            log("job %s crashed: %s", job_id, exc)
            with JOBS_LOCK:
                job = JOBS.get(job_id)
                if job is not None:
                    job.status = "failed"
                    job.error = str(exc)
        finally:
            JOB_QUEUE.task_done()


threading.Thread(target=_worker, name="grabber-worker", daemon=True).start()

# --------------------------------------------------------------------------- #
# API
# --------------------------------------------------------------------------- #

app = FastAPI(title="Spotify Grabber", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class UrlRequest(BaseModel):
    url: str


class JobRequest(BaseModel):
    url: str
    track_ids: Optional[List[str]] = None


def _resolve_or_http(address: str) -> Resolved:
    if not address.strip():
        raise HTTPException(status_code=422, detail="Paste a Spotify link first.")
    try:
        return resolve(address.strip())
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Spotify lookup failed: {exc}") from exc


@app.get("/health")
def health() -> Dict[str, Any]:
    deno = None
    try:
        from spotdl.utils.deno import get_deno_path

        path = get_deno_path()
        deno = str(path) if path else None
    except Exception:
        pass
    return {
        "status": "ok",
        "version": app.version,
        "providers": PROVIDERS,
        "format": FORMAT,
        "bitrate": BITRATE,
        "root": str(ROOT),
        "deno": deno,
        "downloaded": MANIFEST.count(),
    }


@app.post("/resolve")
def resolve_endpoint(req: UrlRequest) -> Dict[str, Any]:
    resolved = _resolve_or_http(req.url)
    return {
        "url": resolved.url,
        "kind": resolved.kind,
        "id": resolved.ident,
        "title": resolved.title,
        "cover_url": resolved.cover_url,
        "total": len(resolved.tracks),
        "tracks": [t.to_dict() for t in resolved.tracks],
    }


@app.post("/jobs")
def create_job(req: JobRequest) -> Dict[str, Any]:
    resolved = _resolve_or_http(req.url)

    pairs = list(zip(resolved.songs, resolved.tracks))
    if req.track_ids:
        wanted = set(req.track_ids)
        pairs = [(s, t) for s, t in pairs if t.song_id in wanted]
        if not pairs:
            raise HTTPException(
                status_code=422, detail="None of those tracks are in this link."
            )

    job = Job(
        id=uuid.uuid4().hex[:12],
        url=resolved.url,
        kind=resolved.kind,
        title=resolved.title,
        dir=_target_for(resolved.ident, resolved.title),
        tracks=[t for _, t in pairs],
        songs=[s for s, _ in pairs],
    )
    with JOBS_LOCK:
        JOBS[job.id] = job
    JOB_QUEUE.put(job.id)
    log("job %s queued: %s (%d tracks)", job.id, job.title, len(job.tracks))
    return job.to_dict()


@app.get("/jobs/{job_id}")
def get_job(job_id: str) -> Dict[str, Any]:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown job.")
    return job.to_dict()


@app.get("/jobs/{job_id}/files")
def list_files(job_id: str) -> Dict[str, Any]:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Unknown job.")
        return {
            "id": job.id,
            "title": job.title,
            "files": [
                {
                    "id": t.song_id,
                    "name": t.file,
                    "size": t.size,
                    "url": f"/jobs/{job.id}/files/{t.song_id}",
                }
                for t in job.tracks
                if t.state in ("done", "present") and t.file
            ],
        }


@app.get("/jobs/{job_id}/files/{song_id}")
def download_file(job_id: str, song_id: str) -> FileResponse:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        track = (
            next((t for t in job.tracks if t.song_id == song_id), None)
            if job
            else None
        )
    if track is None or not track.file:
        raise HTTPException(status_code=404, detail="That track is not downloaded.")
    path = job.dir / track.file
    if not path.is_file():
        # Job may be from an earlier run; fall back to the manifest.
        entry = MANIFEST.get(song_id)
        if entry:
            path = Path(entry["path"])
    if not path.is_file():
        raise HTTPException(status_code=410, detail="File is gone from the server.")
    media = "audio/mp4" if path.suffix.lower() in {".m4a", ".mp4"} else "audio/mpeg"
    return FileResponse(path, media_type=media, filename=path.name)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("GRABBER_HOST", "0.0.0.0"),
        port=int(os.environ.get("GRABBER_PORT", "8787")),
    )
