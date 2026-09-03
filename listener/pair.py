#!/usr/bin/env python3
"""Open a pairing window and show the PIN. Run this from ./pair.sh.

The listener has to be running: it is the listener, not this script, that
answers the phone. This only opens the window and waits to hear how it went.
"""

from __future__ import annotations

import sys
import time

import pairing


def main() -> None:
    window = pairing.open_window()
    deadline = window["expires_at"]
    pin = window["pin"]

    print()
    print("  Pairing window open. In the app, tap Pair with your Mac,")
    print(f"  pick \"{pairing.computer_name()}\", and enter:")
    print()
    print(f"      {pin[:3]} {pin[3:]}")
    print()

    try:
        while time.time() < deadline:
            if pairing.is_paired(window["id"]):
                print("\r  Paired. The app has your address and secret.        ")
                return
            left = int(deadline - time.time())
            print(f"\r  Waiting… {left // 60}:{left % 60:02d} left ", end="", flush=True)
            time.sleep(0.5)
    except KeyboardInterrupt:
        pairing.close_window()
        print("\r  Cancelled.                                    ")
        return

    pairing.close_window()
    print("\r  Window closed without pairing. Run this again to retry.")
    sys.exit(1)


if __name__ == "__main__":
    main()
