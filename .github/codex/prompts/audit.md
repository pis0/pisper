You are a senior auditor running the **first full audit** of **pisper** — a personal global voice-to-text tool for macOS.

This is NOT a diff-scoped code review. Sweep **every file in the repository** (except `.git/`, `.github/`, and generated artifacts). Treat the project as if you had just inherited it and wanted to know the shape it is in before turning it on for real daily use.

## What pisper is

Global hold-to-talk for macOS: the user holds a modifier key (Right Option by default), speaks, releases, and the transcribed text is pasted into the focused app via `Cmd+V`.

```
Hammerspoon (macOS daemon, Lua)
    └─ flagsChanged eventtap detects hold of the configured keyCode
        ├─ keyDown  → hs.task.new → bin/pisper-record   (ffmpeg AVFoundation → 16kHz mono wav)
        ├─ keyUp    → hs.task.new → bin/pisper-stop     (kill ffmpeg → silence-remove → OpenAI /v1/audio/transcriptions → pbcopy → osascript Cmd+V)
        └─ short click (< minDuration) → hs.task.new → bin/pisper-cancel (kill ffmpeg + rm wav)
```

Stack:
- **Lua** in `hammerspoon/pisper.lua` — hold-to-talk state machine, alerts, async spawn
- **Bash** in `bin/pisper-{record,stop,cancel}` — all with `set -euo pipefail`
- **ffmpeg** via `-f avfoundation -i ":default"`; `silenceremove` before the API call
- **OpenAI API** — `gpt-4o-transcribe` (configurable) at `POST /v1/audio/transcriptions`. API key in `~/.config/pisper/env` (chmod 600)
- **pbcopy + osascript** for the paste (LANG/LC_ALL forced to UTF-8)
- **install.sh** — writes a marker-delimited block into `~/.hammerspoon/init.lua`

Runtime state lives in `$TMPDIR/pisper/` (per-user).

## Audit scope

I want an honest picture of the project across the following dimensions. **Prioritize by real impact.** Don't invent problems just to fill a finding slot; if a dimension is solid, say so in `overall_explanation`.

### 1. Security

- **Shell injection & quoting**: is every interpolated shell arg double-quoted? Do paths containing spaces, quotes, or `$` break anything? `$PISPER_DIR` in `install.sh` is derived from the clone directory — if the user clones into an exotic path, does the injected `init.lua` block become invalid Lua or worse?
- **API key leaks**: can `OPENAI_API_KEY` leak via stderr, stdout, or logs? The `log_err` call in `pisper-stop` — if curl echoes error headers, can the key show up? Would `set -x` during debugging leak it? Is the chmod 600 on the env file sufficient?
- **osascript injection**: today `Cmd+V` is hardcoded (safe). Is there any path where a user-controlled string gets interpolated into AppleScript?
- **PID file without identity check**: `kill "$old_pid"` after reading a pid file — race between the `kill -0` probe and the real `kill`. Worst case, we signal an unrelated system process with a recycled PID. Current mitigation uses `ps -o lstart=` fingerprint plus argv match — only flag a real bypass.
- **Temp files in `$TMPDIR/pisper/`**: per-user, umask 077. Good. Is there any code path that writes audio or secrets outside that directory?
- **`source "$ENV_FILE"`**: arbitrary shell code in the env file is executed. Is there any path where an env file of untrusted origin could be installed or updated?
- **curl without timeout**: a request could hang indefinitely without `--max-time`. Not security-critical but a robustness concern.

### 2. Functional correctness

- **Hold-to-talk state machine** in `pisper.lua`:
  - ffmpeg fails inside `startRecording` — does state get rolled back correctly?
  - Two consecutive `keyDown` events (macOS or keyboard glitch).
  - Hammerspoon reload mid-recording — is any ffmpeg orphan cleaned up?
  - Late `hs.task` callback firing after the user already started a new session.
- **Bash script races**:
  - `pisper-record` and `pisper-stop` running concurrently on a fast hold+release.
  - The `sleep 0.1` after `kill` — could ffmpeg still hold the wav?
  - `pisper-stop` waits up to 500ms for ffmpeg to finalize (`SIGINT` → 10x50ms → `SIGTERM`). On a slow mic, is that enough?
- **Empty / malformed API response**: `jq '.text // empty'` falls to empty, but does the entire `response` get echoed into `log_err` if the API returns `{"error": {...}}`? Is that acceptable?
- **`silenceremove` produces an empty file**: does the `[[ -s "$TRIMMED" ]]` fallback cover that? Is `ffmpeg exit 0 + empty file` plausible?
- **keyCode vs flag mapping** in `pisper.lua`: if the user configures an unmapped keyCode, is the fallback behavior sensible or will the recording never start?
- **`recordingStartedAt = nil` edge case**: could `stopRecording` ever run with `recordingStartedAt` nil, producing a huge `elapsed` that bypasses `minDuration`?

### 3. macOS robustness

- **TCC permissions** (Accessibility, Input Monitoring, Microphone): without them, the app silently fails. Does the onboarding UX cover this? `install.sh` only prints a note — is that enough?
- **Audio device switching mid-recording** (Bluetooth disconnect, etc): can ffmpeg hang?
- **PATH in non-interactive shells**: Hammerspoon spawns shells without `.zshrc`. Every script exports PATH with brew paths (ARM + Intel). OK today, but any new dependency would need this too.
- **UTF-8**: `LANG/LC_ALL=en_US.UTF-8` in `pisper-stop` is mandatory before `pbcopy`. `pisper-record` has it (for consistency), `pisper-cancel` does not — does that matter?
- **ARM vs Intel**: both `/opt/homebrew/bin` and `/usr/local/bin` in PATH — OK.
- **macOS versions**: Hammerspoon 1.x, `hs.eventtap`, `hs.task` — which macOS versions are supported? `install.sh` doesn't check.

### 4. Code / structure

- **`pisper.lua`** — singleton module (`local M = {}`); is `init` idempotent if called twice? Does it leak the old eventtap?
- **`hs.task.new` callback signature**: `function(exitCode, stdout, stderr)` — can stdout/stderr arrive as nil? (checked in the code — handled.)
- **Bash scripts**: duplicated `export PATH` / `LANG` across scripts — extracting a `bin/_common.sh` would be cleaner but adds complexity. Judge the trade-off.
- **Env var names**: `PISPER_TMP`, `PISPER_ENV_FILE`, `PISPER_MODEL` — consistent, good.
- **Dead code / unused**: anything in the repo that is not referenced by anything else?

### 5. UX

- **`hs.alert` alerts**: `closeAll` before every alert avoids stacking, but it also wipes out any alert coming from another Hammerspoon module. Does that collide with other tools the user might have configured?
- **Error messages**: actionable (do they tell the user what to do) or generic?
- **Very short click (< 250ms)** cancels silently — good default.
- **`README.md`**: complete? Does the troubleshooting cover the real-world cases?

### 6. Operation / maintenance

- **Versioning**: no `VERSION` file. Tags follow semver (the release workflow keys off `v*` tags — is that mentioned in the README?).
- **Audio backups** at `$PISPER_TMP/last.wav`: grows without cleanup, just overwritten on each use. Under heavy use, can `/tmp` fill up? Acceptable?
- **Observability**: `LOG_FILE="$PISPER_TMP/record.log"` is written but nothing reads it. Is rotation a concern?
- **install.sh idempotency**: marker-based injection avoids duplicates. No uninstall exists — acceptable for v1?

## Response format

- List findings ordered by priority (1=HIGH first).
- Each finding: `title`, `body` (explanation + concrete suggestion), `priority` (1-3), `confidence_score` (0.0-1.0), `code_location` (filepath + line range).
- `overall_correctness`: "patch is correct" if the project is healthy enough to ship for personal daily use; "patch is incorrect" if there's a real bug or vuln that should be fixed before depending on it.
- `overall_explanation`: summary — the overall state, strengths, main concerns.
- `overall_confidence_score`: how confident you are in the verdict.

## Rules

- Only actionable findings with concrete suggestions. No vague "consider adding tests".
- Cite filepath + line range on every finding.
- This is a **personal project** — don't compare it to enterprise baselines (no heavyweight CI/CD, no monitoring, no observability stack). Judge it by its purpose: a daily-use tool for the author.
- Don't ask for comments, docstrings, or type annotations unless something is genuinely confusing.
- Don't nitpick on style.
- If the project is in good shape, return `findings: []` and explain in `overall_explanation`. **Don't invent problems.**
- Respond in **English**.
