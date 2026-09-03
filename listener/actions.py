"""The things the listener is actually allowed to do on this Mac.

Every action is explicit. Anything Claude asks for that is not in this file is
refused, so a bad transcription can never run arbitrary commands.

Actions listed under [confirm] require in config.toml are described back to you
out loud and only run once you say yes. `describe()` builds that sentence from
the *resolved* action, not from Claude's own words, so what you hear is always
what will actually happen.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import mac_actions
from mac_actions import MacError


class ActionError(RuntimeError):
    pass


def describe(action: str, params: dict, config: dict) -> str:
    """The sentence read back to you before a risky action runs."""
    if action == "claude_code":
        project, path = _resolve_project(params, config)
        instruction = str(params.get("instruction", "")).strip()
        return (
            f"About to run Claude Code in {project}, with the instruction: "
            f"{instruction}. Say yes to run it, no to cancel, or say what to change."
        )
    if action == "open_app":
        name = _resolve_app(params, config)
        return f"About to open {name}. Say yes or no."
    if action == "set_reminder":
        return f"About to remind you: {params.get('text', '')}. Say yes or no."
    if action == "take_note":
        return f"About to note: {params.get('text', '')}. Say yes or no."
    if action == "system_control":
        command = str(params.get("command", "")).replace("_", " ")
        return f"About to {command}. Say yes or no."
    if action == "empty_trash":
        return "About to empty your trash permanently. Say yes or no."
    if action == "type_text":
        return f"About to type: {params.get('text', '')}. Say yes or no."
    if action == "app_control":
        return (
            f"About to {params.get('action', '')} {params.get('app', '')}. "
            "Say yes or no."
        )
    if action == "run_shortcut":
        return f"About to run the shortcut {params.get('name', '')}. Say yes or no."
    if action == "window_control":
        return f"About to move the window {params.get('position', '')}. Say yes or no."
    if action == "keep_awake":
        return (
            f"About to keep your Mac awake for {params.get('minutes', '')} minutes. "
            "Say yes or no."
        )
    if action == "send_message":
        return (
            f"About to message {params.get('to', '')} saying: "
            f"{params.get('text', '')}. Say yes to send, no to cancel, "
            "or say what to change."
        )
    return f"About to run {action}. Say yes or no."


def run(action: str, params: dict, speak: str, config: dict) -> str:
    """Execute one action. Returns the sentence to read back through the glasses."""
    if action == "open_app":
        return _open_app(params, speak, config)
    if action == "claude_code":
        return _claude_code(params, config)
    if action == "ask_claude":
        return speak or "I did not have an answer for that."

    # Everything below lives in mac_actions. Its errors mean the same thing to
    # the caller, so they are re-raised as ActionError.
    try:
        if action == "system_control":
            return mac_actions.system_control(params, speak)
        if action == "take_note":
            return mac_actions.take_note(params, config)
        if action == "set_reminder":
            return mac_actions.set_reminder(params)
        if action == "get_status":
            return mac_actions.get_status(params, config)
        if action == "search_web":
            return mac_actions.search_web(params, speak)
        if action == "set_timer":
            return mac_actions.set_timer(params)
        if action == "clipboard":
            return mac_actions.clipboard(params)
        if action == "open_url":
            return mac_actions.open_url(params, speak)
        if action == "send_message":
            return mac_actions.send_message(params)
        if action == "run_shortcut":
            return mac_actions.run_shortcut(params, speak)
        if action == "app_control":
            return mac_actions.app_control(params, speak)
        if action == "find_file":
            return mac_actions.find_file(params)
        if action == "open_path":
            return mac_actions.open_path(params, speak)
        if action == "type_text":
            return mac_actions.type_text(params)
        if action == "brightness":
            return mac_actions.brightness(params)
        if action == "create_event":
            return mac_actions.create_event(params)
        if action == "empty_trash":
            return mac_actions.empty_trash()
        if action == "weather":
            return mac_actions.weather(params)
        if action == "window_control":
            return mac_actions.window_control(params)
        if action == "appearance":
            return mac_actions.appearance(params)
        if action == "keep_awake":
            return mac_actions.keep_awake(params)
    except MacError as exc:
        raise ActionError(str(exc)) from exc

    raise ActionError(f"Unknown action: {action!r}")


# MARK: open_app


def _allowed_apps(config: dict) -> dict[str, str]:
    return config.get("actions", {}).get("open_app", {})


def _resolve_app(params: dict, config: dict) -> str:
    requested = str(params.get("app", "")).strip().lower()
    if not requested:
        raise ActionError("open_app was called without an app name.")

    allowed = _allowed_apps(config)
    real_name = allowed.get(requested)
    if real_name is None:
        options = ", ".join(sorted(allowed))
        raise ActionError(f"{requested} is not on the allowed list. I can open: {options}.")
    return real_name


def _open_app(params: dict, speak: str, config: dict) -> str:
    real_name = _resolve_app(params, config)
    result = subprocess.run(["open", "-a", real_name], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        detail = result.stderr.strip() or "unknown error"
        raise ActionError(f"Could not open {real_name}: {detail}")
    return speak or f"Opening {real_name}."


# MARK: claude_code


def _claude_code_config(config: dict) -> dict:
    return config.get("actions", {}).get("claude_code", {})


def _resolve_project(params: dict, config: dict) -> tuple[str, Path]:
    """Map a spoken project name to a real folder. Only allowlisted folders."""
    requested = str(params.get("project", "")).strip().lower()
    if not requested:
        raise ActionError("No project was named. Say which project to work on.")

    projects = _claude_code_config(config).get("projects", {})
    raw_path = projects.get(requested)
    if raw_path is None:
        options = ", ".join(sorted(projects)) or "none configured"
        raise ActionError(f"{requested} is not a project I know. I can work on: {options}.")

    path = Path(raw_path).expanduser()
    if not path.is_dir():
        raise ActionError(f"The folder for {requested} no longer exists at {path}.")
    return requested, path


def _claude_code(params: dict, config: dict) -> str:
    project, path = _resolve_project(params, config)
    instruction = str(params.get("instruction", "")).strip()
    if not instruction:
        raise ActionError("No instruction was given for the coding task.")

    settings = _claude_code_config(config).get("settings", {})
    claude_config = config["claude"]

    cmd = [claude_config["binary"], "-p", "--model", claude_config.get("model", "sonnet")]
    if settings.get("allowed_tools"):
        cmd += ["--allowed-tools", settings["allowed_tools"]]
    if settings.get("disallowed_tools"):
        cmd += ["--disallowed-tools", settings["disallowed_tools"]]
    cmd += [
        "--append-system-prompt",
        "You are working through a voice assistant. Make the change, then reply "
        "with at most two plain spoken sentences saying what you did. No markdown, "
        "no code, no file paths read out character by character. Never push to a "
        "remote and never delete files you did not create.",
    ]

    try:
        proc = subprocess.run(
            cmd,
            input=instruction,
            capture_output=True,
            text=True,
            timeout=settings.get("timeout_seconds", 600),
            cwd=path,
        )
    except subprocess.TimeoutExpired:
        raise ActionError(
            f"Claude Code is still working on {project} after "
            f"{settings.get('timeout_seconds', 600)} seconds. Check your Mac."
        ) from None

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise ActionError(f"Claude Code failed in {project}: {detail[:200]}")

    reply = proc.stdout.strip()
    return reply[:600] if reply else f"Claude Code finished in {project}."


# MARK: - catalog

# What this assistant can do, in the app's words rather than Claude's. The
# prompt in claude_client.py tells Claude what is possible; this tells the
# person holding the phone, so the two are deliberately separate.
#
# Adding an action means three edits: the prompt, `run()` above, and one entry
# here so it shows up under "What I can do".
CATALOG: list[dict] = [
    {
        "category": "Ask",
        "action": "ask_claude",
        "summary": "Questions, facts, maths, translation, thinking out loud.",
        "examples": ["How far away is the moon?", "How do you say thank you in Greek?"],
    },
    {
        "category": "Ask",
        "action": "look",
        "summary": "Takes a photo through the glasses and describes what it sees.",
        "examples": ["What am I looking at?", "Read this label"],
    },
    {
        "category": "Ask",
        "action": "weather",
        "summary": "Current conditions, here or anywhere.",
        "examples": ["What's the weather?", "What's it like in Lisbon?"],
    },
    {
        "category": "Ask",
        "action": "get_status",
        "summary": "Reads live state off the Mac rather than guessing at it.",
        "examples": ["What's my battery?", "What app am I in?", "Any unread mail?"],
    },
    {
        "category": "Remember",
        "action": "take_note",
        "summary": "Appends to your notes file.",
        "examples": ["Make a note that the boiler needs servicing"],
    },
    {
        "category": "Remember",
        "action": "set_reminder",
        "summary": "Adds to the Mac's Reminders app.",
        "examples": ["Remind me to call the dentist"],
    },
    {
        "category": "Remember",
        "action": "set_timer",
        "summary": "A countdown that notifies on the Mac.",
        "examples": ["Set a timer for ten minutes"],
    },
    {
        "category": "Remember",
        "action": "create_event",
        "summary": "Adds an event to your calendar.",
        "examples": ["Add lunch with Sam to my calendar Friday at noon"],
    },
    {
        "category": "Control the Mac",
        "action": "system_control",
        "summary": "Volume, playback, brightness, lock, sleep, screenshots.",
        "examples": ["Turn the volume up", "Set the volume to thirty", "Lock the screen"],
    },
    {
        "category": "Control the Mac",
        "action": "open_app",
        "summary": "Opens an app. Only the ones you have allowed.",
        "examples": [],
    },
    {
        "category": "Control the Mac",
        "action": "app_control",
        "summary": "Quit, hide or switch to an app.",
        "examples": ["Quit Chrome", "Switch to Notes"],
    },
    {
        "category": "Control the Mac",
        "action": "window_control",
        "summary": "Moves the window in front around the screen.",
        "examples": ["Put this window on the left", "Make it full screen"],
    },
    {
        "category": "Control the Mac",
        "action": "appearance",
        "summary": "Dark mode on, off or flipped.",
        "examples": ["Turn on dark mode"],
    },
    {
        "category": "Control the Mac",
        "action": "keep_awake",
        "summary": "Stops the Mac sleeping while something long is running.",
        "examples": ["Keep my Mac awake for an hour"],
    },
    {
        "category": "Control the Mac",
        "action": "clipboard",
        "summary": "Reads or writes the Mac's clipboard.",
        "examples": ["What's on my clipboard?", "Copy hello world to my clipboard"],
    },
    {
        "category": "Control the Mac",
        "action": "type_text",
        "summary": "Types into whatever app is in front, for dictating.",
        "examples": ["Type out the following: dear Sam"],
    },
    {
        "category": "Find things",
        "action": "search_web",
        "summary": "Opens a web search on the Mac.",
        "examples": ["Look up the offside rule"],
    },
    {
        "category": "Find things",
        "action": "find_file",
        "summary": "Spotlight search by name.",
        "examples": ["Find the file budget spreadsheet"],
    },
    {
        "category": "Find things",
        "action": "open_path",
        "summary": "Opens a file or folder.",
        "examples": ["Open my downloads folder"],
    },
    {
        "category": "Reach people",
        "action": "send_message",
        "summary": "Sends an iMessage.",
        "examples": ["Text mom saying I'll be late"],
    },
    {
        "category": "Your own things",
        "action": "run_shortcut",
        "summary": "Runs one of your macOS Shortcuts.",
        "examples": [],
    },
    {
        "category": "Your own things",
        "action": "claude_code",
        "summary": "Real coding work in a project folder you have allowed.",
        "examples": [],
    },
    {
        "category": "Your own things",
        "action": "empty_trash",
        "summary": "Empties the trash, permanently.",
        "examples": ["Empty the trash"],
    },
]


def catalog(config: dict, needs_confirmation: set[str], shortcuts: list[str]) -> list[dict]:
    """The catalog with your own apps, projects and shortcuts filled in.

    Examples for those three are built from config rather than written down,
    so the list can never advertise something this Mac would refuse to do.
    """
    apps = sorted(_allowed_apps(config))
    projects = sorted(_claude_code_config(config).get("projects", {}))

    filled = []
    for entry in CATALOG:
        examples = list(entry["examples"])
        if entry["action"] == "open_app":
            examples = [f"Open {name}" for name in apps[:4]]
        elif entry["action"] == "claude_code":
            examples = [f"Continue working on {name}" for name in projects[:3]]
        elif entry["action"] == "run_shortcut":
            examples = [f"Run {name}" for name in shortcuts[:3]]

        filled.append({
            **entry,
            "examples": examples,
            "confirm": entry["action"] in needs_confirmation,
        })
    return filled
