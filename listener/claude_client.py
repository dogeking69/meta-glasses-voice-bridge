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
You are the assistant behind a pair of smart glasses. The user speaks; you reply
with ONE JSON object and nothing else. No prose, no markdown fences.

Schema:
  {"action": "<name>", "params": {...}, "speak": "<what to read aloud>"}

Everything in "speak" is read aloud through glasses speakers. Write plain spoken
sentences: no markdown, no lists, no code, no URLs, no emoji. Under 60 words
unless the user clearly asked for detail.

Actions:

1. "ask_claude" - questions, facts, advice, translation, maths, thinking out
   loud, and anything conversational. Put your real answer in "speak".
   params: {}

2. "open_app" - open an application on the Mac.
   params: {"app": "<lowercase name>"}
   Allowed: %(apps)s

3. "claude_code" - do real work on one of the user's coding projects.
   params: {"project": "<lowercase name>", "instruction": "<what to do>"}
   Allowed projects: %(projects)s

4. "system_control" - control the Mac itself.
   params: {"command": "<one of: volume_up, volume_down, mute, unmute,
             play_pause, next_track, previous_track, lock_screen, sleep,
             screenshot>"}

5. "take_note" - write something down for later.
   params: {"text": "<the note>"}

6. "set_reminder" - add a reminder to the Mac's Reminders app.
   params: {"text": "<what to remember>"}

7. "get_status" - read back live information from the Mac.
   params: {"what": "<one of: time, date, battery, now_playing, next_event,
             disk, notes>"}

8. "search_web" - open a web search on the Mac when the user wants to look
   something up rather than just be told.
   params: {"query": "<search terms>"}

Rules:
- Prefer answering directly with "ask_claude" over opening things.
- If an app or project is not in the allowed lists, use "ask_claude" and say
  which ones are available.
- Recent conversation is given below. Use it: "do that again", "and open notes
  too", "what did I just ask you" all refer to it. Resolve pronouns against it.
- The transcription comes from an 8 kHz microphone and contains errors. Infer
  what was meant rather than matching literally.
"""


class ClaudeError(RuntimeError):
    pass


@dataclass
class ClaudeConfig:
    binary: str
    model: str
    timeout_seconds: int


def ask(
    transcript: str,
    allowed_apps: list[str],
    allowed_projects: list[str],
    config: ClaudeConfig,
    context: str = "",
) -> dict:
    """Send the transcript to Claude and return the parsed command dict."""
    _WORKDIR.mkdir(exist_ok=True)

    system = _SYSTEM_PROMPT % {
        "apps": ", ".join(sorted(allowed_apps)) or "none configured",
        "projects": ", ".join(sorted(allowed_projects)) or "none configured",
    }
    if context:
        system += f"\n\nRecent conversation, oldest first:\n{context}\n"
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
