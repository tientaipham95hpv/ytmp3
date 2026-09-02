from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Literal
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException
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
MIN_FREE_BYTES = int(os.getenv("MIN_FREE_BYTES", str(512 * 1024 * 1024)))
logger = logging.getLogger("offlinetube.downloads")


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


app = FastAPI(title="OfflineTube API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in os.getenv("CORS_ORIGINS", "*").split(",")],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


def configured_api_token() -> str | None:
    if not API_ACCESS_TOKEN_FILE.is_file():
        return None
    value = API_ACCESS_TOKEN_FILE.read_text().strip()
    return value or None


@app.middleware("http")
async def protect_api(request, call_next):
    token = configured_api_token()
    if token and request.url.path.startswith("/api/"):
        supplied = request.headers.get("authorization", "")
        if not secrets.compare_digest(supplied, f"Bearer {token}"):
            return JSONResponse(status_code=401, content={"detail": "API access token is missing or invalid."})
    return await call_next(request)


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Required binary '{name}' is not installed")


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=False, timeout=120)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


def _friendly_error(stderr: str) -> tuple[int, str]:
    text = stderr.lower()
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
    return {
        "id": str(data.get("id", "")),
        "title": data.get("title") or "Untitled",
        "thumbnail": thumbnail,
        "channel": data.get("channel") or data.get("uploader") or "Unknown channel",
        "duration": int(data.get("duration") or 0),
        "webpage_url": data.get("webpage_url") or request.url,
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


def execute_download(job_id: str, request: DownloadRequest) -> None:
    try:
        logger.info("job=%s starting type=%s quality=%s", job_id, request.media_type, request.quality)
        require_binary("yt-dlp")
        require_binary("ffmpeg")
        output_template = str(DOWNLOAD_DIR / f"{job_id}.%(ext)s")
        command = build_download_command(request, output_template)
        update_job(job_id, status="downloading", progress=0.0)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
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
        code = process.wait()
        with state_lock:
            was_cancelled = job_id in cancelled_jobs
        if was_cancelled:
            update_job(job_id, status="cancelled", error=None, speed_bytes_per_second=0.0)
            return
        if code != 0:
            raise RuntimeError("\n".join(tail)[-1500:] or "yt-dlp download failed")
        candidates = [p for p in DOWNLOAD_DIR.glob(f"{job_id}.*") if p.is_file() and p.suffix not in {".part", ".ytdl"}]
        if not candidates:
            raise RuntimeError("Download completed but no output file was produced")
        result_path = max(candidates, key=lambda p: p.stat().st_mtime)
        file_id = uuid.uuid4().hex
        with state_lock:
            files[file_id] = result_path
        update_job(job_id, status="completed", progress=100.0, file_id=file_id, filename=result_path.name)
        logger.info("job=%s completed file=%s", job_id, result_path.name)
    except Exception as exc:
        _, detail = _friendly_error(str(exc))
        update_job(job_id, status="failed", error=detail, progress=0.0)
        cleanup_job_files(job_id)
        logger.error("job=%s failed error=%s", job_id, detail)
    finally:
        with state_lock:
            active_processes.pop(job_id, None)
            cancelled_jobs.discard(job_id)


@app.post("/api/media/download", status_code=202)
async def media_download(request: DownloadRequest) -> dict[str, str]:
    free_bytes = shutil.disk_usage(DOWNLOAD_DIR).free
    if free_bytes < MIN_FREE_BYTES:
        raise HTTPException(status_code=507, detail="Máy chủ không đủ dung lượng trống để bắt đầu tải.")
    job_id = uuid.uuid4().hex
    now = utc_now()
    with state_lock:
        jobs[job_id] = {
            "id": job_id, "status": "queued", "progress": 0.0,
            "media_type": request.media_type, "quality": request.quality,
            "file_id": None, "filename": None, "error": None,
            "downloaded_bytes": 0, "total_bytes": None, "speed_bytes_per_second": None,
            "created_at": now, "updated_at": now,
        }
    task = asyncio.create_task(asyncio.to_thread(execute_download, job_id, request))
    active_tasks.add(task)
    task.add_done_callback(active_tasks.discard)
    return {"id": job_id, "status": "queued"}


@app.post("/api/jobs/{job_id}/cancel")
async def cancel_job(job_id: str) -> dict[str, str]:
    with state_lock:
        job = jobs.get(job_id)
        if job is None:
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
async def job_status(job_id: str) -> dict:
    with state_lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        return dict(job)


@app.get("/api/files/{file_id}")
async def get_file(file_id: str) -> FileResponse:
    with state_lock:
        path = files.get(file_id)
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
async def update_youtube_cookies(request: CookieUpdateRequest) -> dict[str, str]:
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
