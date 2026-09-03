"""A two-minute pairing window, so the phone never has to be typed a secret.

Two processes are involved. `pair.sh` opens the window by writing
`.pairing.json` next to this file and printing the PIN; the server reads that
same file when a phone posts to `/pair`. One small file beats any IPC we could
invent, and it disappears the moment a phone pairs or the window closes.

The window is the only time `/pair` answers at all. Outside it, and after five
wrong PINs, the endpoint refuses everything — which matters, because `/pair` is
the one request that cannot be signed. The secret is the thing being handed over.
"""

from __future__ import annotations

import ipaddress
import json
import os
import secrets
import shutil
import socket
import subprocess
import time
from pathlib import Path

STATE_PATH = Path(__file__).resolve().parent / ".pairing.json"
WINDOW_SECONDS = 120
MAX_ATTEMPTS = 5

# Wrong guesses so far, keyed by the window's id. In memory only: a restarted
# server has no pending window either, so there is nothing to carry over.
_attempts: dict[str, int] = {}


class PairingError(Exception):
    """Why a pairing attempt was refused. The text is shown on the phone."""


def open_window(seconds: int = WINDOW_SECONDS) -> dict:
    """Start a window and return it. Overwrites any window already open."""
    window = {
        "pin": f"{secrets.randbelow(1_000_000):06d}",
        "expires_at": time.time() + seconds,
        "id": secrets.token_hex(8),
    }
    STATE_PATH.write_text(json.dumps(window))
    os.chmod(STATE_PATH, 0o600)
    return window


def close_window() -> None:
    STATE_PATH.unlink(missing_ok=True)


def read_window() -> dict | None:
    """The open window, or None. Expired windows are cleaned up on the way past."""
    try:
        window = json.loads(STATE_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if time.time() > window.get("expires_at", 0):
        close_window()
        return None
    return window


def is_paired(window_id: str) -> bool:
    """True once the window this id belongs to has been used up or has closed."""
    window = read_window()
    return window is None or window["id"] != window_id


def claim(pin: str, peer: str) -> None:
    """Check a PIN from `peer`. Returns quietly if it is right, raises otherwise.

    A correct PIN closes the window, so the secret is handed out exactly once.
    """
    try:
        address = ipaddress.ip_address(peer.split("%", 1)[0])
    except ValueError:
        raise PairingError("Could not read where that request came from.")
    if not (address.is_private or address.is_loopback or address.is_link_local):
        raise PairingError("Pairing only works from your own network.")

    window = read_window()
    if window is None:
        raise PairingError(
            "No pairing window is open. Run ./listener/pair.sh on your Mac."
        )

    used = _attempts.get(window["id"], 0)
    if used >= MAX_ATTEMPTS:
        close_window()
        raise PairingError("Too many wrong PINs. Run ./listener/pair.sh again.")

    if not secrets.compare_digest(pin, window["pin"]):
        _attempts[window["id"]] = used + 1
        left = MAX_ATTEMPTS - used - 1
        raise PairingError(
            f"Wrong PIN. {left} attempt{'' if left == 1 else 's'} left."
            if left
            else "Wrong PIN. Run ./listener/pair.sh again."
        )

    _attempts.pop(window["id"], None)
    close_window()


# MARK: what to tell the phone about this Mac


def computer_name() -> str:
    name = _run(["/usr/sbin/scutil", "--get", "ComputerName"])
    return name or socket.gethostname()


def local_hostname() -> str:
    """The Mac's `.local` name, which survives a change of IP address."""
    name = _run(["/usr/sbin/scutil", "--get", "LocalHostName"])
    return f"{name}.local" if name else ""


def lan_address() -> str:
    """Best guess at this Mac's address on the local network."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.168.1.1", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def tailscale_address() -> str:
    """The Mac's Tailscale address, if Tailscale is installed and running.

    This is what makes the assistant work away from home, and collecting it
    here is the whole point: nobody should have to know their own 100.x address.
    """
    binary = shutil.which("tailscale") or "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    if not Path(binary).exists():
        return ""
    lines = _run([binary, "ip", "-4"]).splitlines()
    return lines[0].strip() if lines else ""


def addresses() -> list[str]:
    """Every way to reach this Mac, best first, without duplicates or blanks.

    `.local` leads because it follows the Mac across a DHCP lease; the LAN
    address is the dependable fallback when mDNS is filtered; Tailscale is last
    because it only helps once you have left the house.
    """
    found = [local_hostname(), lan_address(), tailscale_address()]
    return list(dict.fromkeys(a for a in found if a))


def _run(command: list[str]) -> str:
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""
