# pisper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![GitHub stars](https://img.shields.io/github/stars/pis0/pisper?style=social)](https://github.com/pis0/pisper/stargazers)

Global voice-to-text for **macOS**. Hold a key, speak, release — the transcribed text is pasted wherever your cursor is.

**Works where paid alternatives don't** — especially in terminals (Claude Code, Codex, Gemini CLI, iTerm2, Warp, Ghostty, JetBrains), where most dictation tools fail or stutter. Also works everywhere else: editors, browsers, WhatsApp Web, Slack, native prompts. If the app accepts `Cmd+V`, pisper pastes into it.

> **Status:** macOS only. Windows/Linux support is not implemented today. PRs welcome.

## Why it exists

Paid tools like Wispr Flow solve this well, but:

1. They are **closed source** — audio and transcription go through their backend
2. They are **subscription-priced**, even if you already have an OpenAI account
3. Many **don't work in terminals** (or work only with friction)

pisper is the minimum that solves it: **global hold-to-talk**, your own API key, ~200 lines of shell and Lua, zero intermediate cloud other than OpenAI. For a developer who already juggles API keys and doesn't want another subscription, that's the right trade.

### How it compares

|                         | pisper                    | Wispr Flow             | Apple Dictation | Whisper web apps          |
| ----------------------- | ------------------------- | ---------------------- | --------------- | ------------------------- |
| Open source             | ✅ MIT                    | ❌                     | ❌              | varies                    |
| Price                   | Your OpenAI usage (~$1/mo)| Subscription           | Free            | Subscription / per-request|
| Works in terminals      | ✅                        | ⚠️ friction            | ⚠️ limited      | ❌ not system-wide         |
| Stays on your machine   | ✅ (only OpenAI over HTTPS)| ❌ routes via vendor  | ✅              | ❌                        |
| Your own API key        | ✅                        | ❌                     | —               | ❌                        |
| Extra daemon            | None (uses Hammerspoon)   | Custom app             | System          | Custom app / browser      |

## How it works

```
Hammerspoon (macOS daemon)
    │
    ├─ flagsChanged → detects hold/release of the configured key
    │
    ▼
ffmpeg (AVFoundation)
    │
    ├─ records the default mic as 16kHz mono WAV
    │
    ▼
key released
    │
    ▼
curl → OpenAI /v1/audio/transcriptions
    │
    ├─ model: gpt-4o-transcribe (default)
    │
    ▼
pbcopy + osascript (Cmd+V)
    │
    └─ text pasted into the focused app
```

No custom daemon, no compiled binary, no Electron. Everything runs on tools that are already part of the ecosystem (Hammerspoon, ffmpeg, curl, jq, pbcopy, osascript).

## Requirements

- **macOS** (tested on Apple Silicon; Intel should work — `install.sh` looks in `/opt/homebrew/bin` and `/usr/local/bin`)
- **Homebrew** ([brew.sh](https://brew.sh))
- **OpenAI account** with an active API key

## Install

```sh
# 1. Dependencies
brew install --cask hammerspoon
brew install ffmpeg jq

# 2. Clone and install
git clone https://github.com/pis0/pisper.git ~/workspace/virtuware/pisper
cd ~/workspace/virtuware/pisper
./install.sh
```

What `install.sh` does:
- verifies the dependencies
- creates `~/.config/pisper/env` (with `chmod 600`) from `.env.example`
- writes a marker-delimited block into your `~/.hammerspoon/init.lua` (does not overwrite your existing config — only appends between `-- pisper: BEGIN/END` markers)
- reloads Hammerspoon if it's already running

**To uninstall**, remove the block between `-- pisper: BEGIN (auto)` and `-- pisper: END (auto)` in `~/.hammerspoon/init.lua`, delete `~/.config/pisper/`, and reload Hammerspoon.

### Install flags (optional)

`install.sh` accepts a few flags so the entire setup can be done in one non-interactive command — useful when an agent is automating the install for you.

```sh
echo "$OPENAI_KEY" | ./install.sh --api-key-stdin --language pt
```

| Flag | What it does |
|------|---|
| `--api-key-stdin` | Reads `OPENAI_API_KEY` from the first line of stdin and writes it to `~/.config/pisper/env` with `chmod 600`. Takes the token via a pipe or redirect so it never appears in `argv` or shell history. When stdin is a terminal, the script prompts and hides what you type. |
| `--model <name>` | Sets `PISPER_MODEL` (`gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1`). |
| `--language <iso>` | Sets `PISPER_LANGUAGE` to an ISO-639-1 code (`pt`, `en`, `es`, …). Omit to auto-detect. |
| `-h`, `--help` | Show usage. |

> `--api-key sk-...` as a direct argument is **not** supported on purpose — it would leak the token through `ps auxww` and the shell's history file. Use `--api-key-stdin` with a pipe or `<` redirect instead.

The script is idempotent: running it again updates the env in place without duplicating lines or re-injecting the Hammerspoon block. The closing `next steps` output adapts to what's still pending — if the key was written via `--api-key-stdin` and Hammerspoon is already running, the only remaining step is granting the three macOS permissions.

## Configure your API key

Edit `~/.config/pisper/env`:

```sh
OPENAI_API_KEY=sk-your-token-here
# PISPER_MODEL=gpt-4o-transcribe
```

The file is created with `chmod 600` — readable only by you. If you edit it with an editor that writes backup copies (`.swp`, `~`), make sure those don't leak outside that directory.

**Set a hard limit** at [platform.openai.com → Billing → Usage limits](https://platform.openai.com/account/billing/limits). Even for modest use, keeping a monthly cap on a key that lives on your machine is basic hygiene.

## macOS permissions

macOS asks for three separate permissions before this flow works. The first time you hold the key, the system will block and ask you to authorize each one. All of them live under **System Settings → Privacy & Security**.

### 1. Accessibility (required)

**Why:** Hammerspoon needs to inject `Cmd+V` into the focused app via `osascript` / System Events. Without this, the text lands in the clipboard but does not paste.

**Where:** Privacy & Security → Accessibility → enable **Hammerspoon**.

### 2. Input Monitoring (required)

**Why:** the global key-hold detection uses `hs.eventtap`, which needs to observe keyboard events across every app — not only when Hammerspoon is in focus.

**Where:** Privacy & Security → Input Monitoring → enable **Hammerspoon**.

### 3. Microphone (required)

**Why:** `ffmpeg` records via AVFoundation. Because `ffmpeg` runs as a child process of Hammerspoon, macOS asks for permission **on Hammerspoon's behalf**, not on ffmpeg's.

**Where:** Privacy & Security → Microphone → enable **Hammerspoon**.

> If you move Hammerspoon, reinstall it, or upgrade the app — macOS revokes the grants and asks again. Normal.

### When something doesn't work

Most "nothing happens when I hold the key" reports come down to one of these three permissions being missing or revoked. Check them in this order: Input Monitoring → Accessibility → Microphone.

If you suspect macOS is holding bad state (common after a system update or a Hammerspoon upgrade), reset the grants from the terminal and re-authorize:

```sh
tccutil reset Accessibility org.hammerspoon.Hammerspoon
tccutil reset ListenEvent  org.hammerspoon.Hammerspoon
tccutil reset Microphone   org.hammerspoon.Hammerspoon
```

Then relaunch Hammerspoon and hold the key — the system will re-prompt for each permission in turn.

## Usage

Hold the configured key (default: **Right Option**), speak, release. The transcribed text is pasted wherever your cursor is.

Visual feedback:
- **🎤 pisper** → recording in progress
- **⏳ transcribing…** → API call in flight
- **✅** → success, text pasted

A very short tap (< 250ms) is **silently ignored** — that avoids an accidental trigger when you brush the key by reflex. The minimum duration is configurable (`minDuration`).

## Configuration

### Change the hotkey

In `~/.hammerspoon/init.lua`, inside the pisper block:

```lua
pisper.init({
  binPath = '/Users/.../pisper/bin',
  keyCode = 54,  -- Right Command
})
```

KeyCodes for the most useful modifier keys:

| Key            | keyCode        |
|----------------|----------------|
| Right Option   | 61 *(default)* |
| Right Command  | 54             |
| Right Shift    | 60             |
| Right Control  | 62             |
| Fn (globe)     | 63             |

> **Why only modifier keys?** pisper detects the hold via `flagsChanged`, the event macOS fires when a modifier key changes state. Regular keys (letters, F-keys, etc.) don't emit that event. Supporting other keys would require a `keyDown` / `keyUp` tap that intercepts **every** keystroke — not worth the overhead.

To discover the keyCode of any other modifier, open the Hammerspoon Console and paste:

```lua
hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  print(e:getKeyCode()) end):start()
```

Press the key and the code shows up in the console.

### Change the transcription model

In `~/.config/pisper/env`:

```sh
PISPER_MODEL=gpt-4o-transcribe       # default, best quality
# or
PISPER_MODEL=gpt-4o-mini-transcribe  # cheaper
# or
PISPER_MODEL=whisper-1               # legacy, still works
```

Any endpoint compatible with OpenAI's `/v1/audio/transcriptions` should work. To switch **provider** (Groq, local Whisper via `whisper.cpp`, etc.), edit `bin/pisper-stop` — the `curl` call is isolated there.

### Force the transcription language

By default, `gpt-4o-transcribe` auto-detects the language. On short or noisy audio it can occasionally misidentify — a Portuguese clip coming back transcribed as Spanish, or an English phrase getting translated instead of transcribed. To pin the language, set `PISPER_LANGUAGE` in `~/.config/pisper/env`:

```sh
PISPER_LANGUAGE=pt   # Portuguese
# or
PISPER_LANGUAGE=en   # English
# or any other ISO-639-1 code the model supports
```

Leave it unset to auto-detect. Full list of codes: [ISO 639-1](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes).

### Change the minimum duration

Default: 250ms. To change it:

```lua
pisper.init({
  binPath = '/Users/.../pisper/bin',
  minDuration = 0.5,  -- half a second
})
```

## Cost

`gpt-4o-transcribe` is roughly **$0.006/min** of transcribed audio. Typical dictation usage (~10 min/day, 20 business days) ≈ **$1.20/month**.

`gpt-4o-mini-transcribe` is substantially cheaper. `whisper-1` (legacy) is cheaper too.

Setting a monthly cap at [platform.openai.com/account/billing/limits](https://platform.openai.com/account/billing/limits) is a good idea. Ten dollars/month is already way more than any realistic usage.

## Troubleshooting

### Hammerspoon doesn't react when I hold the key

In order:
1. Is Hammerspoon running? `pgrep -x Hammerspoon` — if it doesn't return a PID, launch it: `open -a Hammerspoon`
2. Is **Input Monitoring** enabled for Hammerspoon? (most common cause)
3. Is **Accessibility** enabled? (recording starts but the paste fails)
4. Is another app capturing the same key? Try a different one (e.g. Right Command = keyCode 54)
5. Does the Hammerspoon Console (menu bar → Console) show an error?

### ffmpeg doesn't record / "Input/output error"

- Is **Microphone** enabled for Hammerspoon?
- Test manually in the terminal:
  ```sh
  ffmpeg -f avfoundation -i ":default" -t 2 /tmp/test.wav && afplay /tmp/test.wav
  ```
- If you have multiple inputs (external mic, audio interface), `:default` may not be the right one. List devices:
  ```sh
  ffmpeg -f avfoundation -list_devices true -i ""
  ```
  Then edit `bin/pisper-record` to point at the right index (e.g. `-i ":1"`).

### Transcription comes back in English when I spoke Portuguese (or vice versa)

`gpt-4o-transcribe` detects the language automatically, but it can guess wrong on short or noisy audio. Pin the language via `PISPER_LANGUAGE` in `~/.config/pisper/env` — see [Force the transcription language](#force-the-transcription-language) above.

### Cmd+V doesn't paste in a specific app

Some apps (full-screen games, apps that implement paste via their own custom events) ignore the synthetic keystroke. Fallback: the text **is already in the clipboard** — a manual `Cmd+V` pastes normally.

### Quota exceeded / 429 from OpenAI

Check [platform.openai.com/usage](https://platform.openai.com/usage). If it's your own cap, raise it; if it's a tier rate limit, wait a few minutes.

### Reinstall from scratch

```sh
# Manually remove the pisper block from init.lua
# (between -- pisper: BEGIN and -- pisper: END)

# Clean config and temp
rm -rf ~/.config/pisper
rm -rf "${TMPDIR:-/tmp}/pisper"

# Reset permissions if you want
tccutil reset Accessibility org.hammerspoon.Hammerspoon
tccutil reset ListenEvent  org.hammerspoon.Hammerspoon
tccutil reset Microphone   org.hammerspoon.Hammerspoon

# Reinstall
cd ~/workspace/virtuware/pisper
./install.sh
```

## Layout

```
pisper/
├── bin/
│   ├── pisper-record    # spawns ffmpeg in the background to record
│   ├── pisper-stop      # ends ffmpeg, transcribes, pastes
│   └── pisper-cancel    # aborts a recording without transcribing
├── hammerspoon/
│   └── pisper.lua       # module that detects the hold and invokes the scripts
├── install.sh           # wires pisper into ~/.hammerspoon/init.lua
├── .env.example         # template for ~/.config/pisper/env
└── README.md
```

## Security

- `~/.config/pisper/env` is created with `chmod 600` by `install.sh`
- macOS's `$TMPDIR` (used for the temporary WAVs) is already per-user — it's not shared `/tmp`
- PID files, audio, and temporary logs live in `$TMPDIR/pisper/` with `umask 077`
- The last audio sent to the API is kept in `$TMPDIR/pisper/last.wav` for debugging — overwritten each session. If that bothers you, comment out the `cp "$AUDIO_FILE" "$PISPER_TMP/last.wav"` line in `bin/pisper-stop`.
- The OpenAI auth header goes to curl via a `chmod 600` file (`-H "@file"`) so the token never reaches `argv`, where other local processes could read it with `ps`.
- Your OpenAI key **never leaves your machine** except to go to OpenAI's endpoint over HTTPS. No proxy, no telemetry.

## License

MIT — see [LICENSE](./LICENSE).

## Credits

Built on top of people much smarter than me:
- [Hammerspoon](https://www.hammerspoon.org/) — all the global-hook magic
- [ffmpeg](https://ffmpeg.org/) — audio capture
- [OpenAI](https://platform.openai.com/docs/guides/speech-to-text) — transcription
