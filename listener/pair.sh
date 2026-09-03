#!/bin/bash
# Opens a two-minute window for the iPhone app to collect this Mac's address
# and shared secret. The listener must already be running.
cd "$(dirname "$0")" || exit 1
exec python3 pair.py
