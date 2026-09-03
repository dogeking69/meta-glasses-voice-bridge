#!/bin/bash
# Runs the listener as a background service, so it starts when you log in and
# you never have to keep a Terminal window open.
#
#   ./service.sh install     start it now and at every login
#   ./service.sh logs        watch what it is doing
#   ./service.sh status      is it running, and is it answering
#   ./service.sh restart     pick up a change to config.toml
#   ./service.sh stop        stop it until the next login
#   ./service.sh uninstall   remove it completely
#
# A background service has no window to watch, which is why `logs` and `status`
# exist: without them there is nowhere to see what went wrong.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.voicebridge.listener"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/VoiceBridge"
LOG="$LOG_DIR/listener.log"
ERROR_LOG="$LOG_DIR/listener.error.log"
TARGET="gui/$(id -u)"

# launchd gives a job almost no PATH, so anything the listener shells out to
# has to be findable. These are where Homebrew, pipx and Claude Code install.
SERVICE_PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

die() { echo "  $1" >&2; exit 1; }

find_python() {
    # /usr/bin/python3 is still 3.9 on current macOS and has no tomllib, so the
    # absolute path of a new enough Python is baked into the service.
    local candidate
    for candidate in "$(command -v python3 || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        [ -x "$candidate" ] || continue
        if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

check_claude() {
    # The planner shells out to the Claude CLI by whatever name config.toml
    # gives. "claude" alone works in your shell and fails under launchd.
    local python="$1" binary
    binary=$("$python" - "$HERE/config.toml" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as handle:
        print(tomllib.load(handle).get("claude", {}).get("binary", "claude"))
except OSError:
    print("claude")
PY
)
    case "$binary" in
        /*) [ -x "$binary" ] || echo "  warning: claude binary '$binary' is not executable." ;;
        *)
            local resolved
            resolved=$(PATH="$SERVICE_PATH" command -v "$binary" || true)
            if [ -z "$resolved" ]; then
                resolved=$(command -v "$binary" || true)
                echo "  warning: '$binary' is not on the service's PATH, so talking to Claude will fail."
                [ -n "$resolved" ] && echo "           Set  binary = \"$resolved\"  in config.toml and run ./service.sh restart."
            fi
            ;;
    esac
}

write_plist() {
    local python="$1"
    mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
    "$python" - "$PLIST" "$LABEL" "$python" "$HERE" "$LOG" "$ERROR_LOG" "$SERVICE_PATH" <<'PY'
import plistlib, sys

plist, label, python, here, log, error_log, path = sys.argv[1:8]
job = {
    "Label": label,
    "ProgramArguments": [python, f"{here}/server.py"],
    "WorkingDirectory": here,
    "EnvironmentVariables": {
        "PATH": path,
        "PYTHONUNBUFFERED": "1",
        # Tells the listener it has no window to print Ctrl+C advice to.
        "VOICEBRIDGE_SERVICE": "1",
    },
    "RunAtLoad": True,
    # Restart if it ever falls over. A service you have to notice and nurse is
    # no better than the Terminal window it replaced.
    "KeepAlive": True,
    "StandardOutPath": log,
    "StandardErrorPath": error_log,
    "ProcessType": "Interactive",
}
with open(plist, "wb") as handle:
    plistlib.dump(job, handle)
PY
}

is_loaded() { launchctl print "$TARGET/$LABEL" >/dev/null 2>&1; }

case "${1:-}" in
install)
    [ -f "$HERE/config.toml" ] || die "No config.toml yet. Copy config.example.toml to config.toml first."
    python=$(find_python) || die "Need Python 3.11 or newer. Install it with:  brew install python3"

    write_plist "$python"
    is_loaded && launchctl bootout "$TARGET/$LABEL" 2>/dev/null
    launchctl bootstrap "$TARGET" "$PLIST" || die "launchctl would not load the service. Check $ERROR_LOG"

    echo "  Installed. The listener now starts when you log in."
    echo "  python     $python"
    echo "  logs       $LOG"
    check_claude "$python"
    sleep 1
    exec "$0" status
    ;;
uninstall)
    is_loaded && launchctl bootout "$TARGET/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    echo "  Removed. Logs are kept at $LOG_DIR — delete that folder yourself if you want them gone."
    ;;
start)
    [ -f "$PLIST" ] || die "Not installed. Run ./service.sh install first."
    is_loaded || launchctl bootstrap "$TARGET" "$PLIST"
    launchctl kickstart "$TARGET/$LABEL" >/dev/null 2>&1
    echo "  Started."
    ;;
stop)
    is_loaded || die "Not running."
    launchctl bootout "$TARGET/$LABEL"
    echo "  Stopped. It will start again at your next login — use uninstall to prevent that."
    ;;
restart)
    is_loaded || die "Not running. Run ./service.sh install first."
    launchctl kickstart -k "$TARGET/$LABEL" >/dev/null
    echo "  Restarted."
    ;;
status)
    if is_loaded; then
        pid=$(launchctl print "$TARGET/$LABEL" | awk '/^\tpid = /{print $3}')
        echo "  service    loaded${pid:+, running as pid $pid}"
    else
        echo "  service    not loaded"
    fi
    port=$(grep -m1 '^port' "$HERE/config.toml" 2>/dev/null | tr -dc '0-9')
    port=${port:-8765}
    if curl -fsS -m 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        echo "  answering  yes, on port $port"
    else
        echo "  answering  no on port $port — see $ERROR_LOG"
    fi
    ;;
logs)
    [ -f "$LOG" ] || die "No log yet at $LOG. Run ./service.sh install first."
    echo "  $LOG  (Ctrl+C to stop watching)"
    tail -n 40 -f "$LOG" "$ERROR_LOG"
    ;;
*)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
