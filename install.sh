#!/usr/bin/env bash
# pisper install: integra o módulo ao Hammerspoon e cria config do usuário.
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
say "  projeto: $PISPER_DIR"

# 1. deps básicas
for cmd in ffmpeg jq pbcopy osascript; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd não encontrado no PATH"
    case "$cmd" in
      ffmpeg) echo "  → brew install ffmpeg" ;;
      jq)     echo "  → brew install jq" ;;
    esac
    exit 1
  fi
done
ok "dependências de shell ok (ffmpeg, jq, pbcopy, osascript)"

# 2. Hammerspoon instalado
if ! [[ -d "/Applications/Hammerspoon.app" ]]; then
  err "Hammerspoon não encontrado em /Applications"
  echo "  → brew install --cask hammerspoon"
  exit 1
fi
ok "Hammerspoon instalado"

# 3. config do usuário
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_ENV" ]]; then
  cp "$PISPER_DIR/.env.example" "$CONFIG_ENV"
  chmod 600 "$CONFIG_ENV"
  warn "config criado em $CONFIG_ENV"
  warn "edite e coloque sua OPENAI_API_KEY antes de usar"
else
  ok "config existe em $CONFIG_ENV"
fi

# 4. integração com Hammerspoon init.lua
mkdir -p "$HS_DIR"
touch "$HS_INIT"

marker_begin="-- pisper: BEGIN (auto)"
marker_end="-- pisper: END (auto)"

if grep -q "$marker_begin" "$HS_INIT" 2>/dev/null; then
  ok "pisper já registrado em $HS_INIT"
else
  {
    echo ""
    echo "$marker_begin"
    echo "package.path = package.path .. ';$PISPER_DIR/hammerspoon/?.lua'"
    echo "local pisper = require('pisper')"
    echo "pisper.init({"
    echo "  binPath = '$PISPER_DIR/bin',"
    echo "  -- keyCode padrão: 61 (Right Option). Veja pisper.lua para outras opções."
    echo "})"
    echo "$marker_end"
  } >> "$HS_INIT"
  ok "adicionado ao $HS_INIT"
fi

# 5. recarrega Hammerspoon se estiver rodando
if pgrep -qx Hammerspoon; then
  osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' \
    >/dev/null 2>&1 && ok "Hammerspoon recarregado" \
    || warn "Hammerspoon está rodando mas não respondeu — recarregue manualmente"
else
  warn "Hammerspoon não está rodando — abra ele pra ativar o pisper"
  say  "  → open -a Hammerspoon"
fi

say ""
say "${bold}próximos passos${reset}"
say "  1. edite $CONFIG_ENV e preencha OPENAI_API_KEY"
say "  2. abra Hammerspoon (se ainda não está rodando): open -a Hammerspoon"
say "  3. conceda permissões: Accessibility + Microphone + Input Monitoring"
say "  4. teste: segure ${bold}Right Option${reset}, fale, solte — o texto aparece no foco"
