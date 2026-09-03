"""Announce the listener on the local network, so the phone can find this Mac
without anybody typing an IP address.

`dns-sd` ships with macOS and is already at /usr/bin/dns-sd, so this costs no
dependency. It advertises for as long as the process lives, which is exactly
the behaviour we want: the advert disappears the moment the listener stops.
"""

from __future__ import annotations

import atexit
import subprocess

DNS_SD = "/usr/bin/dns-sd"
SERVICE_TYPE = "_voicebridge._tcp"


def advertise(name: str, port: int) -> subprocess.Popen | None:
    """Start advertising, or return None if it could not be started.

    Failure is not fatal. Without the advert the phone simply cannot discover
    this Mac automatically, and the address can still be typed in by hand.
    """
    try:
        process = subprocess.Popen(
            [DNS_SD, "-R", name, SERVICE_TYPE, "local", str(port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None

    atexit.register(_stop, process)
    return process


def _stop(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
