from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timezone
from collections import defaultdict, deque
from pathlib import Path
from threading import Lock
from typing import Literal
import urllib.error
import urllib.request
from urllib.parse import urlencode, urlparse

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, field_validator, model_validator

DATA_DIR = Path(os.getenv("OFFLINETUBE_DATA_DIR", Path(__file__).resolve().parents[1] / "data"))
DOWNLOAD_DIR = DATA_DIR / "downloads"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com"}
jobs: dict[str, dict] = {}
files: dict[str, Path] = {}
active_tasks: set[asyncio.Task] = set()
active_processes: dict[str, subprocess.Popen[str]] = {}
cancelled_jobs: set[str] = set()
state_lock = Lock()
POT_PROVIDER_URL = os.getenv("POT_PROVIDER_URL", "http://pot-provider:4416")
YOUTUBE_COOKIES_FILE = Path(os.getenv("YOUTUBE_COOKIES_FILE", "/run/secrets/youtube-cookies.txt"))
API_ACCESS_TOKEN_FILE = Path(os.getenv("API_ACCESS_TOKEN_FILE", "/run/secrets/api-access-token.txt"))
DEVICE_DB_FILE = Path(os.getenv("DEVICE_DB_FILE", DATA_DIR / "devices.sqlite3"))
MIN_FREE_BYTES = int(os.getenv("MIN_FREE_BYTES", str(512 * 1024 * 1024)))
MAX_CONCURRENT_DOWNLOADS = max(1, int(os.getenv("MAX_CONCURRENT_DOWNLOADS", "2")))
MAX_DOWNLOAD_SECONDS = max(60, int(os.getenv("MAX_DOWNLOAD_SECONDS", "7200")))
MAX_DURATION_SECONDS = max(0, int(os.getenv("MAX_DURATION_SECONDS", "14400")))
MAX_FILE_BYTES = max(0, int(os.getenv("MAX_FILE_BYTES", str(8 * 1024 * 1024 * 1024))))
TEMP_RETENTION_SECONDS = max(60, int(os.getenv("TEMP_RETENTION_SECONDS", "86400")))
MAX_PLAYLIST_ITEMS = max(1, min(500, int(os.getenv("MAX_PLAYLIST_ITEMS", "200"))))
DEVICE_DAILY_JOB_LIMIT = max(1, int(os.getenv("DEVICE_DAILY_JOB_LIMIT", "25")))
DEVICE_REQUESTS_PER_MINUTE = max(10, int(os.getenv("DEVICE_REQUESTS_PER_MINUTE", "120")))
DEVICE_MAX_ACTIVE_JOBS = max(1, int(os.getenv("DEVICE_MAX_ACTIVE_JOBS", "2")))
REGISTRATIONS_PER_IP_HOUR = max(1, int(os.getenv("REGISTRATIONS_PER_IP_HOUR", "5")))
LRCLIB_BASE_URL = os.getenv("LRCLIB_BASE_URL", "https://lrclib.net").rstrip("/")
LYRICS_TIMEOUT_SECONDS = max(3, min(30, int(os.getenv("LYRICS_TIMEOUT_SECONDS", "12"))))
logger = logging.getLogger("offlinetube.downloads")
download_slots = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)
cleanup_task: asyncio.Task | None = None
file_owners: dict[str, str] = {}
request_windows: dict[str, deque[float]] = defaultdict(deque)
registration_windows: dict[str, deque[float]] = defaultdict(deque)


def yt_dlp_common_args(cookie_file: Path | None = None) -> list[str]:
    args = [
        "--js-runtimes", "deno",
        "--remote-components", "ejs:github",
        "--extractor-args", f"youtubepot-bgutilhttp:base_url={POT_PROVIDER_URL}",
        "--retries", "10",
        "--fragment-retries", "10",
        "--retry-sleep", "http:linear=1:5:3",
        "--retry-sleep", "fragment:linear=1:5:3",
        "--sleep-requests", "1",
        "--socket-timeout", "20",
    ]
    selected_cookie = cookie_file or YOUTUBE_COOKIES_FILE
    if selected_cookie.is_file() and selected_cookie.stat().st_size > 0:
        args += ["--cookies", str(selected_cookie)]
    return args


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class URLRequest(BaseModel):
    url: str = Field(min_length=10, max_length=2048)

    @field_validator("url")
    @classmethod
    def validate_youtube_url(cls, value: str) -> str:
        parsed = urlparse(value.strip())
        host = (parsed.hostname or "").lower()
        if parsed.scheme not in {"http", "https"} or host not in YOUTUBE_HOSTS:
            raise ValueError("A valid YouTube URL is required")
        return value.strip()


class DownloadRequest(URLRequest):
    media_type: Literal["audio", "video"]
    quality: Literal["original", "m4a", "128", "192", "320", "360", "480", "720", "1080", "best"]

    @model_validator(mode="after")
    def quality_is_supported(self) -> "DownloadRequest":
        allowed = {
            "audio": {"original", "m4a", "128", "192", "320"},
            "video": {"360", "480", "720", "1080", "best"},
        }
        if self.quality not in allowed[self.media_type]:
            raise ValueError(f"Unsupported {self.media_type} quality")
        return self


class CookieUpdateRequest(BaseModel):
    cookies: str = Field(min_length=20, max_length=262_144)
    test_url: str = "https://youtu.be/PjZxlhMwWZk"

    @field_validator("test_url")
    @classmethod
    def validate_test_url(cls, value: str) -> str:
        return URLRequest(url=value).url


class DeviceRegistrationRequest(BaseModel):
    install_id: str = Field(min_length=32, max_length=64, pattern=r"^[A-Za-z0-9-]+$")
    app_version: str = Field(default="unknown", min_length=1, max_length=32)


class LyricsRequest(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    artist: str = Field(min_length=1, max_length=300)
    duration: float | None = Field(default=None, ge=1, le=3600)

    @field_validator("title", "artist")
    @classmethod
    def clean_lyrics_text(cls, value: str) -> str:
        cleaned = " ".join(value.split())
        if not cleaned:
            raise ValueError("Title and artist are required")
        return cleaned


def _token_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def initialize_device_db() -> None:
    DEVICE_DB_FILE.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DEVICE_DB_FILE) as connection:
        connection.execute(
            """CREATE TABLE IF NOT EXISTS devices (
                install_id TEXT PRIMARY KEY,
                token_hash TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                app_version TEXT NOT NULL,
                quota_day TEXT NOT NULL,
                jobs_today INTEGER NOT NULL DEFAULT 0,
                revoked INTEGER NOT NULL DEFAULT 0
            )"""
        )


def find_device(token: str) -> dict | None:
    initialize_device_db()
    with sqlite3.connect(DEVICE_DB_FILE) as connection:
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            "SELECT install_id, revoked, quota_day, jobs_today FROM devices WHERE token_hash = ?",
            (_token_hash(token),),
        ).fetchone()
        if row is None or row["revoked"]:
            return None
        connection.execute("UPDATE devices SET last_seen_at = ? WHERE install_id = ?", (utc_now(), row["install_id"]))
        return dict(row)


def consume_daily_job(device_id: str) -> None:
    today = datetime.now(timezone.utc).date().isoformat()
    with sqlite3.connect(DEVICE_DB_FILE) as connection:
        row = connection.execute(
            "SELECT quota_day, jobs_today FROM devices WHERE install_id = ?", (device_id,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=401, detail="Device authorization is invalid.")
        count = int(row[1]) if row[0] == today else 0
        if count >= DEVICE_DAILY_JOB_LIMIT:
            raise HTTPException(status_code=429, detail="Daily download quota reached. Please try again tomorrow.")
        connection.execute(
            "UPDATE devices SET quota_day = ?, jobs_today = ? WHERE install_id = ?",
            (today, count + 1, device_id),
        )


def _within_rate_limit(bucket: deque[float], limit: int, seconds: int) -> bool:
    now = time.monotonic()
    while bucket and bucket[0] <= now - seconds:
        bucket.popleft()
    if len(bucket) >= limit:
        return False
    bucket.append(now)
    return True


def client_ip(request: Request) -> str:
    """Trust proxy headers only because the service is bound to loopback in compose."""
    peer = request.client.host if request.client else "unknown"
    if peer in {"127.0.0.1", "::1"}:
        forwarded = request.headers.get("x-real-ip") or request.headers.get("x-forwarded-for", "").split(",")[0]
        if forwarded.strip():
            return forwarded.strip()[:64]
    return peer


def public_job(job: dict) -> dict:
    result = dict(job)
    result.pop("owner", None)
    return result


async def cleanup_loop() -> None:
    while True:
        await asyncio.to_thread(cleanup_stale_data)
        await asyncio.sleep(min(3600, max(60, TEMP_RETENTION_SECONDS // 4)))


@asynccontextmanager
async def lifespan(_: FastAPI):
    global cleanup_task
    initialize_device_db()
    cleanup_stale_data()
    cleanup_task = asyncio.create_task(cleanup_loop())
    yield
    cleanup_task.cancel()
    with suppress(asyncio.CancelledError):
        await cleanup_task
    with state_lock:
        processes = list(active_processes.values())
    for process in processes:
        if process.poll() is None:
            process.terminate()


app = FastAPI(title="OfflineTube API", version="1.0.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in os.getenv("CORS_ORIGINS", "*").split(",")],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
    message = str(exc.detail)
    code = {
        401: "unauthorized", 403: "forbidden", 404: "not_found", 408: "timeout",
        413: "file_too_large", 422: "invalid_request", 429: "rate_limited",
        500: "internal_error", 502: "upstream_error", 503: "service_unavailable", 507: "insufficient_storage",
    }.get(exc.status_code, "request_failed")
    return JSONResponse(status_code=exc.status_code, content={"detail": message, "error_code": code, "message": message})


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    message = "; ".join(str(item.get("msg", "Invalid input")).replace("Value error, ", "") for item in exc.errors())
    return JSONResponse(status_code=422, content={"detail": message, "error_code": "invalid_request", "message": message})


def configured_api_token() -> str | None:
    if not API_ACCESS_TOKEN_FILE.is_file():
        return None
    value = API_ACCESS_TOKEN_FILE.read_text().strip()
    return value or None


@app.middleware("http")
async def protect_api(request, call_next):
    if not request.url.path.startswith("/api/") or request.url.path == "/api/auth/register":
        return await call_next(request)
    supplied = request.headers.get("authorization", "")
    bearer = supplied.removeprefix("Bearer ") if supplied.startswith("Bearer ") else ""
    admin_token = configured_api_token()
    if admin_token and bearer and secrets.compare_digest(bearer, admin_token):
        request.state.principal = "admin"
        request.state.is_admin = True
        return await call_next(request)
    device = find_device(bearer) if bearer else None
    if device is None:
        message = "Device authorization is missing or invalid."
        return JSONResponse(status_code=401, content={"detail": message, "error_code": "unauthorized", "message": message})
    principal = str(device["install_id"])
    if not _within_rate_limit(request_windows[principal], DEVICE_REQUESTS_PER_MINUTE, 60):
        message = "Too many requests. Please slow down."
        return JSONResponse(status_code=429, content={"detail": message, "error_code": "rate_limited", "message": message})
    request.state.principal = principal
    request.state.is_admin = False
    return await call_next(request)


@app.post("/api/auth/register", status_code=201)
async def register_device(payload: DeviceRegistrationRequest, request: Request) -> dict:
    source_ip = client_ip(request)
    if not _within_rate_limit(registration_windows[source_ip], REGISTRATIONS_PER_IP_HOUR, 3600):
        raise HTTPException(status_code=429, detail="Too many device registrations from this network.")
    initialize_device_db()
    now = utc_now()
    today = datetime.now(timezone.utc).date().isoformat()
    with sqlite3.connect(DEVICE_DB_FILE) as connection:
        existing = connection.execute(
            "SELECT revoked FROM devices WHERE install_id = ?", (payload.install_id,)
        ).fetchone()
        if existing is not None and existing[0]:
            raise HTTPException(status_code=403, detail="This device has been revoked.")
        token = secrets.token_urlsafe(32)
        if existing is None:
            connection.execute(
                "INSERT INTO devices VALUES (?, ?, ?, ?, ?, ?, 0, 0)",
                (payload.install_id, _token_hash(token), now, now, payload.app_version, today),
            )
        else:
            connection.execute(
                "UPDATE devices SET token_hash = ?, last_seen_at = ?, app_version = ? WHERE install_id = ?",
                (_token_hash(token), now, payload.app_version, payload.install_id),
            )
    logger.info("device=%s registered app_version=%s", payload.install_id[:8], payload.app_version)
    return {"access_token": token, "token_type": "bearer", "daily_job_limit": DEVICE_DAILY_JOB_LIMIT}


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Required binary '{name}' is not installed")


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=False, timeout=120)


def fetch_lrclib(payload: LyricsRequest) -> dict:
    query: dict[str, str] = {"track_name": payload.title, "artist_name": payload.artist}
    if payload.duration is not None:
        query["duration"] = str(round(payload.duration))
    url = f"{LRCLIB_BASE_URL}/api/get?{urlencode(query)}"
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "OfflineTube/1.0 (lyrics lookup)"},
    )
    try:
        with urllib.request.urlopen(request, timeout=LYRICS_TIMEOUT_SECONDS) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise HTTPException(status_code=404, detail="Không tìm thấy lời cho bài hát này.") from exc
        if exc.code == 429:
            raise HTTPException(status_code=429, detail="Dịch vụ lời bài hát đang giới hạn yêu cầu. Vui lòng thử lại sau.") from exc
        raise HTTPException(status_code=502, detail="Dịch vụ lời bài hát tạm thời không khả dụng.") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=503, detail="Không thể kết nối dịch vụ lời bài hát.") from exc
    if not isinstance(result, dict):
        raise HTTPException(status_code=502, detail="Dịch vụ lời bài hát trả dữ liệu không hợp lệ.")
    synced = result.get("syncedLyrics")
    plain = result.get("plainLyrics")
    if not isinstance(synced, str) or not synced.strip():
        synced = None
    if not isinstance(plain, str) or not plain.strip():
        plain = None
    if synced is None and plain is None:
        raise HTTPException(status_code=404, detail="Không tìm thấy lời cho bài hát này.")
    return {
        "syncedLyrics": synced,
        "plainLyrics": plain,
        "trackName": result.get("trackName"),
        "artistName": result.get("artistName"),
        "source": "LRCLIB",
    }


@app.get("/health")
async def health() -> dict:
    with state_lock:
        queued = sum(job.get("status") == "queued" for job in jobs.values())
        downloading = sum(job.get("status") == "downloading" for job in jobs.values())
    return {
        "status": "ok", "service": "offlinetube-backend",
        "queued": queued, "downloading": downloading,
        "max_concurrent_downloads": MAX_CONCURRENT_DOWNLOADS,
        "free_bytes": shutil.disk_usage(DOWNLOAD_DIR).free,
    }


@app.post("/api/lyrics/search")
async def search_lyrics(payload: LyricsRequest) -> dict:
    return await asyncio.to_thread(fetch_lrclib, payload)


@app.get("/api/jobs")
async def list_jobs(request: Request) -> dict:
    principal = request.state.principal
    with state_lock:
        visible = jobs.values() if request.state.is_admin else (job for job in jobs.values() if job.get("owner") == principal)
        items = sorted((public_job(job) for job in visible), key=lambda job: job["created_at"], reverse=True)
    return {
        "items": items,
        "queued": sum(item["status"] == "queued" for item in items),
        "downloading": sum(item["status"] == "downloading" for item in items),
        "max_concurrent_downloads": MAX_CONCURRENT_DOWNLOADS,
    }


def _friendly_error(stderr: str) -> tuple[int, str]:
    text = stderr.lower()
    if "download_timeout" in text:
        return 408, "Download exceeded the configured server timeout."
    if "file_size_limit" in text:
        return 413, "Media exceeds the configured maximum file size."
    if "duration_limit" in text or "longer than" in text and "seconds" in text:
        return 422, "Media exceeds the configured maximum duration."
    if "sign in to confirm you”re not a bot" in text or "not a bot" in text:
        return 403, "YouTube đang chặn (xác minh bạn không phải bot). Thử lại sau hoặc dùng video khác."
    if "private video" in text or "private" in text and "video" in text:
        return 403, "Video riêng tư. Tài khoản cookie hiện tại không có quyền truy cập."
    if "members-only" in text or "join this channel" in text:
        return 403, "Video chỉ dành cho thành viên và tài khoản hiện tại không có quyền truy cập."
    if "age-restricted" in text or "age restricted" in text:
        return 403, "Video bị giới hạn độ tuổi và không thể tải bằng phiên hiện tại."
    if "video is unavailable" in text or "video unavailable" in text or "this video doesn”t exist" in text:
        return 404, "Video không tồn tại hoặc đã bị ẩn/xóa."
    if "no title found in player responses" in text:
        return 403, "YouTube đang chặn (không lấy được thông tin video). Thử lại sau."
    return 422, stderr.strip()[-1000:] or "Unable to read media metadata"


def estimated_sizes(data: dict) -> dict[str, int]:
    """Return conservative byte estimates without changing download format selection."""
    duration = float(data.get("duration") or 0)
    formats = data.get("formats") or []

    def size(item: dict) -> int:
        return int(item.get("filesize") or item.get("filesize_approx") or 0)

    estimates: dict[str, int] = {}
    audio_formats = [item for item in formats if item.get("acodec") != "none" and item.get("vcodec") == "none"]
    original_audio = max((size(item) for item in audio_formats), default=0)
    if original_audio:
        estimates["audio:original"] = original_audio
        estimates["audio:m4a"] = original_audio
    if duration > 0:
        for bitrate in (128, 192, 320):
            estimates[f"audio:{bitrate}"] = int(duration * bitrate * 1000 / 8 * 1.03)

    video_formats = [item for item in formats if item.get("vcodec") != "none"]
    for quality in (360, 480, 720, 1080):
        candidates = [item for item in video_formats if int(item.get("height") or 0) <= quality and size(item) > 0]
        if candidates:
            chosen = max(candidates, key=lambda item: (int(item.get("height") or 0), size(item)))
            estimates[f"video:{quality}"] = size(chosen) + (0 if chosen.get("acodec") != "none" else original_audio)
    best_candidates = [item for item in video_formats if size(item) > 0]
    if best_candidates:
        chosen = max(best_candidates, key=lambda item: (int(item.get("height") or 0), size(item)))
        estimates["video:best"] = size(chosen) + (0 if chosen.get("acodec") != "none" else original_audio)
    return estimates


@app.post("/api/media/info")
async def media_info(request: URLRequest) -> dict:
    try:
        require_binary("yt-dlp")
        result = await asyncio.to_thread(
            run_command,
            ["yt-dlp", *yt_dlp_common_args(), "--dump-single-json", "--no-playlist", "--skip-download", request.url],
        )
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if result.returncode != 0:
        status, detail = _friendly_error(result.stderr)
        raise HTTPException(status_code=status, detail=detail)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=502, detail="yt-dlp returned invalid metadata") from exc
    thumbnails = data.get("thumbnails") or []
    thumbnail = data.get("thumbnail") or (thumbnails[-1].get("url") if thumbnails else None)
    duration = int(data.get("duration") or 0)
    if MAX_DURATION_SECONDS and duration > MAX_DURATION_SECONDS:
        raise HTTPException(status_code=422, detail=f"Media duration exceeds the {MAX_DURATION_SECONDS}-second limit.")
    return {
        "id": str(data.get("id", "")),
        "title": data.get("title") or "Untitled",
        "thumbnail": thumbnail,
        "channel": data.get("channel") or data.get("uploader") or "Unknown channel",
        "duration": duration,
        "webpage_url": data.get("webpage_url") or request.url,
        "estimated_sizes": estimated_sizes(data),
    }


@app.post("/api/media/playlist")
async def playlist_info(request: URLRequest) -> dict:
    """Return flat metadata; every download still uses the normal bounded job queue."""
    try:
        require_binary("yt-dlp")
        result = await asyncio.to_thread(
            run_command,
            [
                "yt-dlp", *yt_dlp_common_args(), "--flat-playlist", "--dump-single-json",
                "--playlist-end", str(MAX_PLAYLIST_ITEMS), "--skip-download", request.url,
            ],
        )
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if result.returncode != 0:
        status, detail = _friendly_error(result.stderr)
        raise HTTPException(status_code=status, detail=detail)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=502, detail="yt-dlp returned invalid playlist metadata") from exc
    raw_entries = data.get("entries") or []
    entries = []
    for item in raw_entries[:MAX_PLAYLIST_ITEMS]:
        if not item or not item.get("id"):
            continue
        duration = int(item.get("duration") or 0)
        if MAX_DURATION_SECONDS and duration > MAX_DURATION_SECONDS:
            continue
        thumbnails = item.get("thumbnails") or []
        thumbnail = item.get("thumbnail") or (thumbnails[-1].get("url") if thumbnails else None)
        video_url = item.get("webpage_url") or item.get("url")
        if not isinstance(video_url, str) or not video_url.startswith(("http://", "https://")):
            video_url = f"https://www.youtube.com/watch?v={item['id']}"
        entries.append({
            "id": str(item["id"]), "title": item.get("title") or "Untitled", "thumbnail": thumbnail,
            "channel": item.get("channel") or item.get("uploader") or "Unknown channel",
            "duration": duration, "webpage_url": video_url, "estimated_sizes": {},
        })
    if not entries:
        raise HTTPException(status_code=422, detail="The playlist has no downloadable videos.")
    return {
        "id": str(data.get("id") or "playlist"), "title": data.get("title") or "YouTube Playlist",
        "channel": data.get("channel") or data.get("uploader") or "Unknown channel",
        "thumbnail": data.get("thumbnail"), "entries": entries, "total_entries": len(entries),
        "is_truncated": len(raw_entries) > MAX_PLAYLIST_ITEMS,
    }


def update_job(job_id: str, **values: object) -> None:
    with state_lock:
        if job_id in jobs:
            jobs[job_id].update(values)
            jobs[job_id]["updated_at"] = utc_now()


def progress_from_line(line: str) -> float | None:
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)%", line)
    return min(100.0, max(0.0, float(match.group(1)))) if match else None


def number_from_progress(value: str) -> float | None:
    value = value.strip()
    if not value or value.upper() in {"NA", "N/A", "NONE"}:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def progress_metrics(line: str) -> dict[str, float | int]:
    value = line.strip()
    if value.startswith("download:"):
        value = value.removeprefix("download:")
    if "|" not in value:
        return {}
    parts = value.split("|")
    if len(parts) < 5:
        progress = progress_from_line(line)
        return {"progress": progress} if progress is not None else {}
    progress = progress_from_line(parts[0])
    downloaded = number_from_progress(parts[1])
    total = number_from_progress(parts[2]) or number_from_progress(parts[3])
    speed = number_from_progress(parts[4])
    metrics: dict[str, float | int] = {}
    if progress is not None:
        metrics["progress"] = progress
    if downloaded is not None:
        metrics["downloaded_bytes"] = int(downloaded)
    if total is not None:
        metrics["total_bytes"] = int(total)
    if speed is not None:
        metrics["speed_bytes_per_second"] = speed
    return metrics


def build_download_command(request: DownloadRequest, output_template: str) -> list[str]:
    base = [
        "yt-dlp", *yt_dlp_common_args(),
        "--sleep-interval", "5", "--max-sleep-interval", "10",
        "--no-playlist", "--newline", "--no-part", "--restrict-filenames",
        "--progress-template", "download:%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s", "-o", output_template,
    ]
    if MAX_DURATION_SECONDS:
        base += ["--match-filter", f"duration <= {MAX_DURATION_SECONDS}"]
    if MAX_FILE_BYTES:
        base += ["--max-filesize", str(MAX_FILE_BYTES)]
    if request.media_type == "audio":
        base += ["-f", "bestaudio/best"]
        if request.quality in {"original", "m4a"}:
            # Best available audio, normalized to an AVPlayer-compatible M4A container.
            base += ["-x", "--audio-format", "m4a"]
        else:
            base += ["-x", "--audio-format", "mp3", "--audio-quality", f"{request.quality}K"]
    else:
        if request.quality == "best":
            selector = "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[ext=mp4]/best"
        else:
            height = request.quality
            selector = (
                f"bestvideo[vcodec^=avc1][height<={height}]+bestaudio[acodec^=mp4a]"
                f"/best[ext=mp4][height<={height}]/best[height<={height}]"
            )
        base += ["-f", selector, "--merge-output-format", "mp4", "--recode-video", "mp4"]
    return base + [request.url]


def cleanup_job_files(job_id: str) -> None:
    for path in DOWNLOAD_DIR.glob(f"{job_id}.*"):
        if path.is_file():
            try:
                path.unlink()
            except OSError:
                logger.exception("job=%s failed to remove partial file", job_id)


def cleanup_stale_data() -> None:
    cutoff = time.time() - TEMP_RETENTION_SECONDS
    with state_lock:
        active_ids = set(active_processes)
        stale_jobs = {
            job_id for job_id, job in jobs.items()
            if job_id not in active_ids
            and job.get("status") in {"completed", "failed", "cancelled"}
            and datetime.fromisoformat(job.get("updated_at", utc_now())).timestamp() < cutoff
        }
        stale_file_ids = {file_id for file_id, path in files.items() if not path.is_file() or path.stat().st_mtime < cutoff}
        for job_id in stale_jobs:
            jobs.pop(job_id, None)
        for file_id in stale_file_ids:
            path = files.pop(file_id, None)
            file_owners.pop(file_id, None)
            if path and path.is_file():
                path.unlink(missing_ok=True)
    for path in DOWNLOAD_DIR.iterdir():
        if path.is_file() and path.stat().st_mtime < cutoff and path.stem not in active_ids:
            path.unlink(missing_ok=True)


def execute_download(job_id: str, request: DownloadRequest) -> None:
    timeout_timer: threading.Timer | None = None
    try:
        logger.info("job=%s starting type=%s quality=%s", job_id, request.media_type, request.quality)
        require_binary("yt-dlp")
        require_binary("ffmpeg")
        output_template = str(DOWNLOAD_DIR / f"{job_id}.%(ext)s")
        command = build_download_command(request, output_template)
        update_job(job_id, status="downloading", progress=0.0)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        timed_out = False
        size_exceeded = False

        def terminate_for_timeout() -> None:
            nonlocal timed_out
            if process.poll() is None:
                timed_out = True
                process.terminate()

        timeout_timer = threading.Timer(MAX_DOWNLOAD_SECONDS, terminate_for_timeout)
        timeout_timer.daemon = True
        timeout_timer.start()
        with state_lock:
            active_processes[job_id] = process
        if process.stdout is None:
            raise RuntimeError("Unable to monitor downloader output")
        tail: list[str] = []
        for line in process.stdout:
            tail.append(line.strip())
            tail = tail[-20:]
            metrics = progress_metrics(line)
            if metrics:
                update_job(job_id, **metrics)
                measured = int(metrics.get("total_bytes") or metrics.get("downloaded_bytes") or 0)
                if MAX_FILE_BYTES and measured > MAX_FILE_BYTES:
                    size_exceeded = True
                    process.terminate()
                    break
        try:
            code = process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            code = process.wait(timeout=5)
        timeout_timer.cancel()
        with state_lock:
            was_cancelled = job_id in cancelled_jobs
        if was_cancelled:
            update_job(job_id, status="cancelled", error=None, speed_bytes_per_second=0.0)
            return
        if timed_out:
            raise RuntimeError("DOWNLOAD_TIMEOUT")
        if size_exceeded:
            raise RuntimeError("FILE_SIZE_LIMIT")
        if code != 0:
            raise RuntimeError("\n".join(tail)[-1500:] or "yt-dlp download failed")
        candidates = [p for p in DOWNLOAD_DIR.glob(f"{job_id}.*") if p.is_file() and p.suffix not in {".part", ".ytdl"}]
        if not candidates:
            raise RuntimeError("Download completed but no output file was produced")
        result_path = max(candidates, key=lambda p: p.stat().st_mtime)
        if MAX_FILE_BYTES and result_path.stat().st_size > MAX_FILE_BYTES:
            raise RuntimeError("FILE_SIZE_LIMIT")
        file_id = uuid.uuid4().hex
        with state_lock:
            files[file_id] = result_path
            file_owners[file_id] = str(jobs.get(job_id, {}).get("owner", "admin"))
        update_job(job_id, status="completed", progress=100.0, file_id=file_id, filename=result_path.name)
        logger.info("job=%s completed file=%s", job_id, result_path.name)
    except Exception as exc:
        _, detail = _friendly_error(str(exc))
        update_job(job_id, status="failed", error=detail, progress=0.0)
        cleanup_job_files(job_id)
        logger.error("job=%s failed error=%s", job_id, detail)
    finally:
        if timeout_timer is not None:
            timeout_timer.cancel()
        with state_lock:
            active_processes.pop(job_id, None)
            cancelled_jobs.discard(job_id)


async def run_queued_download(job_id: str, request: DownloadRequest) -> None:
    async with download_slots:
        with state_lock:
            job = jobs.get(job_id)
            if job is None or job.get("status") == "cancelled":
                return
        await asyncio.to_thread(execute_download, job_id, request)


@app.post("/api/media/download", status_code=202)
async def media_download(request: DownloadRequest, http_request: Request) -> dict[str, str]:
    cleanup_stale_data()
    free_bytes = shutil.disk_usage(DOWNLOAD_DIR).free
    if free_bytes < MIN_FREE_BYTES:
        raise HTTPException(status_code=507, detail="Máy chủ không đủ dung lượng trống để bắt đầu tải.")
    owner = http_request.state.principal
    if not http_request.state.is_admin:
        with state_lock:
            active_for_device = sum(
                job.get("owner") == owner and job.get("status") in {"queued", "downloading"}
                for job in jobs.values()
            )
        if active_for_device >= DEVICE_MAX_ACTIVE_JOBS:
            raise HTTPException(status_code=429, detail="This device already has the maximum number of active downloads.")
        consume_daily_job(owner)
    job_id = uuid.uuid4().hex
    now = utc_now()
    with state_lock:
        jobs[job_id] = {
            "id": job_id, "status": "queued", "progress": 0.0,
            "media_type": request.media_type, "quality": request.quality,
            "file_id": None, "filename": None, "error": None,
            "downloaded_bytes": 0, "total_bytes": None, "speed_bytes_per_second": None,
            "owner": owner,
            "created_at": now, "updated_at": now,
        }
    task = asyncio.create_task(run_queued_download(job_id, request))
    active_tasks.add(task)
    task.add_done_callback(active_tasks.discard)
    return {"id": job_id, "status": "queued"}


@app.post("/api/jobs/{job_id}/cancel")
async def cancel_job(job_id: str, request: Request) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{32}", job_id):
        raise HTTPException(status_code=404, detail="Job not found")
    with state_lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        if not request.state.is_admin and job.get("owner") != request.state.principal:
            raise HTTPException(status_code=404, detail="Job not found")
        if job["status"] in {"completed", "failed", "cancelled"}:
            return {"id": job_id, "status": str(job["status"])}
        cancelled_jobs.add(job_id)
        process = active_processes.get(job_id)
        job.update(status="cancelled", error=None, speed_bytes_per_second=0.0, updated_at=utc_now())
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            await asyncio.to_thread(process.wait, 5)
        except subprocess.TimeoutExpired:
            process.kill()
    cleanup_job_files(job_id)
    logger.info("job=%s cancelled", job_id)
    return {"id": job_id, "status": "cancelled"}


@app.get("/api/jobs/{job_id}")
async def job_status(job_id: str, request: Request) -> dict:
    if not re.fullmatch(r"[0-9a-f]{32}", job_id):
        raise HTTPException(status_code=404, detail="Job not found")
    with state_lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        if not request.state.is_admin and job.get("owner") != request.state.principal:
            raise HTTPException(status_code=404, detail="Job not found")
        return public_job(job)


@app.get("/api/files/{file_id}")
async def get_file(file_id: str, request: Request) -> FileResponse:
    if not re.fullmatch(r"[0-9a-f]{32}", file_id):
        raise HTTPException(status_code=404, detail="File not found")
    with state_lock:
        path = files.get(file_id)
        owner = file_owners.get(file_id)
    if not request.state.is_admin and owner != request.state.principal:
        raise HTTPException(status_code=404, detail="File not found")
    if path is None or not path.is_file() or path.parent.resolve() != DOWNLOAD_DIR.resolve():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path, filename=path.name, media_type="application/octet-stream")


def validate_cookie_text(value: str) -> None:
    lines = value.splitlines()
    first_line = lines[0].strip() if lines else ""
    if first_line not in {"# Netscape HTTP Cookie File", "# HTTP Cookie File"}:
        raise HTTPException(status_code=422, detail="Cookie phải ở định dạng Netscape HTTP Cookie File.")
    valid_row = False
    for line in lines:
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7 and parts[0].lstrip(".").endswith("youtube.com"):
            valid_row = True
            break
    if not valid_row:
        raise HTTPException(status_code=422, detail="Không tìm thấy cookie youtube.com hợp lệ.")


@app.post("/api/admin/youtube-cookies")
async def update_youtube_cookies(request: CookieUpdateRequest, http_request: Request) -> dict[str, str]:
    if not http_request.state.is_admin:
        raise HTTPException(status_code=403, detail="Administrator authorization is required.")
    validate_cookie_text(request.cookies)
    YOUTUBE_COOKIES_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix=".youtube-cookies-", dir=YOUTUBE_COOKIES_FILE.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(request.cookies)
        temporary.chmod(0o600)
        result = await asyncio.to_thread(
            run_command,
            ["yt-dlp", *yt_dlp_common_args(temporary), "--dump-single-json", "--no-playlist", "--skip-download", request.test_url],
        )
        if result.returncode != 0:
            _, detail = _friendly_error(result.stderr)
            raise HTTPException(status_code=422, detail=f"Cookie mới không vượt qua kiểm tra YouTube: {detail}")
        os.replace(temporary, YOUTUBE_COOKIES_FILE)
        YOUTUBE_COOKIES_FILE.chmod(0o600)
        return {"status": "updated", "message": "YouTube cookie đã được cập nhật và kiểm tra thành công."}
    finally:
        temporary.unlink(missing_ok=True)
