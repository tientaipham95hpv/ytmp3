import json
from pathlib import Path

from fastapi.testclient import TestClient

from app import main

client = TestClient(main.app)


def test_health():
    assert client.get("/health").json() == {"status": "ok"}


def test_rejects_non_youtube_url():
    response = client.post("/api/media/info", json={"url": "https://example.com/watch?v=x"})
    assert response.status_code == 422


def test_info_maps_metadata(monkeypatch):
    payload = {"id": "abc", "title": "Song", "channel": "Artist", "duration": 61, "thumbnail": "https://img/x.jpg"}
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main, "run_command", lambda _: type("Result", (), {"returncode": 0, "stdout": json.dumps(payload), "stderr": ""})())
    response = client.post("/api/media/info", json={"url": "https://youtu.be/abc"})
    assert response.status_code == 200
    assert response.json()["title"] == "Song"
    assert response.json()["duration"] == 61


def test_audio_quality_validation():
    response = client.post("/api/media/download", json={"url": "https://youtu.be/abc", "media_type": "audio", "quality": "720"})
    assert response.status_code == 422


def test_audio_and_video_commands():
    audio = main.DownloadRequest(url="https://youtu.be/abc", media_type="audio", quality="320")
    audio_command = main.build_download_command(audio, "/tmp/out.%(ext)s")
    assert audio_command[-1] == "https://youtu.be/abc"
    assert ["--audio-format", "mp3"] == audio_command[audio_command.index("--audio-format"):audio_command.index("--audio-format") + 2]
    video = main.DownloadRequest(url="https://youtu.be/abc", media_type="video", quality="720")
    video_command = main.build_download_command(video, "/tmp/out.%(ext)s")
    assert "height<=720" in video_command[video_command.index("-f") + 1]
    assert "--recode-video" in video_command
    assert "--sleep-requests" in video_command
    assert "--retries" in video_command
    assert "--fragment-retries" in video_command
    assert video_command[video_command.index("--remote-components") + 1] == "ejs:github"
    assert "--sleep-interval" in video_command
    assert "youtubepot-bgutilhttp:base_url=" in video_command[video_command.index("--extractor-args") + 1]


def test_download_error_is_friendly(monkeypatch):
    request = main.DownloadRequest(url="https://youtu.be/abc", media_type="audio", quality="original")
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main.subprocess, "Popen", lambda *args, **kwargs: (_ for _ in ()).throw(
        RuntimeError("ERROR: Sign in to confirm you're not a bot")
    ))
    main.jobs["friendly"] = {}
    main.execute_download("friendly", request)
    assert "YouTube đang chặn" in main.jobs["friendly"]["error"]


def test_cookie_file_is_used_when_present(tmp_path: Path, monkeypatch):
    cookie_file = tmp_path / "youtube-cookies.txt"
    cookie_file.write_text("# Netscape HTTP Cookie File\n")
    monkeypatch.setattr(main, "YOUTUBE_COOKIES_FILE", cookie_file)
    args = main.yt_dlp_common_args()
    assert args[args.index("--cookies") + 1] == str(cookie_file)


def test_missing_cookie_file_is_optional(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "YOUTUBE_COOKIES_FILE", tmp_path / "missing.txt")
    assert "--cookies" not in main.yt_dlp_common_args()


def test_progress_metrics_parses_realtime_values():
    metrics = main.progress_metrics("download: 42.5%|1048576|2097152|NA|524288")
    assert metrics == {
        "progress": 42.5,
        "downloaded_bytes": 1048576,
        "total_bytes": 2097152,
        "speed_bytes_per_second": 524288.0,
    }


def test_progress_metrics_uses_estimated_total():
    metrics = main.progress_metrics(" 5.0%|100|NA|2000|NA")
    assert metrics["total_bytes"] == 2000


def test_file_endpoint_is_not_guessable(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "DOWNLOAD_DIR", tmp_path)
    assert client.get("/api/files/missing").status_code == 404


def test_api_token_protects_api_routes(tmp_path: Path, monkeypatch):
    token_file = tmp_path / "token"
    token_file.write_text("secret-test-token")
    monkeypatch.setattr(main, "API_ACCESS_TOKEN_FILE", token_file)
    assert client.post("/api/media/info", json={"url": "https://youtu.be/abc"}).status_code == 401
    response = client.post(
        "/api/media/info",
        json={"url": "https://example.com/x"},
        headers={"Authorization": "Bearer secret-test-token"},
    )
    assert response.status_code == 422


def test_cookie_validation_accepts_netscape_youtube_cookie():
    main.validate_cookie_text("# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tvalue\n")


def test_cookie_validation_rejects_wrong_domain():
    try:
        main.validate_cookie_text("# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tSID\tvalue\n")
    except main.HTTPException as exc:
        assert exc.status_code == 422
    else:
        raise AssertionError("Expected cookie validation to fail")
