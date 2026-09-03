#!/bin/bash
# Starts the voice bridge listener.
cd "$(dirname "$0")" || exit 1
exec python3 server.py
