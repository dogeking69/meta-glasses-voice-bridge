"""Mac control: the everyday assistant functions.

Kept separate from actions.py so the dispatcher stays readable. Everything here
is an explicit, named capability — nothing builds a shell command from speech.
"""

from __future__ import annotations

import datetime
import subprocess
import threading
from pathlib import Path
from urllib.parse import quote_plus


class MacError(RuntimeError):
    pass


def osascript(script: str, timeout: int = 15) -> str:
    """Run AppleScript. This is how Reminders, Music and Calendar are reached."""
    result = subprocess.run(
        ["osascript", "-e", script], capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        detail = lines[-1] if lines else "unknown error"
        if "not allowed" in detail.lower() or "not authorised" in detail.lower():
            raise MacError(
                "macOS blocked that. Allow it under System Settings, "
                "Privacy and Security, Automation."
            )
        raise MacError(detail[:160])
    return result.stdout.strip()


# MARK: - system_control

SYSTEM_COMMANDS: dict[str, tuple[str, str]] = {
    "volume_up": (
        "set volume output volume (output volume of (get volume settings) + 15)",
        "Volume up.",
    ),
    "volume_down": (
        "set volume output volume (output volume of (get volume settings) - 15)",
        "Volume down.",
    ),
    "mute": ("set volume with output muted", "Muted."),
    "unmute": ("set volume without output muted", "Unmuted."),
    "play_pause": ('tell application "Music" to playpause', "Toggled playback."),
    "next_track": ('tell application "Music" to next track', "Skipped."),
    "previous_track": ('tell application "Music" to previous track', "Went back."),
    "lock_screen": (
        'tell application "System Events" to keystroke "q" using {control down, command down}',
        "Locking the screen.",
    ),
    "sleep": ('tell application "System Events" to sleep', "Going to sleep."),
}


def system_control(params: dict, speak: str) -> str:
    command = str(params.get("command", "")).strip().lower()

    if command == "screenshot":
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        target = Path.home() / "Desktop" / f"voicebridge-{stamp}.png"
        subprocess.run(["screencapture", "-x", str(target)], timeout=20)
        return "Screenshot saved to your desktop."

    entry = SYSTEM_COMMANDS.get(command)
    if entry is None:
        options = ", ".join(sorted(list(SYSTEM_COMMANDS) + ["screenshot"]))
        raise MacError(f"I cannot do that. I can do: {options}.")

    script, default_reply = entry
    osascript(script)
    return speak or default_reply


# MARK: - notes and reminders

def notes_path(config: dict) -> Path:
    raw = config.get("actions", {}).get("take_note", {}).get("file", "~/Documents/voice-notes.md")
    return Path(raw).expanduser()


def take_note(params: dict, config: dict) -> str:
    text = str(params.get("text", "")).strip()
    if not text:
        raise MacError("There was nothing to write down.")

    path = notes_path(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"- {stamp} - {text}\n")
    return "Noted."


def set_reminder(params: dict) -> str:
    text = str(params.get("text", "")).strip()
    if not text:
        raise MacError("There was nothing to remind you about.")
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    osascript(
        f'tell application "Reminders" to make new reminder with properties {{name:"{escaped}"}}'
    )
    return "Added to your reminders."


# MARK: - get_status

def get_status(params: dict, config: dict) -> str:
    what = str(params.get("what", "time")).strip().lower()

    if what == "time":
        return "It is " + datetime.datetime.now().strftime("%-I:%M %p") + "."
    if what == "date":
        return "It is " + datetime.datetime.now().strftime("%A, %B %-d") + "."
    if what == "battery":
        return _battery()
    if what == "now_playing":
        return _now_playing()
    if what == "next_event":
        return _next_event()
    if what == "disk":
        out = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, timeout=10).stdout
        parts = out.strip().splitlines()[-1].split()
        return f"{parts[3]} free of {parts[1]}."
    if what == "notes":
        return _recent_notes(config)
    if what in ("frontmost", "frontmost_app", "current_app"):
        return frontmost_app()
    if what == "shortcuts":
        names = list_shortcuts()
        if not names:
            return "You have no shortcuts."
        return f"You have {len(names)} shortcuts, including " + ", ".join(names[:5]) + "."
    if what == "uptime":
        out = subprocess.run(["uptime"], capture_output=True, text=True, timeout=10).stdout
        return "Your Mac says: " + out.split("up ", 1)[-1].split(",")[0].strip() + "."
    if what == "wifi":
        name = subprocess.run(
            ["networksetup", "-getairportnetwork", "en0"],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return name.split(": ", 1)[-1] if ": " in name else "Not on Wi-Fi." 

    raise MacError(f"I cannot look up {what}.")


def _battery() -> str:
    out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=10).stdout
    for token in out.split():
        if token.endswith("%;"):
            return f"Your Mac is at {token.rstrip('%;')} percent."
    return "Your Mac does not report a battery."


def _now_playing() -> str:
    try:
        state = osascript('tell application "Music" to player state as string')
    except MacError:
        return "Music is not running."
    if state != "playing":
        return "Nothing is playing."
    name = osascript('tell application "Music" to name of current track')
    artist = osascript('tell application "Music" to artist of current track')
    return f"{name} by {artist}." if artist else f"{name}."


def _next_event() -> str:
    script = (
        'set output to ""\n'
        'tell application "Calendar"\n'
        "  set rightNow to current date\n"
        "  set laterOn to rightNow + (2 * days)\n"
        "  repeat with cal in calendars\n"
        "    repeat with evt in (every event of cal whose start date > rightNow "
        "and start date < laterOn)\n"
        '      set output to output & (summary of evt) & "|" & '
        "((start date of evt) as string) & linefeed\n"
        "    end repeat\n"
        "  end repeat\n"
        "end tell\n"
        "return output"
    )
    raw = osascript(script, timeout=60)
    rows = [line for line in raw.splitlines() if "|" in line]
    if not rows:
        return "Nothing on your calendar in the next two days."
    title, when = sorted(rows)[0].split("|", 1)
    return f"{title.strip()}, {when.strip()}."


def _recent_notes(config: dict) -> str:
    path = notes_path(config)
    if not path.exists():
        return "You have no notes yet."
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    if not lines:
        return "You have no notes yet."
    recent = [line.split(" - ", 2)[-1].strip() for line in lines[-3:]]
    return "Your last notes: " + " ".join(recent)


# MARK: - search_web

def search_web(params: dict, speak: str) -> str:
    query = str(params.get("query", "")).strip()
    if not query:
        raise MacError("There was nothing to search for.")
    subprocess.run(["open", f"https://duckduckgo.com/?q={quote_plus(query)}"], timeout=15)
    return speak or f"Searching for {query}."


# MARK: - timers

def _notify(title: str, body: str) -> None:
    escaped_title = title.replace('"', "'")
    escaped_body = body.replace('"', "'")
    subprocess.run(
        ["osascript", "-e",
         f'display notification "{escaped_body}" with title "{escaped_title}" sound name "Glass"'],
        capture_output=True, timeout=15,
    )


def set_timer(params: dict) -> str:
    """Fires a Mac notification after a delay. A thread is enough — this is a
    personal tool, and a timer that dies with the listener is acceptable."""
    try:
        seconds = int(float(params.get("seconds", 0)))
    except (TypeError, ValueError):
        raise MacError("I did not catch how long to set the timer for.") from None
    if seconds <= 0:
        raise MacError("I did not catch how long to set the timer for.")
    if seconds > 24 * 3600:
        raise MacError("That timer is longer than a day. Use a reminder instead.")

    label = str(params.get("label", "")).strip() or "Timer"
    threading.Timer(seconds, _notify, args=(label, "Time is up.")).start()

    if seconds < 60:
        spoken = f"{seconds} seconds"
    elif seconds % 60 == 0:
        minutes = seconds // 60
        spoken = f"{minutes} minute" + ("s" if minutes != 1 else "")
    else:
        spoken = f"{seconds // 60} minutes {seconds % 60} seconds"
    return f"Timer set for {spoken}."


# MARK: - clipboard

def clipboard(params: dict) -> str:
    mode = str(params.get("mode", "read")).strip().lower()

    if mode == "read":
        text = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=10).stdout.strip()
        if not text:
            return "Your clipboard is empty."
        return f"Your clipboard says: {text[:400]}"

    if mode == "write":
        text = str(params.get("text", ""))
        if not text:
            raise MacError("There was nothing to copy.")
        subprocess.run(["pbcopy"], input=text, text=True, timeout=10)
        return "Copied to your clipboard."

    raise MacError("I can read or write the clipboard.")


# MARK: - open_url

def open_url(params: dict, speak: str) -> str:
    url = str(params.get("url", "")).strip()
    if not url:
        raise MacError("There was no address to open.")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    subprocess.run(["open", url], timeout=15)
    return speak or "Opening it now."


# MARK: - send_message

def send_message(params: dict) -> str:
    """iMessage via AppleScript. Always behind a spoken confirmation."""
    recipient = str(params.get("to", "")).strip()
    text = str(params.get("text", "")).strip()
    if not recipient or not text:
        raise MacError("I need both who to message and what to say.")

    esc_to = recipient.replace("\\", "\\\\").replace('"', '\\"')
    esc_text = text.replace("\\", "\\\\").replace('"', '\\"')
    osascript(
        f'tell application "Messages" to send "{esc_text}" to '
        f'buddy "{esc_to}" of (1st service whose service type = iMessage)'
    )
    return f"Message sent to {recipient}."


# MARK: - Shortcuts

def list_shortcuts() -> list[str]:
    out = subprocess.run(["shortcuts", "list"], capture_output=True, text=True, timeout=20)
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def run_shortcut(params: dict, speak: str) -> str:
    """Runs a macOS Shortcut by name. Anything the user builds in the Shortcuts
    app becomes voice-callable without changing this code."""
    name = str(params.get("name", "")).strip()
    if not name:
        raise MacError("I did not catch which shortcut to run.")

    available = list_shortcuts()
    match = next((s for s in available if s.lower() == name.lower()), None)
    if match is None:
        match = next((s for s in available if name.lower() in s.lower()), None)
    if match is None:
        sample = ", ".join(available[:8]) or "none"
        raise MacError(f"I could not find a shortcut called {name}. You have: {sample}.")

    result = subprocess.run(["shortcuts", "run", match], capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise MacError(f"{match} failed: {(result.stderr or '').strip()[:120]}")
    output = (result.stdout or "").strip()
    return output[:400] if output else (speak or f"Ran {match}.")


# MARK: - applications

def app_control(params: dict, speak: str) -> str:
    action = str(params.get("action", "")).strip().lower()
    name = str(params.get("app", "")).strip()
    if not name:
        raise MacError("I did not catch which app.")
    escaped = name.replace('"', '\\"')

    if action == "quit":
        osascript(f'tell application "{escaped}" to quit')
        return speak or f"Closed {name}."
    if action == "hide":
        osascript(f'tell application "System Events" to set visible of process "{escaped}" to false')
        return speak or f"Hid {name}."
    if action == "focus":
        osascript(f'tell application "{escaped}" to activate')
        return speak or f"Switched to {name}."

    raise MacError("I can quit, hide or focus an app.")


def frontmost_app() -> str:
    name = osascript(
        'tell application "System Events" to get name of first application process '
        "whose frontmost is true"
    )
    return f"You are in {name}."


# MARK: - files

def find_file(params: dict) -> str:
    """Spotlight search. Read-only: it reports paths, it does not open them."""
    query = str(params.get("query", "")).strip()
    if not query:
        raise MacError("I did not catch what to look for.")

    result = subprocess.run(
        ["mdfind", "-name", query], capture_output=True, text=True, timeout=45
    )
    hits = [line for line in result.stdout.splitlines() if line.strip()][:5]
    if not hits:
        return f"I could not find anything called {query}."

    names = [Path(h).name for h in hits]
    listed = ", ".join(names[:3])
    more = f", and {len(hits) - 3} more" if len(hits) > 3 else ""
    return f"I found {listed}{more}."


def open_path(params: dict, speak: str) -> str:
    raw = str(params.get("path", "")).strip()
    if not raw:
        raise MacError("I did not catch what to open.")
    path = Path(raw).expanduser()
    if not path.exists():
        raise MacError(f"There is nothing at {path}.")
    subprocess.run(["open", str(path)], timeout=20)
    return speak or f"Opening {path.name}."


# MARK: - typing and display

def type_text(params: dict) -> str:
    """Types into whatever app is in front. Useful for dictating into a document
    without touching the keyboard."""
    text = str(params.get("text", "")).strip()
    if not text:
        raise MacError("There was nothing to type.")
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    osascript(f'tell application "System Events" to keystroke "{escaped}"', timeout=60)
    return "Typed it."


def brightness(params: dict) -> str:
    direction = str(params.get("direction", "")).strip().lower()
    key = {"up": 144, "down": 145}.get(direction)
    if key is None:
        raise MacError("I can turn the brightness up or down.")
    osascript(f'tell application "System Events" to key code {key}')
    return f"Brightness {direction}."


# MARK: - calendar

def create_event(params: dict) -> str:
    title = str(params.get("title", "")).strip()
    when = str(params.get("when", "")).strip()
    if not title:
        raise MacError("I did not catch what the event is.")
    if not when:
        raise MacError("I did not catch when the event is.")

    esc_title = title.replace('"', '\\"')
    esc_when = when.replace('"', '\\"')
    osascript(
        f'set theDate to date "{esc_when}"\n'
        'tell application "Calendar" to tell calendar 1 to make new event '
        f'with properties {{summary:"{esc_title}", start date:theDate, '
        "end date:theDate + (1 * hours)}}",
        timeout=45,
    )
    return f"Added {title} to your calendar."


# MARK: - trash

def empty_trash() -> str:
    """Destructive, so it is confirmed out loud before it runs."""
    osascript('tell application "Finder" to empty trash')
    return "Trash emptied."
