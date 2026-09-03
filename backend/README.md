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

Production deployments should put the API behind HTTPS, set `CORS_ORIGINS`, persist `/data`, and limit request rates. Runtime limits are configurable:

- `MAX_CONCURRENT_DOWNLOADS` (default `2`)
- `MAX_DOWNLOAD_SECONDS` (default `7200`)
- `MAX_DURATION_SECONDS` (default `14400`; `0` disables)
- `MAX_FILE_BYTES` (default `8589934592`; `0` disables)
- `TEMP_RETENTION_SECONDS` (default `86400`)
- `MAX_PLAYLIST_ITEMS` (default `200`, hard maximum `500`)
- `MIN_FREE_BYTES` (default `536870912`)
- `DEVICE_DAILY_JOB_LIMIT` (default `25`)
- `DEVICE_REQUESTS_PER_MINUTE` (default `120`)
- `DEVICE_MAX_ACTIVE_JOBS` (default `2`)
- `REGISTRATIONS_PER_IP_HOUR` (default `5`)

`GET /health` exposes queue and disk health. Authenticated `GET /api/jobs` lists current jobs and queue counts. Finished jobs and files are removed automatically after the configured retention period.

The iOS app registers each installation through `POST /api/auth/register`, stores its device token in Keychain, and renews it automatically after a `401`. Device tokens are stored as SHA-256 hashes in the persistent `/data/devices.sqlite3` database. Jobs and result files are isolated by device.

The token provisioned with `make provision-api-token` is the administrator token. It is required for operations such as replacing the YouTube cookie and must not be distributed to public users. Legacy app versions remain compatible during migration, but new app versions use device tokens for normal downloads.
