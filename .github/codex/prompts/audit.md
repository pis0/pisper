Você é um auditor sênior fazendo a **primeira auditoria completa** do **pisper** — ferramenta pessoal de voice-to-text global pra macOS.

Esta NÃO é uma code review de diff. Varra **todos os arquivos do repositório** (exceto `.git/`, `.github/`, e artefatos gerados). Analise o projeto como se tivesse acabado de herdá-lo e quisesse saber em que estado está antes de apertar o play em produção.

## O que o pisper é

Hold-to-talk global pra macOS: usuário segura uma tecla modificadora (Right Option por padrão), fala, solta, e o texto transcrito é colado no app em foco via `Cmd+V`.

```
Hammerspoon (daemon macOS, Lua)
    └─ eventtap de flagsChanged detecta hold do keyCode configurado
        ├─ keyDown  → hs.task.new → bin/pisper-record   (ffmpeg AVFoundation → wav 16kHz mono)
        ├─ keyUp    → hs.task.new → bin/pisper-stop     (kill ffmpeg → silence-remove → OpenAI /v1/audio/transcriptions → pbcopy → osascript Cmd+V)
        └─ click curto (< minDuration) → hs.task.new → bin/pisper-cancel (kill ffmpeg + rm wav)
```

Stack:
- **Lua** em `hammerspoon/pisper.lua` — state machine do hold-to-talk, alerts, spawn async
- **Bash** em `bin/pisper-{record,stop,cancel}` — todos com `set -euo pipefail`
- **ffmpeg** via `-f avfoundation -i ":default"`; `silenceremove` antes de enviar pra API
- **OpenAI API** — `gpt-4o-transcribe` (configurável) em `POST /v1/audio/transcriptions`. API key em `~/.config/pisper/env` (chmod 600)
- **pbcopy + osascript** pra colar (LANG/LC_ALL forçados pra UTF-8)
- **install.sh** — injeta bloco marker-delimitado em `~/.hammerspoon/init.lua`

Estado runtime em `/tmp/pisper/`.

## Escopo da auditoria

Quero um retrato honesto do projeto nas seguintes dimensões. **Priorize por impacto real.** Não invente problema só pra preencher finding; se uma dimensão estiver sólida, diga isso no `overall_explanation`.

### 1. Segurança

- **Shell injection & quoting**: todo arg interpolado em shell tem aspas duplas? Paths com espaços/aspas/`$` quebram? `$PISPER_DIR` no `install.sh` vem de dirname do clone — se o user clona em path exótico, o bloco injetado em `init.lua` vira Lua inválido ou pior.
- **API key leak**: `OPENAI_API_KEY` pode vazar via stderr/stdout/log? O `log_err "API request failed: $response"` em `pisper-stop` — se o curl ecoa headers de erro, a key pode aparecer. `set -x` em debug vazaria? Env file com chmod 600 é suficiente?
- **osascript injection**: hoje `Cmd+V` é hardcoded (seguro). Algum caminho que interpola string user-controlled em AppleScript?
- **PID file sem dono**: `kill "$old_pid"` após `cat` do pid file — race entre `kill -0` check e o `kill` real. Em pior caso, mata processo alheio do sistema com pid reciclado.
- **Tempfile em `/tmp/pisper`**: path fixo, readable por outros users. Se for multi-user ou se `/tmp` for um share, áudio do mic fica exposto. `$TMPDIR` ou `mktemp -d` seria mais seguro.
- **`source "$ENV_FILE"`**: qualquer código shell arbitrário no env file é executado. Se o install/update jamais pegar env file de origem não-confiável, tudo bem — confirmar que não há esse path.
- **curl sem timeout**: requisição pode travar indefinidamente sem `--max-time`. Não é security crítico mas é robustez.

### 2. Correção — bugs funcionais

- **State machine do hold-to-talk** em `pisper.lua`:
  - ffmpeg falha em `startRecording` — `isRecording=true` já foi setado, keyUp ainda dispara `pisper-stop` sobre arquivo inexistente.
  - Dois `keyDown` consecutivos (bug macOS / teclado).
  - Hammerspoon reload no meio de gravação — PID órfão em `/tmp/pisper/ffmpeg.pid`.
  - `hs.task` callback tardio executando depois que user já iniciou nova gravação.
- **Races nos bash scripts**:
  - `pisper-record` e `pisper-stop` concorrentes se user holdar+soltar rápido.
  - `sleep 0.1` após `kill` em `pisper-record` — ffmpeg pode ainda segurar o wav.
  - `pisper-stop` espera até 500ms pra ffmpeg finalizar (`SIGINT` → 10x50ms → `SIGTERM`). Em mic lento, pode não bastar.
- **Empty / malformed API response**: `jq '.text // empty'` cai pra vazio, mas `response` inteiro vai pra `log_err` se a API retornar `{"error": {...}}` — aceitável?
- **`silenceremove` produz arquivo vazio**: fallback `[[ -s "$TRIMMED" ]]` cobre isso? Ffmpeg exit 0 + arquivo vazio é plausível?
- **keyCode vs flag mapping** em `pisper.lua` (linhas 85-88): se usuário configura keyCode não mapeado (ex: 80 = F19), cai no default `isDown = flags.alt == true` — que só é true se Option tá apertado. F19 provavelmente nunca reporta alt=true, então gravação nunca inicia. Bug latente.
- **`recordingStartedAt = nil` edge**: `stopRecording` com `recordingStartedAt` nil faz `secondsSinceEpoch() - 0 = número gigante` — passa minDuration, vai pra transcribing. Só acontece se `isRecording` for true sem startedAt setado — teoricamente impossível, mas confirmar.

### 3. Robustez macOS

- **Permissões TCC** (Accessibility, Input Monitoring, Microphone): sem elas, silent fails. UX de onboarding lida com isso? `install.sh` apenas imprime aviso — suficiente?
- **Dispositivo de áudio trocando durante gravação** (Bluetooth desconectando, etc): ffmpeg pode travar.
- **PATH em shell não-interativo**: Hammerspoon spawna shell sem `.zshrc`. Todo script exporta PATH com brew paths (ARM + Intel). OK hoje, mas qualquer dep nova precisa disso.
- **UTF-8**: `LANG/LC_ALL=en_US.UTF-8` no `pisper-stop` é obrigatório antes de `pbcopy`. `pisper-record` também tem (p/ consistência), mas `pisper-cancel` não — problema?
- **ARM vs Intel**: ambos `/opt/homebrew/bin` e `/usr/local/bin` no PATH — OK.
- **macOS versions**: Hammerspoon 1.x, `hs.eventtap`, `hs.task` — quais versões do macOS cobertas? install.sh não checa.

### 4. Código / estrutura

- **`pisper.lua`** — módulo singleton (`local M = {}`); `init` é idempotente se chamado duas vezes? Vaza eventtap antigo?
- **Assinatura de callbacks `hs.task.new`**: `function(exitCode, stdout, stderr)` — stdout/stderr podem vir nil? (checado no código — bem feito).
- **Bash scripts**: duplicação de `export PATH`/`LANG` em cada script — extrair pra `bin/_common.sh` seria mais limpo, mas adiciona complexidade. Julgue trade-off.
- **Nomes de env vars**: `PISPER_TMP`, `PISPER_ENV_FILE`, `PISPER_MODEL` — consistente, bom.
- **Dead code / unused**: algo no repo que não é referenciado por nada?

### 5. UX

- **Alerts do `hs.alert`**: `closeAll` antes de cada alert evita empilhar, mas também apaga alert de outro script que usa Hammerspoon. Conflito com outros módulos do user?
- **Mensagens de erro**: acionáveis (dizem o que fazer) ou genéricas?
- **Click muito curto (< 250ms)** cancela silencioso — bom padrão.
- **`README.md`**: completo, troubleshooting cobre casos reais?

### 6. Operação / manutenção

- **Versionamento**: sem `VERSION` file, sem tags semver (o workflow de release depende de tags `v*` — aparece mencionado no readme?).
- **Backups de áudio** em `$PISPER_TMP/last.wav`: cresce sem limpeza, só é sobrescrito a cada uso. Em uso intenso `/tmp` pode encher — aceitável?
- **Observabilidade**: `LOG_FILE="$PISPER_TMP/record.log"` é escrito mas ninguém consome. Rotação?
- **install.sh idempotência**: marker-based injection evita dup. Uninstall não existe — plausível pra v1.

## Formato da resposta

- Liste findings ordenados por priority (1=HIGH primeiro).
- Cada finding: `title`, `body` (explicação + sugestão concreta), `priority` (1-3), `confidence_score` (0.0-1.0), `code_location` (filepath + line range).
- `overall_correctness`: "patch is correct" se o projeto está saudável pra shipping pessoal; "patch is incorrect" se há bug real ou vuln que precisa ser corrigido antes de usar.
- `overall_explanation`: síntese — o estado geral do projeto, pontos fortes, preocupações principais.
- `overall_confidence_score`: quão confiante você está no veredito.

## Regras

- Só aponte findings acionáveis com sugestão concreta. Nada de "considere adicionar testes" genérico.
- Cite arquivo + range de linhas em cada finding.
- Este é um projeto **pessoal** — não compare com padrões enterprise (sem CI/CD complexo, sem monitoring, sem observability stack). Julgue pelo propósito: ferramenta de uso diário do autor.
- Não sugira adicionar comentários, docstrings ou tipos a menos que algo esteja genuinamente confuso.
- Não nitpick de estilo.
- Se o projeto estiver bem, liste `findings: []` e explique no `overall_explanation`. **Não invente problemas.**
- Responda em **português (Brasil)**.
