# OfflineTube backend

Requires Python 3.11+, `yt-dlp`, and FFmpeg. The server owns extraction/transcoding; the iOS app only receives metadata, polls jobs, and downloads completed files.

Download job responses also expose `downloaded_bytes`, `total_bytes`, and `speed_bytes_per_second` when yt-dlp provides them. `POST /api/jobs/{id}/cancel` terminates an active download and removes partial files; existing endpoints remain backward compatible.

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
pytest -q
```

Production deployments should put the API behind HTTPS, set `CORS_ORIGINS`, persist `/data`, limit request rates, and periodically expire old jobs/files.
