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


def test_file_endpoint_is_not_guessable(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(main, "DOWNLOAD_DIR", tmp_path)
    assert client.get("/api/files/missing").status_code == 404
