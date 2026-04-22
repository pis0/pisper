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
  warn "edit it and set your OPENAI_API_KEY before use"
else
  ok "config exists at $CONFIG_ENV"
fi
# Sempre reforça chmod — se o arquivo existia com permissão aberta, a key estava exposta.
chmod 600 "$CONFIG_ENV"

# 4. hook into Hammerspoon init.lua
mkdir -p "$HS_DIR"
touch "$HS_INIT"

marker_begin="-- pisper: BEGIN (auto)"
marker_end="-- pisper: END (auto)"

if grep -q "$marker_begin" "$HS_INIT" 2>/dev/null; then
  ok "pisper already registered in $HS_INIT"
else
  # Usa long bracket [===[...]===] pra string Lua — não interpreta aspas/escapes no path.
  {
    echo ""
    echo "$marker_begin"
    echo "package.path = package.path .. [===[;$PISPER_DIR/hammerspoon/?.lua]===]"
    echo "local pisper = require('pisper')"
    echo "pisper.init({"
    echo "  binPath = [===[$PISPER_DIR/bin]===],"
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

say ""
say "${bold}next steps${reset}"
say "  1. edit $CONFIG_ENV and set OPENAI_API_KEY"
say "  2. launch Hammerspoon (if not running): open -a Hammerspoon"
say "  3. grant permissions: Accessibility + Microphone + Input Monitoring"
say "  4. test: hold ${bold}Right Option${reset}, speak, release — text is pasted at the cursor"
