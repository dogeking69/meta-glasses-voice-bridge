"""The things the listener is actually allowed to do on this Mac.

Every action is explicit. Anything Claude asks for that is not in this file
is refused, so a bad transcription can never run arbitrary commands.
"""

from __future__ import annotations

import subprocess


class ActionError(RuntimeError):
    pass


def run(action: str, params: dict, speak: str, allowed_apps: dict[str, str]) -> str:
    """Execute one action. Returns the sentence to read back through the glasses."""
    if action == "open_app":
        return _open_app(params, speak, allowed_apps)
    if action == "ask_claude":
        return speak or "I did not have an answer for that."
    raise ActionError(f"Unknown action: {action!r}")


def _open_app(params: dict, speak: str, allowed_apps: dict[str, str]) -> str:
    requested = str(params.get("app", "")).strip().lower()
    if not requested:
        raise ActionError("open_app was called without an app name.")

    real_name = allowed_apps.get(requested)
    if real_name is None:
        options = ", ".join(sorted(allowed_apps))
        raise ActionError(f"{requested} is not on the allowed list. I can open: {options}.")

    result = subprocess.run(
        ["open", "-a", real_name],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "unknown error"
        raise ActionError(f"Could not open {real_name}: {detail}")

    return speak or f"Opening {real_name}."
