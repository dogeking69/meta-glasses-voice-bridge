"""Conversation memory.

Without this every utterance is a cold start, so "now open notes too" or "what
did I just ask you" cannot work. Recent turns are passed back to Claude as
context, and the whole log is what the app's History tab shows.
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

HISTORY_PATH = Path(__file__).resolve().parent / "history.json"


@dataclass
class Turn:
    transcript: str
    action: str
    params: dict = field(default_factory=dict)
    reply: str = ""
    ok: bool = True
    error: str = ""
    at: float = field(default_factory=time.time)

    @property
    def id(self) -> str:
        return f"{self.at:.6f}"


class Conversation:
    """Thread-safe, file-backed. Small enough that rewriting the file is fine."""

    def __init__(self, keep: int = 200, context_turns: int = 6) -> None:
        self._keep = keep
        self._context_turns = context_turns
        self._lock = threading.Lock()
        self._turns: list[Turn] = self._load()

    def add(self, turn: Turn) -> None:
        with self._lock:
            self._turns.append(turn)
            del self._turns[: max(0, len(self._turns) - self._keep)]
            self._save()

    def recent(self, limit: int | None = None) -> list[Turn]:
        with self._lock:
            turns = list(self._turns)
        return turns[-limit:] if limit else turns

    def clear(self) -> None:
        with self._lock:
            self._turns = []
            self._save()

    def context(self) -> str:
        """The last few turns, rendered for Claude's prompt."""
        turns = self.recent(self._context_turns)
        if not turns:
            return ""
        lines = []
        for turn in turns:
            lines.append(f'User: "{turn.transcript}"')
            outcome = turn.reply if turn.ok else f"(failed: {turn.error})"
            lines.append(f"You: {turn.action} -> {outcome}")
        return "\n".join(lines)

    # MARK: - Persistence

    def _load(self) -> list[Turn]:
        if not HISTORY_PATH.exists():
            return []
        try:
            raw = json.loads(HISTORY_PATH.read_text())
            return [Turn(**item) for item in raw]
        except (json.JSONDecodeError, TypeError, ValueError):
            # A corrupt history should never stop the listener from starting.
            return []

    def _save(self) -> None:
        try:
            HISTORY_PATH.write_text(json.dumps([asdict(t) for t in self._turns], indent=1))
        except OSError:
            pass
