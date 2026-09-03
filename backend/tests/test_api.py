import json
import os
import sqlite3
import time
from pathlib import Path

from fastapi.testclient import TestClient
import pytest

from app import main

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def authorized_device(tmp_path: Path, monkeypatch):
    database = tmp_path / "devices.sqlite3"
    monkeypatch.setattr(main, "DEVICE_DB_FILE", database)
    main.initialize_device_db()
    token = "test-device-token"
    now = main.utc_now()
    with sqlite3.connect(database) as connection:
        connection.execute(
            "INSERT INTO devices VALUES (?, ?, ?, ?, ?, ?, 0, 0)",
            ("device-test-id-00000000000000000000", main._token_hash(token), now, now, "test", "2000-01-01"),
        )
    client.headers["Authorization"] = f"Bearer {token}"
    main.request_windows.clear()
    main.registration_windows.clear()
    yield
    client.headers.pop("Authorization", None)
    main.jobs.clear()
    main.files.clear()
    main.file_owners.clear()


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["max_concurrent_downloads"] >= 1
    assert payload["free_bytes"] >= 0


def test_job_queue_summary():
    job_id = "b" * 32
    main.jobs[job_id] = {
        "id": job_id, "owner": "device-test-id-00000000000000000000",
        "status": "queued", "created_at": main.utc_now(), "updated_at": main.utc_now()
    }
    try:
        response = client.get("/api/jobs")
        assert response.status_code == 200
        assert response.json()["queued"] >= 1
        assert response.json()["max_concurrent_downloads"] == main.MAX_CONCURRENT_DOWNLOADS
    finally:
        main.jobs.pop(job_id, None)


def test_rejects_non_youtube_url():
    response = client.post("/api/media/info", json={"url": "https://example.com/watch?v=x"})
    assert response.status_code == 422


def test_info_maps_metadata(monkeypatch):
    payload = {
        "id": "abc", "title": "Song", "channel": "Artist", "duration": 100,
        "thumbnail": "https://img/x.jpg",
        "formats": [
            {"vcodec": "none", "acodec": "mp4a", "filesize": 1_000_000},
            {"vcodec": "avc1", "acodec": "none", "height": 720, "filesize_approx": 5_000_000},
        ],
    }
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main, "run_command", lambda _: type("Result", (), {"returncode": 0, "stdout": json.dumps(payload), "stderr": ""})())
    response = client.post("/api/media/info", json={"url": "https://youtu.be/abc"})
    assert response.status_code == 200
    assert response.json()["title"] == "Song"
    assert response.json()["duration"] == 100
    assert response.json()["estimated_sizes"]["audio:128"] == 1_648_000
    assert response.json()["estimated_sizes"]["video:720"] == 6_000_000


def test_playlist_info_returns_flat_entries(monkeypatch):
    payload = {"id": "PL123", "title": "My Playlist", "channel": "Creator", "entries": [
        {"id": "one", "title": "One", "url": "https://www.youtube.com/watch?v=one", "duration": 10},
        {"id": "two", "title": "Two", "url": "two", "duration": 20},
    ]}
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main, "run_command", lambda _: type("Result", (), {
        "returncode": 0, "stdout": json.dumps(payload), "stderr": "",
    })())
    response = client.post("/api/media/playlist", json={"url": "https://youtube.com/playlist?list=PL123"})
    assert response.status_code == 200
    result = response.json()
    assert result["title"] == "My Playlist"
    assert result["total_entries"] == 2
    assert result["entries"][1]["webpage_url"] == "https://www.youtube.com/watch?v=two"


def test_playlist_info_rejects_empty_playlist(monkeypatch):
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main, "run_command", lambda _: type("Result", (), {
        "returncode": 0, "stdout": json.dumps({"id": "empty", "entries": []}), "stderr": "",
    })())
    response = client.post("/api/media/playlist", json={"url": "https://youtube.com/playlist?list=empty"})
    assert response.status_code == 422


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
    unauthorized = client.post(
        "/api/media/info", json={"url": "https://youtu.be/abc"}, headers={"Authorization": ""}
    )
    assert unauthorized.status_code == 401
    assert unauthorized.json()["error_code"] == "unauthorized"
    response = client.post(
        "/api/media/info",
        json={"url": "https://example.com/x"},
        headers={"Authorization": "Bearer secret-test-token"},
    )
    assert response.status_code == 422


def test_device_registration_and_authentication():
    response = client.post(
        "/api/auth/register",
        json={"install_id": "new-device-id-000000000000000000000", "app_version": "1.4.0"},
        headers={"Authorization": ""},
    )
    assert response.status_code == 201
    token = response.json()["access_token"]
    assert token
    jobs = client.get("/api/jobs", headers={"Authorization": f"Bearer {token}"})
    assert jobs.status_code == 200


def test_device_cannot_access_another_devices_job():
    job_id = "c" * 32
    main.jobs[job_id] = {
        "id": job_id, "owner": "another-device", "status": "queued",
        "created_at": main.utc_now(), "updated_at": main.utc_now(),
    }
    response = client.get(f"/api/jobs/{job_id}")
    assert response.status_code == 404


def test_device_cannot_use_admin_cookie_endpoint():
    response = client.post(
        "/api/admin/youtube-cookies",
        json={"cookies": "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tvalue"},
    )
    assert response.status_code == 403


def test_cookie_validation_accepts_netscape_youtube_cookie():
    main.validate_cookie_text("# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tvalue\n")


def test_cookie_validation_rejects_wrong_domain():
    try:
        main.validate_cookie_text("# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tSID\tvalue\n")
    except main.HTTPException as exc:
        assert exc.status_code == 422
    else:
        raise AssertionError("Expected cookie validation to fail")


def test_cleanup_job_files_removes_all_partial_outputs(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "DOWNLOAD_DIR", tmp_path)
    (tmp_path / "job.part").write_text("partial")
    (tmp_path / "job.mp4").write_text("partial")
    (tmp_path / "other.mp4").write_text("keep")
    main.cleanup_job_files("job")
    assert not (tmp_path / "job.part").exists()
    assert not (tmp_path / "job.mp4").exists()
    assert (tmp_path / "other.mp4").exists()


def test_download_rejects_when_server_disk_is_low(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "DOWNLOAD_DIR", tmp_path)
    monkeypatch.setattr(main, "MIN_FREE_BYTES", 100)
    monkeypatch.setattr(main.shutil, "disk_usage", lambda _: type("Usage", (), {"free": 99})())
    response = client.post("/api/media/download", json={"url": "https://youtu.be/abc", "media_type": "audio", "quality": "128"})
    assert response.status_code == 507


def test_api_errors_include_stable_code_and_message():
    response = client.get("/api/jobs/not-a-valid-job-id")
    assert response.status_code == 404
    assert response.json()["error_code"] == "not_found"
    assert response.json()["message"] == "Job not found"


def test_file_endpoint_rejects_path_traversal():
    response = client.get("/api/files/..%2F..%2Fetc%2Fpasswd")
    assert response.status_code == 404


def test_info_rejects_media_over_duration_limit(monkeypatch):
    payload = {"id": "long", "title": "Long", "duration": 101}
    monkeypatch.setattr(main, "MAX_DURATION_SECONDS", 100)
    monkeypatch.setattr(main, "require_binary", lambda _: None)
    monkeypatch.setattr(main, "run_command", lambda _: type("Result", (), {"returncode": 0, "stdout": json.dumps(payload), "stderr": ""})())
    response = client.post("/api/media/info", json={"url": "https://youtu.be/long"})
    assert response.status_code == 422
    assert response.json()["error_code"] == "invalid_request"


def test_download_command_contains_configured_limits(monkeypatch):
    monkeypatch.setattr(main, "MAX_DURATION_SECONDS", 3600)
    monkeypatch.setattr(main, "MAX_FILE_BYTES", 123456)
    request = main.DownloadRequest(url="https://youtu.be/abc", media_type="audio", quality="128")
    command = main.build_download_command(request, "/tmp/out.%(ext)s")
    assert command[command.index("--match-filter") + 1] == "duration <= 3600"
    assert command[command.index("--max-filesize") + 1] == "123456"


def test_cleanup_removes_stale_files_and_finished_jobs(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "DOWNLOAD_DIR", tmp_path)
    monkeypatch.setattr(main, "TEMP_RETENTION_SECONDS", 60)
    stale = tmp_path / "dead.part"
    stale.write_text("old")
    old = time.time() - 120
    os.utime(stale, (old, old))
    job_id = "a" * 32
    main.jobs[job_id] = {"status": "failed", "updated_at": "2000-01-01T00:00:00+00:00"}
    main.cleanup_stale_data()
    assert not stale.exists()
    assert job_id not in main.jobs
