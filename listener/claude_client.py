"""Talks to Claude through the Claude Code CLI.

This uses your Claude subscription (the CLI is logged in with OAuth), so no
Anthropic API key is needed anywhere in this project.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

# The scratch directory the CLI is run from. Keeping it empty and separate stops
# Claude from picking up unrelated project files while classifying a command.
_WORKDIR = Path(__file__).resolve().parent / ".claude-workdir"

_SYSTEM_PROMPT = """\
You are the command router for a voice assistant driven by smart glasses.
You receive one transcribed utterance and reply with ONE JSON object, nothing else.
No prose, no markdown fences.

Schema:
  {"action": "<name>", "params": {...}, "speak": "<short sentence to read aloud>"}

Available actions:

1. "open_app" - the user wants an application opened on their Mac.
   params: {"app": "<lowercase app name>"}
   Allowed app names: %(apps)s
   Example: "open spotify" ->
     {"action":"open_app","params":{"app":"spotify"},"speak":"Opening Spotify."}

2. "ask_claude" - anything else: a question, a request for information, a
   thought to think through. Put your actual answer in "speak".
   params: {}
   Keep "speak" under 60 words. It is read aloud through glasses speakers, so
   write plain spoken sentences: no lists, no markdown, no code, no URLs.
   Example: "how far is the moon" ->
     {"action":"ask_claude","params":{},"speak":"About 239,000 miles on average."}

If the user asks to open an app that is not in the allowed list, use "ask_claude"
and say in "speak" that the app is not on the allowed list.
"""


class ClaudeError(RuntimeError):
    pass


@dataclass
class ClaudeConfig:
    binary: str
    model: str
    timeout_seconds: int


def ask(transcript: str, allowed_apps: list[str], config: ClaudeConfig) -> dict:
    """Send the transcript to Claude and return the parsed command dict."""
    _WORKDIR.mkdir(exist_ok=True)

    system = _SYSTEM_PROMPT % {"apps": ", ".join(sorted(allowed_apps))}
    cmd = [
        config.binary,
        "-p",
        "--model",
        config.model,
        "--append-system-prompt",
        system,
    ]

    try:
        proc = subprocess.run(
            cmd,
            input=transcript,
            capture_output=True,
            text=True,
            timeout=config.timeout_seconds,
            cwd=_WORKDIR,
        )
    except FileNotFoundError as exc:
        raise ClaudeError(f"Claude CLI not found at {config.binary}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ClaudeError(f"Claude timed out after {config.timeout_seconds}s") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        if "OAuth" in detail or "authenticate" in detail.lower():
            raise ClaudeError("Claude CLI is not logged in. Run 'claude' in a terminal.")
        raise ClaudeError(f"Claude CLI failed: {detail[:300]}")

    return _parse(proc.stdout)


def _parse(raw: str) -> dict:
    """Pull the JSON object out of Claude's reply, tolerating stray text."""
    text = raw.strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()
    else:
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            text = text[start : end + 1]

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        # Claude answered in plain prose. Treat the whole thing as a spoken reply
        # rather than failing the request.
        return {"action": "ask_claude", "params": {}, "speak": raw.strip()[:500]}

    if not isinstance(parsed, dict) or "action" not in parsed:
        raise ClaudeError(f"Claude returned unexpected JSON: {text[:200]}")

    parsed.setdefault("params", {})
    parsed.setdefault("speak", "")
    return parsed
