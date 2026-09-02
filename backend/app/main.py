from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Literal
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator, model_validator

DATA_DIR = Path(os.getenv("OFFLINETUBE_DATA_DIR", Path(__file__).resolve().parents[1] / "data"))
DOWNLOAD_DIR = DATA_DIR / "downloads"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com"}
jobs: dict[str, dict] = {}
files: dict[str, Path] = {}
active_tasks: set[asyncio.Task] = set()
state_lock = Lock()
POT_PROVIDER_URL = os.getenv("POT_PROVIDER_URL", "http://pot-provider:4416")
YOUTUBE_COOKIES_FILE = Path(os.getenv("YOUTUBE_COOKIES_FILE", "/run/secrets/youtube-cookies.txt"))


def yt_dlp_common_args() -> list[str]:
    args = [
        "--js-runtimes", "deno",
        "--remote-components", "ejs:github",
        "--extractor-args", f"youtubepot-bgutilhttp:base_url={POT_PROVIDER_URL}",
        "--retries", "10",
        "--fragment-retries", "10",
        "--retry-sleep", "http:linear=1:5:3",
        "--retry-sleep", "fragment:linear=1:5:3",
        "--sleep-requests", "1",
    ]
    if YOUTUBE_COOKIES_FILE.is_file() and YOUTUBE_COOKIES_FILE.stat().st_size > 0:
        args += ["--cookies", str(YOUTUBE_COOKIES_FILE)]
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


app = FastAPI(title="OfflineTube API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[item.strip() for item in os.getenv("CORS_ORIGINS", "*").split(",")],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


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


def build_download_command(request: DownloadRequest, output_template: str) -> list[str]:
    base = [
        "yt-dlp", *yt_dlp_common_args(),
        "--sleep-interval", "5", "--max-sleep-interval", "10",
        "--no-playlist", "--newline", "--no-part", "--restrict-filenames",
        "--progress-template", "download:%(progress._percent_str)s", "-o", output_template,
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


def execute_download(job_id: str, request: DownloadRequest) -> None:
    try:
        require_binary("yt-dlp")
        require_binary("ffmpeg")
        output_template = str(DOWNLOAD_DIR / f"{job_id}.%(ext)s")
        command = build_download_command(request, output_template)
        update_job(job_id, status="downloading", progress=0.0)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if process.stdout is None:
            raise RuntimeError("Unable to monitor downloader output")
        tail: list[str] = []
        for line in process.stdout:
            tail.append(line.strip())
            tail = tail[-20:]
            progress = progress_from_line(line)
            if progress is not None:
                update_job(job_id, progress=progress)
        code = process.wait()
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
    except Exception as exc:
        _, detail = _friendly_error(str(exc))
        update_job(job_id, status="failed", error=detail, progress=0.0)


@app.post("/api/media/download", status_code=202)
async def media_download(request: DownloadRequest) -> dict[str, str]:
    job_id = uuid.uuid4().hex
    now = utc_now()
    with state_lock:
        jobs[job_id] = {
            "id": job_id, "status": "queued", "progress": 0.0,
            "media_type": request.media_type, "quality": request.quality,
            "file_id": None, "filename": None, "error": None,
            "created_at": now, "updated_at": now,
        }
    task = asyncio.create_task(asyncio.to_thread(execute_download, job_id, request))
    active_tasks.add(task)
    task.add_done_callback(active_tasks.discard)
    return {"id": job_id, "status": "queued"}


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
