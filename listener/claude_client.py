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
             screenshot, set_volume>"}
   set_volume also takes {"level": <0 to 100>}.

5. "take_note" - write something down for later.
   params: {"text": "<the note>"}

6. "set_reminder" - add a reminder to the Mac's Reminders app.
   params: {"text": "<what to remember>"}

7. "get_status" - read back live information from the Mac.
   params: {"what": "<one of: time, date, battery, now_playing, next_event,
             disk, notes, frontmost, shortcuts, uptime, wifi, volume, mail,
             reminders, ip>"}
   Use "frontmost" when asked what app they are in. Never guess at live state -
   always read it.

8. "search_web" - open a web search on the Mac when the user wants to look
   something up rather than just be told.
   params: {"query": "<search terms>"}

9. "set_timer" - a countdown that notifies on the Mac when it finishes.
   params: {"seconds": <number>, "label": "<what it is for>"}

10. "clipboard" - read or write the Mac's clipboard.
    params: {"mode": "read"} or {"mode": "write", "text": "<what to copy>"}

11. "open_url" - open a specific web page.
    params: {"url": "<the address>"}

12. "send_message" - send an iMessage. Always confirmed out loud first.
    params: {"to": "<name or number>", "text": "<the message>"}

13. "run_shortcut" - run one of the user's own macOS Shortcuts. Prefer this
    when a shortcut clearly matches what they asked for.
    params: {"name": "<shortcut name>"}
    Available: %(shortcuts)s

14. "app_control" - quit, hide or switch to an application.
    params: {"action": "quit" | "hide" | "focus", "app": "<name>"}

15. "find_file" - Spotlight search for a file by name.
    params: {"query": "<name>"}

16. "open_path" - open a specific file or folder.
    params: {"path": "<path, ~ allowed>"}

17. "type_text" - type into whatever app is in front, for dictating.
    params: {"text": "<what to type>"}

18. "brightness" - screen brightness.
    params: {"direction": "up" | "down"}

19. "create_event" - add a calendar event. "when" must be a date AppleScript
    understands, like "September 5, 2026 2:00 PM".
    params: {"title": "<what>", "when": "<when>"}

20. "empty_trash" - permanently empty the Mac's trash. Confirmed out loud.
    params: {}

21. "weather" - current conditions outside.
    params: {"location": "<place, or empty for where they are>"}

22. "window_control" - move the window that is in front.
    params: {"position": "left" | "right" | "top" | "bottom" | "full" | "center"}

23. "appearance" - the Mac's dark mode.
    params: {"mode": "dark" | "light" | "toggle"}

24. "keep_awake" - stop the Mac going to sleep for a while.
    params: {"minutes": <number>} or {"mode": "stop"} to let it sleep again.

25. "look" - use the camera in the glasses to see what the user is looking at.
    Use this for anything about their surroundings: "what am I looking at",
    "read this label", "what does this sign say", "is this ripe". The photo is
    taken after you reply, so put the question itself in params.
    params: {"question": "<what to answer about the photo>"}

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
    shortcuts: list[str] | None = None,
) -> dict:
    """Send the transcript to Claude and return the parsed command dict."""
    _WORKDIR.mkdir(exist_ok=True)
    shortcuts = shortcuts or []

    system = _SYSTEM_PROMPT % {
        "apps": ", ".join(sorted(allowed_apps)) or "none configured",
        "projects": ", ".join(sorted(allowed_projects)) or "none configured",
        "shortcuts": ", ".join(shortcuts[:60]) or "none",
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


_LOOK_PROMPT = """\
Look at the image file at {path} using the Read tool, then answer this question
about it: {question}

Your answer is read aloud through the speakers in a pair of smart glasses.
Write plain spoken sentences: no markdown, no lists, no file paths, no emoji.
Two sentences at most unless the user clearly asked for detail. The photo was
taken from the wearer's point of view, so "you" means them. If the photo is too
dark or blurred to tell, say so plainly rather than guessing.
"""


def describe_image(image_path: Path, question: str, config: ClaudeConfig) -> str:
    """Ask Claude what is in a photo taken by the glasses.

    The CLI reads the file off disk with its own Read tool, so this still runs
    on the Claude subscription — no API key and no image upload from here.
    """
    prompt = _LOOK_PROMPT.format(
        path=image_path, question=question.strip() or "What am I looking at?"
    )

    cmd = [
        config.binary,
        "-p",
        "--model",
        config.model,
        # Read is the only tool it needs, and the only one it gets.
        "--allowed-tools",
        "Read",
    ]

    try:
        proc = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=max(config.timeout_seconds, 120),
            cwd=image_path.parent,
        )
    except FileNotFoundError as exc:
        raise ClaudeError(f"Claude CLI not found at {config.binary}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ClaudeError("Claude took too long to look at that photo.") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        if "OAuth" in detail or "authenticate" in detail.lower():
            raise ClaudeError("Claude CLI is not logged in. Run 'claude' in a terminal.")
        raise ClaudeError(f"Claude could not read the photo: {detail[:200]}")

    answer = proc.stdout.strip()
    if not answer:
        raise ClaudeError("Claude had nothing to say about that photo.")
    return answer[:600]
