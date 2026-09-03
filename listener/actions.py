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
