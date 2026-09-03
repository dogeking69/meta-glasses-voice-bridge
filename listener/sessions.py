"""Read-only access to Claude Code conversations stored on this Mac.

Claude Code writes every session as JSONL under ~/.claude/projects/<encoded
path>/<session id>.jsonl. Nothing here writes to those files.

Note this covers Claude Code sessions only. Conversations from the Claude app or
claude.ai live on Anthropic's servers with no local copy, so they cannot appear.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

# Blocks that are noise when reading a conversation back.
_SKIP_BLOCK_TYPES = {"thinking", "redacted_thinking"}


def _decode_project(dir_name: str) -> str:
    """Turn "-Users-me-Documents-thing" back into something readable."""
    path = dir_name.replace("-", "/")
    home = str(Path.home())
    if path.startswith(home):
        path = "~" + path[len(home):]
    return path.rsplit("/", 1)[-1] or path


def _iter_records(path: Path):
    try:
        with path.open(errors="ignore") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def list_sessions(limit: int = 40, project: str | None = None) -> list[dict]:
    """Recent sessions, newest first. Cheap: only titles and counts are read."""
    if not PROJECTS_DIR.is_dir():
        return []

    files = sorted(
        PROJECTS_DIR.glob("*/*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    out: list[dict] = []
    for path in files:
        # The listener runs Claude in its own scratch directory to route voice
        # commands. Those are not conversations worth browsing.
        if ".claude-workdir" in path.parent.name or path.parent.name.endswith("-workdir"):
            continue

        project_name = _decode_project(path.parent.name)
        if project and project.lower() not in project_name.lower():
            continue

        title, count, first_prompt = None, 0, ""
        for record in _iter_records(path):
            kind = record.get("type")
            if kind == "ai-title":
                title = record.get("aiTitle")
            elif kind in ("user", "assistant"):
                count += 1
                if kind == "user" and not first_prompt:
                    first_prompt = _flatten(record.get("message", {}).get("content"))[:90]

        if count == 0:
            continue

        out.append({
            "id": path.stem,
            "title": title or first_prompt or "Untitled session",
            "project": project_name,
            "messages": count,
            "modified": path.stat().st_mtime,
        })
        if len(out) >= limit:
            break
    return out


def read_session(session_id: str, limit: int = 300) -> dict | None:
    """One conversation, flattened to readable turns."""
    matches = list(PROJECTS_DIR.glob(f"*/{session_id}.jsonl"))
    if not matches:
        return None
    path = matches[0]

    title = None
    turns: list[dict] = []
    for record in _iter_records(path):
        kind = record.get("type")
        if kind == "ai-title":
            title = record.get("aiTitle")
            continue
        if kind not in ("user", "assistant"):
            continue

        text = _flatten(record.get("message", {}).get("content"))
        if not text:
            continue
        turns.append({
            "role": kind,
            "text": text[:4000],
            "at": _timestamp(record.get("timestamp")),
        })

    return {
        "id": session_id,
        "title": title or "Untitled session",
        "project": _decode_project(path.parent.name),
        "turns": turns[-limit:],
    }


def _flatten(content) -> str:
    """Content is either a plain string or a list of typed blocks."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""

    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind in _SKIP_BLOCK_TYPES:
            continue
        if kind == "text":
            parts.append(str(block.get("text", "")).strip())
        elif kind == "tool_use":
            parts.append(f"[used {block.get('name', 'a tool')}]")
        elif kind == "tool_result":
            parts.append("[tool result]")
    return "\n".join(p for p in parts if p).strip()


def _timestamp(raw) -> float:
    if not raw:
        return 0.0
    try:
        return datetime.fromisoformat(str(raw).replace("Z", "+00:00")).replace(
            tzinfo=timezone.utc
        ).timestamp()
    except ValueError:
        return 0.0
