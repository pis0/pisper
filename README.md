# pisper

Voice-to-text global pra macOS — segure uma tecla, fale, solte, e o texto é colado no app em foco.

Funciona em qualquer terminal (Claude Code, Codex, Gemini CLI, iTerm2, Terminal JetBrains, Ghostty, Warp…) e qualquer app que aceite `Cmd+V`.

## Como funciona

```
Hammerspoon (macOS daemon)  →  detecta hold da tecla configurada
         ↓
ffmpeg  →  grava mic via AVFoundation
         ↓
soltou a tecla
         ↓
curl  →  POST /v1/audio/transcriptions (OpenAI Whisper)
         ↓
pbcopy + osascript Cmd+V  →  cola no app em foco
```

## Pré-requisitos

```sh
brew install --cask hammerspoon
brew install ffmpeg jq
```

## Instalação

```sh
git clone <repo> ~/workspace/virtuware/pisper
cd ~/workspace/virtuware/pisper
./install.sh
```

Depois:

1. Edite `~/.config/pisper/env` e preencha `OPENAI_API_KEY`.
2. Abra o Hammerspoon (primeira vez): `open -a Hammerspoon`.
3. Conceda permissões quando pedido:
   - **Accessibility** (pra ler o hold da tecla e disparar `Cmd+V`)
   - **Microphone** (pro ffmpeg gravar)
   - **Input Monitoring** (pro eventtap funcionar)

## Uso

Segure a tecla configurada (padrão: **Right Option**), fale, solte. O texto transcrito é colado onde o cursor estiver.

- Click muito rápido (< 250ms) cancela silenciosamente — evita disparo acidental.
- Alert "🎤 pisper" indica gravação ativa.
- Alert "⏳ transcrevendo…" indica chamada à API.
- Alert "✅" indica sucesso (texto colado).

## Configuração

### Trocar a tecla de ativação

Em `~/.hammerspoon/init.lua`, passe `keyCode` pro `pisper.init`:

```lua
pisper.init({
  binPath = '/Users/.../pisper/bin',
  keyCode = 54,  -- Right Command
})
```

KeyCodes comuns:

| Tecla | keyCode |
|-------|---------|
| Right Option | 61 *(padrão)* |
| Right Command | 54 |
| Right Shift | 60 |
| Right Control | 62 |
| Fn (globo) | 63 |
| F19 | 80 |

Descobrir keyCode de qualquer tecla: abra o console do Hammerspoon e rode:
```lua
hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  print(e:getKeyCode()) end):start()
```

### Trocar o modelo de transcrição

Em `~/.config/pisper/env`:

```sh
PISPER_MODEL=gpt-4o-mini-transcribe  # mais barato
# ou
PISPER_MODEL=whisper-1               # legacy
```

## Custo

`gpt-4o-transcribe` custa ~$0.006/min. Uso típico de ditado (~10 min/dia) = ~$1.80/mês.

Coloque um hard limit em platform.openai.com → Billing → Usage limits.

## Troubleshooting

**Hammerspoon não reage à tecla**
- Permissões: System Settings → Privacy & Security → Accessibility / Input Monitoring → Hammerspoon ativado.
- Tente outra tecla que não conflita com outro app (Alt+Tab no macOS? Etc).

**ffmpeg: "Input/output error" ou não grava**
- Permissões: System Settings → Privacy & Security → Microphone → Terminal / Hammerspoon / etc.
- Teste manualmente: `ffmpeg -f avfoundation -i ":default" -t 2 /tmp/test.wav`

**Transcrição retorna texto errado em português**
- `gpt-4o-transcribe` detecta idioma automaticamente. Se erra muito, dá pra passar `-F "language=pt"` no curl (editar `bin/pisper-stop`).

**Cmd+V não cola em app específico**
- Alguns apps capturam paste de forma customizada. Fallback manual: o texto já está no clipboard, use `Cmd+V` normalmente.

## Layout

```
pisper/
├── bin/
│   ├── pisper-record    # inicia gravação
│   ├── pisper-stop      # encerra + transcreve + cola
│   └── pisper-cancel    # aborta (click curto)
├── hammerspoon/
│   └── pisper.lua       # módulo que detecta hold e invoca os scripts
├── install.sh           # integra ao ~/.hammerspoon/init.lua
├── .env.example         # template do ~/.config/pisper/env
└── README.md
```
