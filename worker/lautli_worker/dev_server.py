"""Development transcription server for the iPhone app (epic #33).

Serves the iPhone API contract (`POST /api/v1/transcriptions`) from a Mac using the same model and cleanup
as the desktop worker, so the phone can be tested before the hosted server exists. Not a production server:
it has no App Attest, quotas or TLS, and it decodes audio with macOS `afconvert`. Requests need the
bearer token printed at startup (or set with LAUTLI_DEV_TOKEN), since the server listens on the LAN.

    WHISPER_MODEL_PATH=.models/flix-swissgerman-full python -m worker.lautli_worker.dev_server
"""

import argparse
import hmac
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import soundfile

Recognizer = Callable[[list[float]], list[dict]]
Decoder = Callable[[bytes], np.ndarray]

CLIP_CONTENT_TYPE = "audio/mp4"
# Matches the app's 5-minute recording limit: 32 kbit/s AAC is about 1.2 MB, so 4 MB leaves headroom.
MAX_CLIP_BYTES = 4 * 1024 * 1024
MAX_CLIP_SECONDS = 5 * 60 + 5
SAMPLE_RATE_HZ = 16_000


class ClipError(Exception):
    def __init__(self, status: int, code: str) -> None:
        super().__init__(code)
        self.status = status
        self.code = code


def decode_with_afconvert(clip: bytes) -> np.ndarray:
    """AAC/M4A to 16 kHz mono float32. The temporary files are deleted before returning."""
    with tempfile.TemporaryDirectory(prefix="lautli-dev-") as directory:
        source = Path(directory, "clip.m4a")
        target = Path(directory, "clip.wav")
        source.write_bytes(clip)
        completed = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEF32@{SAMPLE_RATE_HZ}", "-c", "1", str(source), str(target)],
            capture_output=True, timeout=30, check=False,
        )
        if completed.returncode != 0:
            raise ClipError(400, "invalid_audio")
        samples, rate = soundfile.read(target, dtype="float32")
    if rate != SAMPLE_RATE_HZ or samples.ndim != 1:
        raise ClipError(400, "invalid_audio")
    return samples


def transcribe_clip(clip: bytes, decode: Decoder, recognize: Recognizer) -> str:
    samples = decode(clip)
    if len(samples) > MAX_CLIP_SECONDS * SAMPLE_RATE_HZ:
        raise ClipError(413, "clip_too_long")
    segments = recognize(samples.tolist())
    return " ".join(text for segment in segments if (text := str(segment["text"]).strip()))


def envelope(data: dict | None, error: dict | None) -> bytes:
    timestamp = datetime.now(timezone.utc).isoformat()
    return json.dumps({"data": data, "error": error, "meta": {"timestamp": timestamp}}).encode()


def log(**fields: object) -> None:
    # Durations, sizes and codes only: never audio or transcript text.
    print(json.dumps(fields), file=sys.stderr, flush=True)


class ModelSlot:
    """Holds the recognizer once it has loaded. One GPU runs one transcription at a time."""

    def __init__(self) -> None:
        self.recognize: Recognizer | None = None
        self.failed = False
        self.lock = threading.Lock()


def make_handler(slot: ModelSlot, decode: Decoder, token: str) -> type[BaseHTTPRequestHandler]:
    expected = f"Bearer {token}".encode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/health":
                self.respond(200, envelope({"status": "ok"}, None))
            elif self.path == "/ready":
                ready = slot.recognize is not None
                body = envelope({"status": "ready"}, None) if ready else envelope(None, {"code": "model_loading"})
                self.respond(200 if ready else 503, body)
            else:
                self.respond(404, envelope(None, {"code": "not_found"}))

        def do_POST(self) -> None:
            started = time.monotonic()
            request_id = self.headers.get("X-Request-ID", "")
            status, body, size = self.transcription()
            self.respond(status, body)
            log(event="transcription", request_id=request_id, status=status, bytes=size,
                duration_ms=round((time.monotonic() - started) * 1000))

        def transcription(self) -> tuple[int, bytes, int]:
            if self.path != "/api/v1/transcriptions":
                return 404, envelope(None, {"code": "not_found"}), 0
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
                return 401, envelope(None, {"code": "unauthorized"}), 0
            if slot.recognize is None:
                return 503, envelope(None, {"code": "model_loading"}), 0
            if self.headers.get("Content-Type", "").split(";")[0].strip() != CLIP_CONTENT_TYPE:
                return 415, envelope(None, {"code": "unsupported_media_type"}), 0
            try:
                size = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return 411, envelope(None, {"code": "length_required"}), 0
            if size <= 0 or size > MAX_CLIP_BYTES:
                return 413, envelope(None, {"code": "clip_too_large"}), size
            clip = self.rfile.read(size)
            try:
                with slot.lock:
                    text = transcribe_clip(clip, decode, slot.recognize)
            except ClipError as error:
                return error.status, envelope(None, {"code": error.code}), size
            except Exception as error:
                # The exception message can contain transcript text, so only its type is logged.
                log(event="transcription_failed", error=type(error).__name__)
                return 500, envelope(None, {"code": "transcription_failed"}), size
            return 200, envelope({"text": text}, None), size

        def respond(self, status: int, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            pass  # The default access log goes to stderr unstructured; `log` covers requests.

    return Handler


def load_in_background(slot: ModelSlot) -> None:
    from worker.lautli_worker.main import load_recognizer

    def load() -> None:
        try:
            slot.recognize = load_recognizer()
            log(event="model_ready")
        except Exception as error:
            slot.failed = True
            log(event="model_failed", error=type(error).__name__)

    threading.Thread(target=load, daemon=True).start()


def lan_address() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(("192.0.2.1", 9))  # TEST-NET address: picks the LAN interface, sends nothing.
            return probe.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def run() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    token = os.environ.get("LAUTLI_DEV_TOKEN") or secrets.token_urlsafe(16)
    slot = ModelSlot()
    load_in_background(slot)
    # shortcut: plain HTTP with a shared token, so the token can be sniffed on the LAN; run it only on a
    # trusted network. The hosted server replaces this with TLS plus App Attest (#33 Phase 3).
    server = ThreadingHTTPServer(("0.0.0.0", arguments.port), make_handler(slot, decode_with_afconvert, token))
    log(event="listening", url=f"http://{lan_address()}:{arguments.port}")
    # On stdout, not in the structured log: the token is a secret the user types into the app.
    print(f"Server token for the lautli app: {token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 1 if slot.failed else 0


if __name__ == "__main__":
    raise SystemExit(run())
