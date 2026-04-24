#!/usr/bin/env bash
# pisper install: wires the Lua module into Hammerspoon and sets up user config.
set -euo pipefail

PISPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"
CONFIG_DIR="$HOME/.config/pisper"
CONFIG_ENV="$CONFIG_DIR/env"

bold=$'\033[1m'
green=$'\033[32m'
yellow=$'\033[33m'
red=$'\033[31m'
reset=$'\033[0m'

say() { printf '%s\n' "$*"; }
ok()  { printf '%b✓%b %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%b!%b %s\n' "$yellow" "$reset" "$*"; }
err() { printf '%b✗%b %s\n' "$red" "$reset" "$*" >&2; }

print_help() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Set up pisper on this machine. Validates dependencies, creates the user
config at ~/.config/pisper/env, and wires the Lua module into Hammerspoon's
init.lua. Running it again is safe — idempotent via marker block and env
rewrite.

Options:
  --api-key-stdin       Read OPENAI_API_KEY from stdin (first line) and
                        write it to ~/.config/pisper/env. Keeps the token
                        out of argv and shell history — use this for
                        scripted installs. When stdin is a terminal, the
                        prompt hides what you type.
                        Examples:
                          echo "$KEY" | ./install.sh --api-key-stdin
                          ./install.sh --api-key-stdin < key.txt
                          ./install.sh --api-key-stdin   # prompts (hidden)
  --model <name>        Set PISPER_MODEL. Options:
                          gpt-4o-transcribe (default if unset)
                          gpt-4o-mini-transcribe
                          whisper-1
  --language <iso>      Set PISPER_LANGUAGE — pin the transcription
                        language as an ISO-639-1 code (pt, en, es, fr, …).
                        Omit to let the model auto-detect.
  -h, --help            Show this help and exit.

With no flags the script still wires up Hammerspoon and leaves the env
file for you to fill in manually. The flags exist so agents automating
an install can skip the manual edit step without placing the API key
in argv.

Examples:
  ./install.sh
  echo "$OPENAI_KEY" | ./install.sh --api-key-stdin --language pt
  ./install.sh --model gpt-4o-mini-transcribe --language en
EOF
}

OPT_API_KEY=""
OPT_READ_STDIN=0
OPT_MODEL=""
OPT_LANGUAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key-stdin)
      OPT_READ_STDIN=1; shift ;;
    --model)
      [[ -n "${2:-}" ]] || { err "--model requires a value"; exit 2; }
      OPT_MODEL="$2"; shift 2 ;;
    --model=*)
      OPT_MODEL="${1#*=}"; shift ;;
    --language)
      [[ -n "${2:-}" ]] || { err "--language requires a value"; exit 2; }
      OPT_LANGUAGE="$2"; shift 2 ;;
    --language=*)
      OPT_LANGUAGE="${1#*=}"; shift ;;
    -h|--help)
      print_help; exit 0 ;;
    --api-key|--api-key=*)
      # Refuse the old argv-visible form. ps auxww and shell history would
      # leak the token. Redirect users to --api-key-stdin instead.
      err "--api-key is not supported (would leak via argv / shell history)"
      err "use --api-key-stdin and pipe the key: echo \"\$KEY\" | ./install.sh --api-key-stdin"
      exit 2 ;;
    *)
      err "unknown option: $1 (try --help)"; exit 2 ;;
  esac
done

# Read the API key from stdin if requested. Hide input when stdin is a TTY
# (interactive user typing), plain read when it's a pipe/redirect (agent).
if [[ $OPT_READ_STDIN -eq 1 ]]; then
  if [[ -t 0 ]]; then
    printf 'Paste OPENAI_API_KEY (input hidden): '
    IFS= read -rs OPT_API_KEY || true
    printf '\n'
  else
    IFS= read -r OPT_API_KEY || true
  fi
  if [[ -z "$OPT_API_KEY" ]]; then
    err "--api-key-stdin: no key read from stdin"
    exit 2
  fi
fi

# Idempotent env edit: strip any existing uncommented lines for $key, then
# append $key=$value. Commented documentation in .env.example is preserved.
set_env_var() {
  local key="$1" value="$2" file="$3"
  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  chmod 600 "$tmp"
  # grep -v returns non-zero when every line matches — tolerate that.
  grep -v -E "^[[:space:]]*${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

say "${bold}pisper install${reset}"
say "  project: $PISPER_DIR"

# 1. base deps
for cmd in ffmpeg jq pbcopy osascript; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd not found in PATH"
    case "$cmd" in
      ffmpeg) echo "  → brew install ffmpeg" ;;
      jq)     echo "  → brew install jq" ;;
    esac
    exit 1
  fi
done
ok "shell deps ok (ffmpeg, jq, pbcopy, osascript)"

# 2. Hammerspoon installed
if ! [[ -d "/Applications/Hammerspoon.app" ]]; then
  err "Hammerspoon not found in /Applications"
  echo "  → brew install --cask hammerspoon"
  exit 1
fi
ok "Hammerspoon installed"

# 3. user config
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
if [[ ! -f "$CONFIG_ENV" ]]; then
  cp "$PISPER_DIR/.env.example" "$CONFIG_ENV"
  warn "config created at $CONFIG_ENV"
else
  ok "config exists at $CONFIG_ENV"
fi
# Always reassert chmod — if the file already existed with a loose mode, the key was exposed.
chmod 600 "$CONFIG_ENV"

# Apply any values passed via flags. We intentionally skip echoing the key
# value itself (it's a secret) — just confirm it was written.
if [[ -n "$OPT_API_KEY" ]]; then
  set_env_var "OPENAI_API_KEY" "$OPT_API_KEY" "$CONFIG_ENV"
  ok "OPENAI_API_KEY written to $CONFIG_ENV"
fi
if [[ -n "$OPT_MODEL" ]]; then
  set_env_var "PISPER_MODEL" "$OPT_MODEL" "$CONFIG_ENV"
  ok "PISPER_MODEL=$OPT_MODEL"
fi
if [[ -n "$OPT_LANGUAGE" ]]; then
  set_env_var "PISPER_LANGUAGE" "$OPT_LANGUAGE" "$CONFIG_ENV"
  ok "PISPER_LANGUAGE=$OPT_LANGUAGE"
fi

# 4. hook into Hammerspoon init.lua
mkdir -p "$HS_DIR"
touch "$HS_INIT"

marker_begin="-- pisper: BEGIN (auto)"
marker_end="-- pisper: END (auto)"

if grep -q "$marker_begin" "$HS_INIT" 2>/dev/null; then
  ok "pisper already registered in $HS_INIT"
else
  # Embed $PISPER_DIR as a Lua double-quoted string with proper escaping.
  # Long-bracket literals ([===[...]===]) looked safer but are defeated by a
  # path containing the matching closing delimiter — an attacker-controlled
  # clone target could break out of the literal and inject arbitrary Lua that
  # runs inside Hammerspoon. Double-quoted Lua strings with backslash/quote
  # escaping remove that class of attack entirely.
  lua_dq_escape() {
    local s="$1"
    s="${s//\\/\\\\}"         # \  -> \\
    s="${s//\"/\\\"}"         # "  -> \"
    s="${s//$'\n'/\\n}"       # LF -> \n  (literal newlines in a double-quoted
    s="${s//$'\r'/\\r}"       # CR -> \r   Lua string split it into two lines,
                              # which would let a crafted path with \n + Lua
                              # payload inject statements onto the next line.
    printf '%s' "$s"
  }

  escaped_dir=$(lua_dq_escape "$PISPER_DIR")
  {
    echo ""
    echo "$marker_begin"
    echo "package.path = package.path .. \";${escaped_dir}/hammerspoon/?.lua\""
    echo "local pisper = require('pisper')"
    echo "pisper.init({"
    echo "  binPath = \"${escaped_dir}/bin\","
    echo "  -- default keyCode: 61 (Right Option). See pisper.lua for other options."
    echo "})"
    echo "$marker_end"
  } >> "$HS_INIT"
  ok "added to $HS_INIT"
fi

# 5. reload Hammerspoon if it's running
if pgrep -qx Hammerspoon; then
  osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' \
    >/dev/null 2>&1 && ok "Hammerspoon reloaded" \
    || warn "Hammerspoon is running but didn't respond — reload it manually"
else
  warn "Hammerspoon is not running — launch it to activate pisper"
  say  "  → open -a Hammerspoon"
fi

# Dynamic next steps: skip the ones that are already satisfied so the output
# reflects what the user actually still has to do. Agents reading this output
# can relay only the remaining work.
say ""
say "${bold}next steps${reset}"
n=0
# Key is considered "set" if there's an OPENAI_API_KEY= line starting with sk-
# followed by plausible key characters. The placeholder sk-... from .env.example
# would not match — we want the real one.
if ! grep -qE '^[[:space:]]*OPENAI_API_KEY=sk-[A-Za-z0-9_-]{20,}' "$CONFIG_ENV" 2>/dev/null; then
  n=$((n+1))
  say "  $n. edit $CONFIG_ENV and set OPENAI_API_KEY (or re-run with --api-key sk-...)"
fi
if ! pgrep -qx Hammerspoon; then
  n=$((n+1))
  say "  $n. launch Hammerspoon: open -a Hammerspoon"
fi
n=$((n+1))
say "  $n. grant macOS permissions to Hammerspoon (System Settings → Privacy & Security):"
say "      Accessibility, Input Monitoring, Microphone"
n=$((n+1))
say "  $n. test: hold ${bold}Right Option${reset}, speak, release — text is pasted at the cursor"
