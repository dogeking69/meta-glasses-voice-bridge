"""Where photos taken by the glasses land on this Mac.

A photo is written to disk because that is how Claude reads it: the CLI's Read
tool opens the file itself, which keeps everything on your Claude subscription
with no image upload from here.

The folder is capped. Without that, a day of asking "what am I looking at"
quietly fills your disk with pictures of your kitchen.
"""

from __future__ import annotations

import base64
import binascii
import datetime
from pathlib import Path

# Enough for a full-resolution capture, small enough to reject anything absurd.
MAX_PHOTO_BYTES = 8 * 1024 * 1024

# The first bytes of a JPEG and of a HEIC file. A photo that is neither is not
# something the glasses sent.
_JPEG_MAGIC = b"\xff\xd8\xff"
_HEIC_BRAND = b"ftyp"


class PhotoError(RuntimeError):
    pass


def folder(config: dict) -> Path:
    raw = config.get("actions", {}).get("look", {}).get("folder", "~/Pictures/VoiceBridge")
    path = Path(raw).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def _extension(data: bytes) -> str:
    if data.startswith(_JPEG_MAGIC):
        return ".jpg"
    if len(data) > 12 and data[4:8] == _HEIC_BRAND:
        return ".heic"
    raise PhotoError("That did not arrive as a photo.")


def save(encoded: str, config: dict) -> Path:
    """Decode a base64 photo from the phone and write it to the photo folder."""
    if not encoded:
        raise PhotoError("No photo arrived with that request.")

    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise PhotoError("The photo was not readable.") from None

    if len(data) > MAX_PHOTO_BYTES:
        raise PhotoError("That photo is too large.")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = folder(config) / f"look-{stamp}{_extension(data)}"
    path.write_bytes(data)
    prune(config)
    return path


def prune(config: dict) -> None:
    """Keep only the most recent photos."""
    keep = int(config.get("actions", {}).get("look", {}).get("keep", 50))
    photos = sorted(
        (p for p in folder(config).glob("look-*") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for stale in photos[keep:]:
        try:
            stale.unlink()
        except OSError:
            pass
