# OfflineTube

Personal iOS 17+ offline YouTube media client. The SwiftUI app never runs `yt-dlp`; it asks the FastAPI backend for metadata/download jobs, saves the finished file inside the app sandbox, and plays it with AVPlayer.

> Only download content you own or are authorized to store. You are responsible for YouTube terms and local law.

## Repository

- `OfflineTube/` — SwiftUI + SwiftData + AVPlayer, MVVM, shared Xcode scheme.
- `backend/` — FastAPI + yt-dlp + FFmpeg, background jobs and file delivery.
- `.github/workflows/build-ios.yml` — Release `iphoneos` build and unsigned IPA artifact.

## Run backend

```bash
docker compose up -d --build
# Local origin: http://127.0.0.1:18080
# Production: https://offlinetube.cineviet.live
```

Or use the Python setup in `backend/README.md`. The production app defaults to `https://offlinetube.cineviet.live`; the backend runs in Docker behind Nginx on loopback port `18080` with a persistent volume and restarts automatically after Docker/VPS restarts.

If YouTube requests bot verification, export authenticated YouTube cookies in Netscape format to `secrets/youtube-cookies.txt`, then restart the backend. The private secrets directory is mounted only into the backend and ignored by Git; never commit or share it publicly.

To replace cookies safely in one command, use:

```bash
make update-cookies FILE=/path/to/cookies.txt
```

The command validates the Netscape file, installs it with mode `600`, restarts the backend, and performs a real YouTube metadata check. If verification fails, it restores the previous cookie automatically.

## iOS

Open `OfflineTube/OfflineTube.xcodeproj` in Xcode 16+, select the `OfflineTube` scheme, and run on iOS 17+. Background audio mode and lock-screen remote controls are configured. Downloaded files live under Application Support and the SwiftData library tracks metadata/playback position.

## Unsigned IPA

Run **Build unsigned iOS IPA** manually in GitHub Actions or push a tag matching `v*`. It builds Release for `iphoneos` with signing disabled, creates `Payload/OfflineTube.app`, zips `OfflineTube-unsigned.ipa`, and uploads it as an artifact. An unsigned IPA still needs an external signing/sideloading method before installation on a physical iPhone; no Apple certificate is used by this workflow.

## API

- `POST /api/media/info` — `{ "url": "https://youtu.be/..." }`
- `POST /api/media/download` — `{ "url": "...", "media_type": "audio|video", "quality": "..." }`
- `GET /api/jobs/{id}` — poll `queued/downloading/completed/failed` and progress
- `GET /api/files/{id}` — download completed output
