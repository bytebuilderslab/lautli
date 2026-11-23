import json
import shutil
import subprocess
import threading
import urllib.error
import urllib.request
from contextlib import contextmanager
from http.server import ThreadingHTTPServer

import numpy as np
import pytest
import soundfile

from worker.lautli_worker.dev_server import (
    MAX_CLIP_SECONDS,
    SAMPLE_RATE_HZ,
    ClipError,
    ModelSlot,
    decode_with_afconvert,
    make_handler,
)


@contextmanager
def running(recognize=None, decode=lambda _: np.zeros(SAMPLE_RATE_HZ, dtype=np.float32)):
    slot = ModelSlot()
    slot.recognize = recognize
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(slot, decode, "secret"))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


def call(url, body=None, content_type="audio/mp4", token="secret"):
    request = urllib.request.Request(url, data=body, method="POST" if body is not None else "GET")
    if body is not None:
        request.add_header("Content-Type", content_type)
        request.add_header("X-Request-ID", "test")
        if token is not None:
            request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def test_transcription_joins_segments_into_the_envelope():
    segments = [{"text": " Hallo Sarah, "}, {"text": ""}, {"text": "ich komme später."}]
    with running(recognize=lambda _: segments) as base:
        status, body = call(f"{base}/api/v1/transcriptions", b"clip")
    assert status == 200
    assert body["data"] == {"text": "Hallo Sarah, ich komme später."}
    assert body["error"] is None
    assert "timestamp" in body["meta"]


def test_ready_reports_loading_until_the_model_is_there():
    with running() as base:
        assert call(f"{base}/health")[0] == 200
        status, body = call(f"{base}/ready")
        assert (status, body["error"]["code"]) == (503, "model_loading")
        status, body = call(f"{base}/api/v1/transcriptions", b"clip")
        assert (status, body["error"]["code"]) == (503, "model_loading")


def test_transcription_requires_the_token():
    with running(recognize=lambda _: [{"text": "Hallo"}]) as base:
        assert call(f"{base}/api/v1/transcriptions", b"clip", token=None)[0] == 401
        status, body = call(f"{base}/api/v1/transcriptions", b"clip", token="wrong")
        assert (status, body["error"]["code"]) == (401, "unauthorized")


def test_rejects_wrong_content_type_and_empty_body():
    with running(recognize=lambda _: []) as base:
        assert call(f"{base}/api/v1/transcriptions", b"clip", "audio/wav")[0] == 415
        assert call(f"{base}/api/v1/transcriptions", b"")[0] == 413


def test_rejects_undecodable_and_overlong_audio():
    def undecodable(_):
        raise ClipError(400, "invalid_audio")

    with running(recognize=lambda _: [], decode=undecodable) as base:
        assert call(f"{base}/api/v1/transcriptions", b"clip")[1]["error"]["code"] == "invalid_audio"

    too_long = np.zeros((MAX_CLIP_SECONDS + 1) * SAMPLE_RATE_HZ, dtype=np.float32)
    with running(recognize=lambda _: [], decode=lambda _: too_long) as base:
        assert call(f"{base}/api/v1/transcriptions", b"clip")[1]["error"]["code"] == "clip_too_long"


def test_recognizer_failure_is_a_500_without_details():
    def broken(_):
        raise RuntimeError("secret transcript text")

    with running(recognize=broken) as base:
        status, body = call(f"{base}/api/v1/transcriptions", b"clip")
    assert (status, body["error"]) == (500, {"code": "transcription_failed"})


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert is macOS-only")
def test_afconvert_decodes_aac_to_16khz_mono(tmp_path):
    wav = tmp_path / "tone.wav"
    m4a = tmp_path / "tone.m4a"

    tone = np.sin(np.linspace(0, 2 * np.pi * 440, 48_000)).astype(np.float32)
    soundfile.write(wav, np.stack([tone, tone], axis=1), 48_000)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(wav), str(m4a)], check=True)

    samples = decode_with_afconvert(m4a.read_bytes())

    assert samples.ndim == 1
    assert abs(len(samples) - SAMPLE_RATE_HZ) < 2_048  # AAC priming adds a few frames
    assert np.abs(samples).max() > 0.5


@pytest.mark.skipif(shutil.which("afconvert") is None, reason="afconvert is macOS-only")
def test_afconvert_rejects_non_audio():
    with pytest.raises(ClipError):
        decode_with_afconvert(b"definitely not audio")
