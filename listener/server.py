#!/usr/bin/env python3
"""Voice bridge listener.

Listens on your local network for signed requests from the iPhone app, asks
Claude what the spoken words mean, runs the matching action on this Mac, and
returns a sentence for the phone to speak back through the glasses.

Run it with:  ./run.sh
"""

from __future__ import annotations

import hashlib
import hmac
import json
import socket
import sys
import time
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import actions
import claude_client

CONFIG_PATH = Path(__file__).resolve().parent / "config.toml"
MAX_BODY_BYTES = 64 * 1024


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(
            f"No config file at {CONFIG_PATH}\n"
            "Copy config.example.toml to config.toml and set your shared secret."
        )
    with CONFIG_PATH.open("rb") as handle:
        config = tomllib.load(handle)

    secret = config.get("auth", {}).get("shared_secret", "")
    if not secret or secret == "CHANGE-ME":
        sys.exit(
            "Set a real shared_secret in config.toml. Generate one with:\n"
            '  python3 -c "import secrets; print(secrets.token_hex(32))"'
        )
    return config


CONFIG = load_config()


def lan_ip() -> str:
    """Best guess at this Mac's address on the local network."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.168.1.1", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def timestamp_is_fresh(timestamp: str) -> tuple[bool, str]:
    auth = CONFIG["auth"]
    try:
        sent_at = int(timestamp)
    except (TypeError, ValueError):
        return False, "Missing or malformed X-Timestamp header."

    skew = abs(time.time() - sent_at)
    if skew > auth.get("max_skew_seconds", 60):
        return False, f"Request is {int(skew)}s out of date. Check the clock on both devices."
    return True, ""


def expected_signature(timestamp: str, body: bytes) -> str:
    secret = CONFIG["auth"]["shared_secret"].encode()
    payload = timestamp.encode() + b"." + body
    return hmac.new(secret, payload, hashlib.sha256).hexdigest()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"  {self.address_string()} {fmt % args}", flush=True)

    def _respond(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._respond(200, {"ok": True, "service": "voice-bridge-listener"})
        else:
            self._respond(404, {"ok": False, "error": "Not found"})

    def do_POST(self) -> None:
        if self.path != "/command":
            self._respond(404, {"ok": False, "error": "Not found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._respond(400, {"ok": False, "error": "Bad Content-Length"})
            return
        body = self.rfile.read(length)

        timestamp = self.headers.get("X-Timestamp", "")
        provided = self.headers.get("X-Signature", "")

        fresh, reason = timestamp_is_fresh(timestamp)
        if not fresh:
            self._respond(401, {"ok": False, "error": reason})
            return
        if not hmac.compare_digest(provided, expected_signature(timestamp, body)):
            self._respond(401, {"ok": False, "error": "Bad signature. Check the shared secret."})
            return

        try:
            transcript = str(json.loads(body).get("transcript", "")).strip()
        except (json.JSONDecodeError, AttributeError):
            self._respond(400, {"ok": False, "error": "Body must be JSON with a transcript field."})
            return

        if not transcript:
            self._respond(400, {"ok": False, "error": "Empty transcript."})
            return

        self._handle_transcript(transcript)

    def _handle_transcript(self, transcript: str) -> None:
        allowed_apps = CONFIG.get("actions", {}).get("open_app", {})
        claude_config = claude_client.ClaudeConfig(
            binary=CONFIG["claude"]["binary"],
            model=CONFIG["claude"].get("model", "sonnet"),
            timeout_seconds=CONFIG["claude"].get("timeout_seconds", 60),
        )

        print(f'\n> heard: "{transcript}"', flush=True)
        started = time.monotonic()

        try:
            command = claude_client.ask(transcript, list(allowed_apps), claude_config)
        except claude_client.ClaudeError as exc:
            print(f"  claude error: {exc}", flush=True)
            self._respond(502, {"ok": False, "error": str(exc), "speak": str(exc)})
            return

        print(f"  action: {command['action']} {command.get('params')}", flush=True)

        try:
            spoken = actions.run(
                command["action"],
                command.get("params") or {},
                command.get("speak") or "",
                allowed_apps,
            )
        except actions.ActionError as exc:
            print(f"  action error: {exc}", flush=True)
            self._respond(200, {"ok": False, "error": str(exc), "speak": str(exc)})
            return

        elapsed = time.monotonic() - started
        print(f'  said: "{spoken}"  ({elapsed:.1f}s)', flush=True)
        self._respond(200, {"ok": True, "action": command["action"], "speak": spoken})


def main() -> None:
    host = CONFIG["server"].get("host", "0.0.0.0")
    port = CONFIG["server"].get("port", 8765)
    try:
        server = ThreadingHTTPServer((host, port), Handler)
    except OSError as exc:
        sys.exit(f"Could not listen on {host}:{port} ({exc.strerror}).\nIs the listener already running in another window?")

    print("Voice bridge listener")
    print(f"  listening on   {host}:{port}")
    print(f"  phone should use  http://{lan_ip()}:{port}")
    print(f"  claude cli     {CONFIG['claude']['binary']} (model: {CONFIG['claude'].get('model')})")
    print("  press Ctrl+C to stop\n", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.server_close()


if __name__ == "__main__":
    main()
