# OfflineTube

Personal iOS 17+ offline YouTube media client. The SwiftUI app never runs `yt-dlp`; it asks the FastAPI backend for metadata/download jobs, saves the finished file inside the app sandbox, and plays it with AVPlayer.

> Only download content you own or are authorized to store. You are responsible for YouTube terms and local law.

## Repository

- `OfflineTube/` — SwiftUI + SwiftData + AVPlayer, MVVM, shared Xcode scheme.
- `backend/` — FastAPI + yt-dlp + FFmpeg, background jobs and file delivery.
- `.github/workflows/build-ios.yml` — Release `iphoneos` build and unsigned IPA artifact.

## Run backend

```bash
docker compose up --build
# API: http://localhost:8000, docs: http://localhost:8000/docs
```

Or use the Python setup in `backend/README.md`. For a real iPhone, expose the API via HTTPS (recommended) or a reachable LAN IP, then set that URL from the gear button in OfflineTube.

## iOS

Open `OfflineTube/OfflineTube.xcodeproj` in Xcode 16+, select the `OfflineTube` scheme, and run on iOS 17+. Background audio mode and lock-screen remote controls are configured. Downloaded files live under Application Support and the SwiftData library tracks metadata/playback position.

## Unsigned IPA

Run **Build unsigned iOS IPA** manually in GitHub Actions or push a tag matching `v*`. It builds Release for `iphoneos` with signing disabled, creates `Payload/OfflineTube.app`, zips `OfflineTube-unsigned.ipa`, and uploads it as an artifact. An unsigned IPA still needs an external signing/sideloading method before installation on a physical iPhone; no Apple certificate is used by this workflow.

## API

- `POST /api/media/info` — `{ "url": "https://youtu.be/..." }`
- `POST /api/media/download` — `{ "url": "...", "media_type": "audio|video", "quality": "..." }`
- `GET /api/jobs/{id}` — poll `queued/downloading/completed/failed` and progress
- `GET /api/files/{id}` — download completed output
