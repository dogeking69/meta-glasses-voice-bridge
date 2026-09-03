"""Holds commands that are waiting for you to say yes.

A risky action is never run straight off a transcription. It is parked here,
read back to you through the glasses, and only runs once you confirm.
"""

from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass, field


@dataclass
class Pending:
    action: str
    params: dict
    speak: str
    transcript: str
    created: float = field(default_factory=time.monotonic)


class PendingStore:
    def __init__(self, timeout_seconds: int = 180) -> None:
        self._timeout = timeout_seconds
        self._items: dict[str, Pending] = {}
        self._lock = threading.Lock()

    def put(self, pending: Pending) -> str:
        token = secrets.token_urlsafe(12)
        with self._lock:
            self._expire()
            self._items[token] = pending
        return token

    def take(self, token: str) -> Pending | None:
        """Fetch and remove. A confirmation can only ever be used once."""
        with self._lock:
            self._expire()
            return self._items.pop(token, None)

    def _expire(self) -> None:
        cutoff = time.monotonic() - self._timeout
        for token in [t for t, p in self._items.items() if p.created < cutoff]:
            del self._items[token]
