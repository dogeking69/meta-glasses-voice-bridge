#!/bin/bash
# Sets up the Mac half of the voice bridge in one go.
#
#   ./setup.sh
#
# It checks what is missing before it changes anything, writes your config file
# with a fresh secret, offers to start the listener at login, and opens a
# pairing window for the phone. Everything it does can be undone: the config
# file is yours to edit, and ./listener/service.sh uninstall removes the service.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LISTENER="$HERE/listener"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
say()  { printf '  %s\n' "$1"; }

problems=()
notes=()

bold "Voice bridge setup"
echo

# MARK: preflight — collect everything that is wrong before doing anything
#
# Reporting one problem, being fixed, then reporting the next is a miserable
# way to spend an evening. Everything missing is listed at once, each with the
# single command that fixes it.

if [ "$(uname)" != "Darwin" ]; then
    say "This listener drives a Mac, and only runs on one."
    exit 1
fi

PYTHON=""
for candidate in "$(command -v python3 || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$candidate" ] || continue
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    if command -v brew >/dev/null 2>&1; then
        problems+=("Python 3.11 or newer is missing. Install it with:
      brew install python3")
    else
        problems+=("Python 3.11 or newer is missing, and so is Homebrew, which is the
    easiest way to get it. Install Homebrew with:
      /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
    then run:  brew install python3
    (macOS ships Python 3.9, which cannot read this project's config file.)")
    fi
fi

CLAUDE="$(command -v claude || true)"
if [ -z "$CLAUDE" ]; then
    problems+=("The Claude Code CLI is missing. It is what turns what you say into an
    action. Install it from  https://claude.com/claude-code  then run:
      claude
    once, to log in.")
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    notes+=("Xcode is not installed. You need it later to put the app on your iPhone,
    but not for anything on this page. It is free from the App Store.")
fi

if [ ${#problems[@]} -gt 0 ]; then
    bold "Before going further:"
    echo
    for problem in "${problems[@]}"; do
        printf '  • %s\n\n' "$problem"
    done
    say "Fix those, then run ./setup.sh again. Nothing has been changed."
    exit 1
fi

say "Python     $PYTHON"
say "Claude     $CLAUDE"
for note in "${notes[@]:-}"; do [ -n "$note" ] && printf '\n  • %s\n' "$note"; done
echo

# MARK: config file and secret

if [ -f "$LISTENER/config.toml" ]; then
    say "Config     already at listener/config.toml, left alone"
else
    cp "$LISTENER/config.example.toml" "$LISTENER/config.toml"
    chmod 600 "$LISTENER/config.toml"
    say "Config     created listener/config.toml"
fi

if grep -q 'shared_secret = "CHANGE-ME"' "$LISTENER/config.toml"; then
    "$PYTHON" - "$LISTENER/config.toml" <<'PY'
import secrets, sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    'shared_secret = "CHANGE-ME"',
    f'shared_secret = "{secrets.token_hex(32)}"',
))
PY
    say "Secret     generated. You never have to read it — pairing hands it over."
else
    say "Secret     already set, left alone"
fi

# The Claude CLI has to be found by a service that gets almost no PATH, so the
# absolute path goes into the config now rather than failing mysteriously later.
"$PYTHON" - "$LISTENER/config.toml" "$CLAUDE" <<'PY'
import sys
from pathlib import Path

path, binary = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
if 'binary = "claude"' in text:
    path.write_text(text.replace('binary = "claude"', f'binary = "{binary}"'))
    print("  Claude CLI path written into config.toml")
PY
echo

# MARK: the service

read -r -p "  Start the listener automatically when you log in? [Y/n] " reply
case "${reply:-y}" in
    [Nn]*)
        say "Skipped. Start it by hand with ./listener/run.sh when you want it."
        say "Do that now in another window, then run ./listener/pair.sh to pair a phone."
        exit 0
        ;;
esac
echo
"$LISTENER/service.sh" install || exit 1
echo

# MARK: the phone

read -r -p "  Pair your iPhone now? [Y/n] " reply
case "${reply:-y}" in
    [Nn]*)
        say "Fine. Run ./listener/pair.sh whenever you are ready."
        exit 0
        ;;
esac

bold "In the app: Settings → Pair with your Mac → pick this Mac → type the PIN."
exec "$LISTENER/pair.sh"
