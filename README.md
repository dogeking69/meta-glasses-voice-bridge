<h1 align="center">Voice Bridge</h1>

<p align="center">
  <b>Talk to your Ray-Ban Meta glasses. Your Mac does the thing.</b><br>
  Voice commands from Meta smart glasses → Claude → actions on your computer.
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg">
  <img alt="iOS 16+" src="https://img.shields.io/badge/iOS-16%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white">
  <img alt="Python 3.11+" src="https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python&logoColor=white">
  <img alt="No API key required" src="https://img.shields.io/badge/API%20key-not%20required-brightgreen">
</p>

<p align="center">
  <img src="docs/app-main.png" alt="Voice Bridge iOS app showing glasses, microphone and Mac connection status above a large hold-to-talk button" width="300">
</p>

An open-source companion app for the **Meta Wearables Device Access Toolkit
(DAT)**. Hold a button, speak through your glasses, and Claude turns what you
said into a structured command your Mac executes — opening an app, or just
answering the question out loud.

Built because Meta's toolkit gives third-party apps real access to the glasses,
but the `"Hey Meta"` wake word stays private to Meta. This uses an explicit
in-app button instead.

```
Glasses mic (Bluetooth hands-free audio, 8 kHz)
  -> iPhone app turns speech into text, on the device
  -> signed request over your Wi-Fi
  -> Mac listener asks Claude what you meant
  -> Mac runs the action and sends back a sentence
  -> iPhone speaks it through the glasses
```

**No Anthropic API key is needed.** The Mac calls Claude through the Claude Code
CLI, which is logged in with your Claude subscription.

---

## Two things to know before you start

> **If you only read one thing, read this.** It is the answer to the question
> that probably brought you here.

**1. The glasses microphone is not part of Meta's SDK.**
The Device Access Toolkit (DAT) gives you camera, display, and the pairing
session. Microphone and speaker audio arrive as ordinary Bluetooth hands-free
audio, which the app reads with Apple's own AVFoundation. That is why the app
works even before you add the Meta package — you just won't see glasses session
status on screen.

**2. Audio is 8 kHz mono**, the same quality as a phone call. That is fine for
speech-to-text, which is all we use it for.

---

## Get the code

```bash
git clone https://github.com/dogeking69/meta-glasses-voice-bridge.git
cd meta-glasses-voice-bridge
```

`git clone` downloads a copy of this repository; `cd` moves your terminal into
that folder. Every command below is run from there.

---

## Part 1 — Set up the Mac listener

**Step 1. Log in to Claude.** Open Terminal and run:

```bash
claude
```

Follow the login prompt. Your session had expired when this was built, so this
step is required. You only do it once.

**Step 2. Make your config file.** In Terminal:

```bash
cp listener/config.example.toml listener/config.toml
```

`cp` copies a file. `config.toml` is ignored by Git so your secret never gets committed.

**Step 3. Generate a shared secret.** This is a long random password the phone
and the Mac both know, so nothing else on your Wi-Fi can drive your computer:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

Copy the output, open `listener/config.toml`, and paste it as the value of
`shared_secret`. Keep the terminal window — you need the same value on the phone.

**Step 4. Start the listener:**

```bash
./listener/run.sh
```

It prints the address your phone should use, like `http://192.168.1.173:8765`.
Leave this window open; `Ctrl+C` stops it.

---

## Part 2 — Set up the iPhone app

**Step 1.** Open `ios/VoiceBridge.xcodeproj` in Xcode.

**Step 2. Set your signing team.** Click the blue `VoiceBridge` project in the
left sidebar → the `VoiceBridge` target → **Signing & Capabilities** → pick your
Apple ID under **Team**. Without this the app cannot install on your phone.

**Step 3.** Plug in your iPhone, pick it in the device menu at the top, press
the ▶ Run button.

**Step 4.** The app opens its Settings screen on first launch. Enter the address
the listener printed, and paste the same shared secret. Tap **Test connection**
— it should say "Reached your Mac." The secret is stored in the iPhone Keychain.

**Step 5.** Put on the glasses, make sure they are connected to the phone over
Bluetooth, then hold the big microphone button and speak. Let go when done.

The **Microphone** row on the main screen turns green only when audio is really
coming from the glasses rather than the iPhone. If it stays grey, the glasses are
not connected over Bluetooth.

---

## Part 3 — Add the Meta toolkit (optional, do it after the above works)

The app is written so it compiles and runs without the Meta package. Adding it
turns on glasses registration and session status.

1. **Enable Developer Mode on the glasses**, in the Meta AI app's settings. You
   need Meta AI app v247 or newer and glasses firmware v20 or newer.
2. Register at the [Wearables Developer Center](https://wearables.developer.meta.com)
   and create a project. You get a **Meta App ID** and a **Client Token**.
3. In Xcode: **File → Add Package Dependencies**, paste
   `https://github.com/facebook/meta-wearables-dat-ios`, and add the
   **MWDATCore** product to the VoiceBridge target.
4. Open `ios/VoiceBridge/Info.plist` and fill in the `MWDAT` block: put your App
   ID in `MetaAppID` and your token in `ClientToken`. `TeamID` fills itself in
   from your signing team.
5. Rebuild. A **Connect glasses** button appears; tapping it hands off to the
   Meta AI app for approval and returns you here.

**Live SDK docs.** Meta runs a documentation server you can connect to Claude
Code so DAT questions get answered from current docs instead of guesswork. Run
this in a Terminal (not in this app):

```bash
claude mcp add --transport http meta-wearables https://mcp.developer.meta.com/wearables
```

Then in a `claude` session you can use `search_dat_docs`.

---

## The actions it can do

Defined in `listener/actions.py`. Only these two exist on purpose — a bad
transcription can never run a command that is not listed here.

| You say | What happens |
|---|---|
| "open spotify" | Opens Spotify on your Mac. Only apps listed under `[actions.open_app]` in `config.toml` are allowed. |
| anything else | Claude answers, and the answer is read aloud through the glasses. |

To allow another app, add a line to `[actions.open_app]` in `config.toml`:
`slack = "Slack"` — the left side is what you say, the right side is the real
app name. Restart the listener afterwards.

To add a genuinely new kind of action, you edit two places: describe it in the
prompt in `listener/claude_client.py`, and implement it in `listener/actions.py`.

---

## Security

- Every request is signed with HMAC-SHA256 over `<timestamp>.<body>`. Wrong
  secret, no signature, or a request older than 60 seconds is rejected.
- The listener binds to your local network only. Nothing is exposed to the
  internet, and you should not port-forward it — the shared secret alone is not
  enough protection for a public endpoint.
- The shared secret lives in `config.toml` (gitignored) on the Mac and in the
  Keychain on the phone. It is never in source code.
- Speech-to-text runs on the iPhone, so your audio is not uploaded anywhere.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| "Claude CLI is not logged in" | Run `claude` in a Terminal and log in. |
| "Bad signature" | The secret in the app and in `config.toml` do not match exactly. Watch for trailing spaces. |
| "No answer" on Test connection | Listener not running, or phone and Mac are on different Wi-Fi networks. |
| Microphone row stays grey | Glasses are not connected over Bluetooth, or another app is holding the mic. |
| "Address already in use" | The listener is already running in another Terminal window. |

---

## Files

```
ios/VoiceBridge/
  VoiceBridgeApp.swift   app entry, Meta toolkit setup, registration callback
  ContentView.swift      main screen: status, talk button, transcript
  SettingsView.swift     Mac address and shared secret
  VoiceCapture.swift     Bluetooth audio routing + on-device speech-to-text
  GlassesManager.swift   Meta toolkit registration and session
  ListenerClient.swift   signed requests to the Mac
  Speaker.swift          reads replies aloud
  SettingsStore.swift    saved settings
  Keychain.swift         secret storage

listener/
  server.py              the local server, signature checking
  claude_client.py       runs the Claude Code CLI, parses its JSON
  actions.py             the allowed actions
  config.example.toml    template for your config.toml
  run.sh                 starts the listener
```

---

## Contributing

Issues and pull requests are welcome — especially:

- More actions in `listener/actions.py` (media control, window management, notes)
- A Linux or Windows version of the listener
- Better handling of the 8 kHz audio for accuracy

Keep the security model intact: new actions must be explicitly allowlisted, never
constructed from free text.

## Credits and related links

- [Meta Wearables Device Access Toolkit for iOS](https://github.com/facebook/meta-wearables-dat-ios)
- [Wearables Developer Center](https://wearables.developer.meta.com)
- [Claude Code](https://claude.com/claude-code)

## License

MIT — see [LICENSE](LICENSE).
