# pisper

Voice-to-text global para **macOS**. Segure uma tecla, fale, solte — o texto transcrito é colado onde o cursor estiver.

Funciona em qualquer app: terminais (Claude Code, Codex, Gemini CLI, iTerm2, Warp, Ghostty, Terminal do JetBrains), editores, navegador, WhatsApp Web, Slack, prompts nativos — se o app aceita `Cmd+V`, o pisper cola.

> **Status:** macOS only. Suporte a Windows/Linux não está implementado hoje. PRs são bem-vindos.

<!-- TODO: adicionar demo.gif aqui mostrando o hold → fala → paste em um terminal -->

## Por que existe

Ferramentas pagas tipo Wispr Flow resolvem isso muito bem, mas:

1. São **closed source** — áudio e transcrição passam pelo backend delas
2. São **pagas por assinatura**, mesmo que você já tenha uma conta OpenAI
3. Muitas **não funcionam em terminal** (ou funcionam com fricção)

O pisper é o mínimo que resolve: **hold-to-talk global**, sua própria API key, ~200 linhas de shell e Lua, zero cloud intermediária além da OpenAI. Pra dev que já mexe com API key e não quer mais uma assinatura, faz sentido.

## Como funciona

```
Hammerspoon (daemon macOS)
    │
    ├─ flagsChanged → detecta hold/release da tecla configurada
    │
    ▼
ffmpeg (AVFoundation)
    │
    ├─ grava o mic default em 16kHz mono WAV
    │
    ▼
soltou a tecla
    │
    ▼
curl → OpenAI /v1/audio/transcriptions
    │
    ├─ model: gpt-4o-transcribe (default)
    │
    ▼
pbcopy + osascript (Cmd+V)
    │
    └─ texto colado no app em foco
```

Nenhum daemon custom, nenhum binário compilado, nenhum Electron. Tudo roda em cima de ferramentas que já estão no ecossistema (Hammerspoon, ffmpeg, curl, jq, pbcopy, osascript).

## Pré-requisitos

- **macOS** (testado em Apple Silicon; Intel deve funcionar — `install.sh` busca em `/opt/homebrew/bin` e `/usr/local/bin`)
- **Homebrew** ([brew.sh](https://brew.sh))
- **Conta OpenAI** com uma API key ativa

## Instalação

```sh
# 1. Dependências
brew install --cask hammerspoon
brew install ffmpeg jq

# 2. Clone e instale
git clone https://github.com/pis0/pisper.git ~/workspace/virtuware/pisper
cd ~/workspace/virtuware/pisper
./install.sh
```

O `install.sh`:
- valida as dependências
- cria `~/.config/pisper/env` (com `chmod 600`) a partir do `.env.example`
- injeta um bloco marcado no seu `~/.hammerspoon/init.lua` (não sobrescreve config existente — só adiciona entre marcadores `-- pisper: BEGIN/END`)
- recarrega o Hammerspoon se já estiver rodando

**Desinstalar** é remover o bloco entre `-- pisper: BEGIN (auto)` e `-- pisper: END (auto)` do `~/.hammerspoon/init.lua`, remover `~/.config/pisper/`, e recarregar o Hammerspoon.

## Configurar sua API key

Edite `~/.config/pisper/env`:

```sh
OPENAI_API_KEY=sk-seu-token-aqui
# PISPER_MODEL=gpt-4o-transcribe
```

O arquivo é criado com `chmod 600` — só seu usuário lê. Se editar com editor que gera backup (`.swp`, `~`), confirme que eles não vazam fora desse diretório.

**Coloque um hard limit** em [platform.openai.com → Billing → Usage limits](https://platform.openai.com/account/billing/limits). Mesmo com uso modesto, é higiene básica ter um teto mensal pra key que fica na sua máquina.

## Permissões do macOS

O macOS pede três permissões separadas pra esse fluxo funcionar. Na primeira vez que você segurar a tecla, o sistema vai bloquear e pedir pra autorizar cada uma. Todas se habilitam em **Ajustes do Sistema → Privacidade e Segurança**.

### 1. Acessibilidade (obrigatória)

**Por quê:** o Hammerspoon precisa injetar `Cmd+V` via `osascript`/System Events no app em foco. Sem isso, o texto fica no clipboard mas não é colado.

**Onde:** Privacidade e Segurança → Acessibilidade → habilite **Hammerspoon**.

### 2. Monitoramento de Entrada (obrigatória)

**Por quê:** o hold global da tecla é detectado via `hs.eventtap` — o Hammerspoon precisa "ouvir" eventos de teclado em qualquer app, não só quando ele está em foco.

**Onde:** Privacidade e Segurança → Monitoramento de Entrada → habilite **Hammerspoon**.

### 3. Microfone (obrigatória)

**Por quê:** o `ffmpeg` grava via AVFoundation. Como o `ffmpeg` é processo filho do Hammerspoon, o macOS pede permissão **pro Hammerspoon**, não pro ffmpeg isolado.

**Onde:** Privacidade e Segurança → Microfone → habilite **Hammerspoon**.

> Se você trocar o Hammerspoon de lugar, reinstalar, ou atualizar o app — o macOS revoga e pede de novo. Normal.

### Quando algo não funciona

A maior parte dos problemas de "não acontece nada ao segurar a tecla" é uma dessas três permissões faltando ou revogada. Checar nessa ordem: Monitoramento de Entrada → Acessibilidade → Microfone.

Se suspeitar que o macOS guardou estado ruim (típico após update do sistema ou do Hammerspoon), resetar as permissões via Terminal e reconceder resolve:

```sh
tccutil reset Accessibility org.hammerspoon.Hammerspoon
tccutil reset ListenEvent  org.hammerspoon.Hammerspoon
tccutil reset Microphone   org.hammerspoon.Hammerspoon
```

Depois, abra o Hammerspoon de novo e segure a tecla — o sistema vai pedir cada permissão na sequência.

## Uso

Segure a tecla configurada (padrão: **Right Option**), fale, solte. O texto transcrito é colado onde o cursor estiver.

Feedback visual:
- **🎤 pisper** → gravação ativa
- **⏳ transcribing…** → chamada à API em andamento
- **✅** → sucesso, texto colado

Toque muito rápido (< 250ms) é **ignorado silenciosamente** — evita disparo acidental quando você encosta na tecla por reflexo. A duração mínima é configurável (`minDuration`).

## Configuração

### Trocar a tecla de ativação

Em `~/.hammerspoon/init.lua`, dentro do bloco do pisper:

```lua
pisper.init({
  binPath = '/Users/.../pisper/bin',
  keyCode = 54,  -- Right Command
})
```

KeyCodes das teclas modificadoras mais úteis:

| Tecla          | keyCode |
|----------------|---------|
| Right Option   | 61 *(padrão)* |
| Right Command  | 54      |
| Right Shift    | 60      |
| Right Control  | 62      |
| Fn (globo)     | 63      |

> **Por que só modificadoras?** O pisper detecta hold via `flagsChanged`, que é o evento que o macOS emite quando uma tecla modificadora muda de estado. Teclas regulares (letras, F-keys, etc.) não disparam esse evento. Suporte a outras teclas exigiria um `keyDown`/`keyUp` tap, que intercepta **todo** teclado digitado — overhead que não vale.

Pra descobrir o keyCode de qualquer outra modificadora, abra o Console do Hammerspoon e cole:

```lua
hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  print(e:getKeyCode()) end):start()
```

Aperte a tecla e o código aparece no console.

### Trocar o modelo de transcrição

Em `~/.config/pisper/env`:

```sh
PISPER_MODEL=gpt-4o-transcribe       # padrão, melhor qualidade
# ou
PISPER_MODEL=gpt-4o-mini-transcribe  # mais barato
# ou
PISPER_MODEL=whisper-1               # legacy, funciona
```

Qualquer endpoint compatível com `/v1/audio/transcriptions` da OpenAI deve funcionar. Pra trocar o **provider** (Groq, Whisper local via `whisper.cpp`, etc.), edite `bin/pisper-stop` — a chamada `curl` tá isolada lá.

### Trocar a duração mínima

Padrão: 250ms. Pra mudar:

```lua
pisper.init({
  binPath = '/Users/.../pisper/bin',
  minDuration = 0.5,  -- meio segundo
})
```

## Custo

`gpt-4o-transcribe` custa **~$0.006/min** de áudio transcrito. Uso típico de ditado (~10 min/dia, 20 dias úteis) ≈ **$1.20/mês**.

`gpt-4o-mini-transcribe` é bem mais barato. `whisper-1` (legacy) também.

Colocar limite mensal em [platform.openai.com/account/billing/limits](https://platform.openai.com/account/billing/limits) é uma boa. Dez dólares/mês de teto já é muito mais do que qualquer uso realista.

## Troubleshooting

### Hammerspoon não reage quando seguro a tecla

Na ordem:
1. Hammerspoon tá rodando? `pgrep -x Hammerspoon` — se não retornar PID, abra: `open -a Hammerspoon`
2. **Monitoramento de Entrada** habilitado pro Hammerspoon? (é o mais comum)
3. **Acessibilidade** habilitado? (a gravação começa mas o paste falha)
4. Outro app captura a mesma tecla? Teste outra tecla (ex: Right Command = keyCode 54)
5. Console do Hammerspoon (menu da barra → Console) mostra erro?

### ffmpeg não grava / "Input/output error"

- **Microfone** habilitado pro Hammerspoon?
- Teste manual no terminal:
  ```sh
  ffmpeg -f avfoundation -i ":default" -t 2 /tmp/test.wav && afplay /tmp/test.wav
  ```
- Se você tem múltiplos inputs (mic externo, interface de áudio), o `:default` pode não ser o certo. Listar dispositivos:
  ```sh
  ffmpeg -f avfoundation -list_devices true -i ""
  ```
  E editar `bin/pisper-record` pra apontar pro índice certo (ex: `-i ":1"`).

### Transcrição vem em inglês quando falo português (ou vice-versa)

`gpt-4o-transcribe` detecta idioma automaticamente, mas em áudios curtos ou com ruído pode errar. Solução: force o idioma via parâmetro `language` na chamada curl em `bin/pisper-stop`:

```sh
  -F "language=pt" \
```

### Cmd+V não cola em app específico

Alguns apps (jogos full-screen, apps que implementam paste custom via eventos próprios) ignoram o synthetic keystroke. Fallback: o texto **já está no clipboard** — `Cmd+V` manual cola normal.

### Quota exceeded / 429 da OpenAI

Ver em [platform.openai.com/usage](https://platform.openai.com/usage). Se for limite que você colocou, suba o cap; se for rate limit do tier, espera uns minutos.

### Reinstalar do zero

```sh
# Remove o bloco pisper do init.lua manualmente
# (entre -- pisper: BEGIN e -- pisper: END)

# Limpa config e temp
rm -rf ~/.config/pisper
rm -rf "${TMPDIR:-/tmp}/pisper"

# Reseta permissões se quiser
tccutil reset Accessibility org.hammerspoon.Hammerspoon
tccutil reset ListenEvent  org.hammerspoon.Hammerspoon
tccutil reset Microphone   org.hammerspoon.Hammerspoon

# Reinstala
cd ~/workspace/virtuware/pisper
./install.sh
```

## Layout

```
pisper/
├── bin/
│   ├── pisper-record    # inicia gravação via ffmpeg em background
│   ├── pisper-stop      # encerra ffmpeg, transcreve, cola
│   └── pisper-cancel    # aborta gravação sem transcrever
├── hammerspoon/
│   └── pisper.lua       # módulo que detecta hold e invoca os scripts
├── install.sh           # integra ao ~/.hammerspoon/init.lua
├── .env.example         # template do ~/.config/pisper/env
└── README.md
```

## Segurança

- `~/.config/pisper/env` é criado com `chmod 600` pelo `install.sh`
- `$TMPDIR` do macOS (usado pros WAVs temporários) já é per-user, não é `/tmp` compartilhado
- PID files, áudio e logs temporários ficam em `$TMPDIR/pisper/` com `umask 077`
- O último áudio enviado é guardado em `$TMPDIR/pisper/last.wav` pra debug — é sobrescrito a cada sessão. Se isso te incomoda, comenta a linha `cp "$AUDIO_FILE" "$PISPER_TMP/last.wav"` em `bin/pisper-stop`.
- A chave da OpenAI **nunca sai da sua máquina** exceto pro endpoint da OpenAI (via HTTPS). Nenhum proxy, nenhum telemetry.

## Roadmap

- [ ] Demo GIF no README
- [ ] Windows (global hotkey + captura de mic + paste) — provavelmente AutoHotkey ou app em Rust/Go
- [ ] Linux (evdev + `parecord`/`arecord` + `xdotool`/`wtype`)
- [ ] Suporte nativo a Whisper local (sem API) via `whisper.cpp`
- [ ] Pós-processamento opcional com LLM (limpar "é", "tipo", formatar pra contexto)

Contribuições são bem-vindas. Abra uma issue antes de atacar algo grande pra alinharmos escopo.

## Licença

MIT — se ainda não tem `LICENSE` no repo, adicionar um arquivo MIT padrão resolve.

## Créditos

Construído em cima de gente muito mais inteligente:
- [Hammerspoon](https://www.hammerspoon.org/) — toda a mágica de hook global
- [ffmpeg](https://ffmpeg.org/) — captura de áudio
- [OpenAI](https://platform.openai.com/docs/guides/speech-to-text) — transcrição
