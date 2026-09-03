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
import mac_actions
import sessions
from conversation import Conversation, Turn
from pending import Pending, PendingStore

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
PENDING = PendingStore(CONFIG.get("confirm", {}).get("timeout_seconds", 180))
CONVERSATION = Conversation(
    keep=CONFIG.get("history", {}).get("keep", 200),
    context_turns=CONFIG.get("history", {}).get("context_turns", 6),
)

# Actions that are read back to you and only run once you say yes.
NEEDS_CONFIRMATION = set(CONFIG.get("confirm", {}).get("require", ["claude_code"]))


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


_SHORTCUTS_CACHE: dict = {"names": [], "at": 0.0}


def _shortcut_names() -> list[str]:
    """Shortcut names change rarely and listing them costs a subprocess, so the
    result is cached for a few minutes."""
    if time.time() - _SHORTCUTS_CACHE["at"] > 300:
        try:
            _SHORTCUTS_CACHE["names"] = mac_actions.list_shortcuts()
        except Exception:
            _SHORTCUTS_CACHE["names"] = []
        _SHORTCUTS_CACHE["at"] = time.time()
    return _SHORTCUTS_CACHE["names"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"  {self.address_string()} {fmt % args}", flush=True)

    def handle_one_request(self) -> None:
        # Phones drop connections all the time — moving between Wi-Fi and
        # cellular, locking the screen. Without this, each one prints a full
        # traceback and buries the useful log lines.
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            self.close_connection = True

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
            return
        if self.path.startswith("/sessions"):
            if not self._authorised(b""):
                return
            self._handle_sessions()
            return
        if self.path.startswith("/history"):
            # Signed like everything else: history is a record of your life.
            if not self._authorised(b""):
                return
            turns = [
                {
                    "id": t.id, "transcript": t.transcript, "action": t.action,
                    "params": t.params, "reply": t.reply, "ok": t.ok,
                    "error": t.error, "at": t.at,
                }
                for t in CONVERSATION.recent(100)
            ]
            self._respond(200, {"ok": True, "turns": turns})
            return
        self._respond(404, {"ok": False, "error": "Not found"})

    def _handle_sessions(self) -> None:
        """Browse Claude Code conversations stored on this Mac. Read-only."""
        path = self.path.split("?", 1)[0]
        parts = [p for p in path.split("/") if p]

        if len(parts) == 1:
            self._respond(200, {"ok": True, "sessions": sessions.list_sessions(limit=40)})
            return

        session = sessions.read_session(parts[1])
        if session is None:
            self._respond(404, {"ok": False, "error": "No such session."})
            return
        self._respond(200, {"ok": True, "session": session})

    def _authorised(self, body: bytes) -> bool:
        timestamp = self.headers.get("X-Timestamp", "")
        provided = self.headers.get("X-Signature", "")
        fresh, reason = timestamp_is_fresh(timestamp)
        if not fresh:
            self._respond(401, {"ok": False, "error": reason})
            return False
        if not hmac.compare_digest(provided, expected_signature(timestamp, body)):
            self._respond(401, {"ok": False, "error": "Bad signature. Check the shared secret."})
            return False
        return True

    def do_POST(self) -> None:
        if self.path not in ("/command", "/confirm", "/history/clear"):
            self._respond(404, {"ok": False, "error": "Not found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._respond(400, {"ok": False, "error": "Bad Content-Length"})
            return
        body = self.rfile.read(length)

        if not self._authorised(body):
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"ok": False, "error": "Body must be JSON."})
            return

        if self.path == "/history/clear":
            CONVERSATION.clear()
            print("  history cleared", flush=True)
            self._respond(200, {"ok": True, "speak": "History cleared."})
            return

        if self.path == "/confirm":
            self._handle_confirm(payload)
            return

        transcript = str(payload.get("transcript", "")).strip()
        if not transcript:
            self._respond(400, {"ok": False, "error": "Empty transcript."})
            return
        self._handle_transcript(transcript)

    def _handle_transcript(self, transcript: str) -> None:
        print(f'\n> heard: "{transcript}"', flush=True)
        started = time.monotonic()

        try:
            command = self._plan(transcript)
        except claude_client.ClaudeError as exc:
            print(f"  claude error: {exc}", flush=True)
            self._respond(502, {"ok": False, "error": str(exc), "speak": str(exc)})
            return

        action = command["action"]
        params = command.get("params") or {}
        print(f"  action: {action} {params}", flush=True)

        if action in NEEDS_CONFIRMATION:
            self._offer(action, params, command.get("speak") or "", transcript)
            return

        self._execute(action, params, command.get("speak") or "", started, transcript)

    def _handle_confirm(self, payload: dict) -> None:
        token = str(payload.get("pending_id", ""))
        pending = PENDING.take(token)
        if pending is None:
            message = "That confirmation expired. Say the command again."
            self._respond(200, {"ok": False, "error": message, "speak": message})
            return

        decision = str(payload.get("decision", "")).strip().lower()

        if decision == "no":
            print("  cancelled", flush=True)
            self._respond(200, {"ok": True, "action": "cancelled", "speak": "Cancelled."})
            return

        if decision == "edit":
            # Re-plan from the original request plus the correction, then ask again.
            amendment = str(payload.get("transcript", "")).strip()
            if not amendment:
                self._respond(400, {"ok": False, "error": "Edit needs a transcript."})
                return
            combined = f"{pending.transcript}\n\nCorrection from the user: {amendment}"
            print(f'  edit: "{amendment}"', flush=True)
            try:
                command = self._plan(combined)
            except claude_client.ClaudeError as exc:
                self._respond(502, {"ok": False, "error": str(exc), "speak": str(exc)})
                return
            self._offer(
                command["action"], command.get("params") or {},
                command.get("speak") or "", combined,
            )
            return

        if decision != "yes":
            self._respond(400, {"ok": False, "error": "decision must be yes, no or edit."})
            return

        print("  confirmed", flush=True)
        self._execute(pending.action, pending.params, pending.speak,
                      time.monotonic(), pending.transcript)

    # MARK: helpers

    def _plan(self, transcript: str) -> dict:
        claude_config = claude_client.ClaudeConfig(
            binary=CONFIG["claude"]["binary"],
            model=CONFIG["claude"].get("model", "sonnet"),
            timeout_seconds=CONFIG["claude"].get("timeout_seconds", 60),
        )
        return claude_client.ask(
            transcript,
            list(CONFIG.get("actions", {}).get("open_app", {})),
            list(CONFIG.get("actions", {}).get("claude_code", {}).get("projects", {})),
            claude_config,
            context=CONVERSATION.context(),
            shortcuts=_shortcut_names(),
        )

    def _offer(self, action: str, params: dict, speak: str, transcript: str) -> None:
        """Read the action back and wait for a yes. Nothing has run yet."""
        try:
            description = actions.describe(action, params, CONFIG)
        except actions.ActionError as exc:
            print(f"  cannot plan: {exc}", flush=True)
            self._respond(200, {"ok": False, "error": str(exc), "speak": str(exc)})
            return

        token = PENDING.put(Pending(action, params, speak, transcript))
        print(f'  awaiting confirmation: "{description}"', flush=True)
        self._respond(200, {
            "ok": True,
            "needs_confirmation": True,
            "pending_id": token,
            "action": action,
            "speak": description,
        })

    def _execute(self, action: str, params: dict, speak: str, started: float,
                 transcript: str = "") -> None:
        try:
            spoken = actions.run(action, params, speak, CONFIG)
        except actions.ActionError as exc:
            print(f"  action error: {exc}", flush=True)
            CONVERSATION.add(Turn(transcript, action, params, "", False, str(exc)))
            self._respond(200, {"ok": False, "error": str(exc), "speak": str(exc)})
            return

        elapsed = time.monotonic() - started
        print(f'  said: "{spoken}"  ({elapsed:.1f}s)', flush=True)
        CONVERSATION.add(Turn(transcript, action, params, spoken, True, ""))
        self._respond(200, {"ok": True, "action": action, "speak": spoken})


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
