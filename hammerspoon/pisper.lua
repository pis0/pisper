-- pisper: voice-to-text global para macOS via Hammerspoon + OpenAI Whisper.
-- Hold-to-talk: segure a tecla configurada, fale, solte — o texto é colado no app em foco.

local M = {}

-- keyCode do Right Option (0x3D = 61). Outros úteis:
--   Right Command: 54 | Right Shift: 60 | Right Control: 62 | Fn: 63
-- Só teclas modifier funcionam — flagsChanged não dispara em keys regulares (F13–F19 etc).
local DEFAULT_KEYCODE = 61
local DEFAULT_MIN_DURATION = 0.25 -- segundos; clicks rápidos são cancelados

local isRecording = false
local recordingStartedAt = nil
local sessionSeq = 0
local currentSession = nil

local function alert(msg, duration)
  hs.alert.closeAll()
  hs.alert.show(msg, {
    strokeColor = { white = 1, alpha = 0 },
    fillColor = { white = 0, alpha = 0.75 },
    textColor = { white = 1 },
    textSize = 16,
    radius = 12,
  }, duration or 0.5)
end

local function runAsync(path, args, cb)
  local task = hs.task.new(path, function(exitCode, stdout, stderr)
    if cb then cb(exitCode, stdout or "", stderr or "") end
  end, args or {})
  -- hs.task.new retorna nil se launchPath não existe; task:start retorna
  -- nil se o spawn falha. Sem essas checagens o callback nunca é chamado
  -- e o estado a cargo do caller vira fantasma.
  if not task then return nil, "launch path not found" end
  if not task:start() then return nil, "task:start failed" end
  return task
end

function M.startRecording()
  if isRecording then return end
  sessionSeq = sessionSeq + 1
  local sid = tostring(sessionSeq)

  -- Registra ownership antes do task:start pra callback identificar a sessão
  -- corretamente mesmo em dispatch ultra-rápido. isRecording só entra em true
  -- depois de confirmar start — evita estado "gravando" sem gravação real
  -- se binPath estiver stale ou o exec bit tiver se perdido.
  currentSession = sid

  local task, err = runAsync(M.binPath .. "/pisper-record", { sid }, function(exitCode, _, stderr)
    -- pisper-record pode falhar legitimamente (mic negado, ffmpeg ausente) ou
    -- porque pisper-cancel matou o ffmpeg em click curto (< minDuration) antes
    -- da janela de validação fechar. Só alertamos se ainda estivermos nesta
    -- sessão — caso contrário o usuário já cancelou e o alerta vira ruído,
    -- quebrando a UX de cancelamento silencioso.
    if exitCode ~= 0 then
      if currentSession == sid then
        isRecording = false
        recordingStartedAt = nil
        currentSession = nil
        hs.alert.show("pisper: failed to start\n" .. stderr, 2)
      end
    end
  end)

  if not task then
    -- Callback async nunca virá — rollback manual do estado.
    currentSession = nil
    hs.alert.show("pisper: " .. (err or "failed to spawn recorder"), 2)
    return
  end

  isRecording = true
  recordingStartedAt = hs.timer.secondsSinceEpoch()
  alert("🎤 pisper", 0.4)
end

function M.stopRecording()
  if not isRecording then return end
  isRecording = false

  local sid = currentSession
  currentSession = nil

  local elapsed = hs.timer.secondsSinceEpoch() - (recordingStartedAt or 0)
  recordingStartedAt = nil

  if elapsed < M.minDuration then
    local task, err = runAsync(M.binPath .. "/pisper-cancel", { sid }, nil)
    if not task then
      hs.alert.show("pisper: cancel failed\n" .. (err or "unknown"), 2)
    end
    return
  end

  alert("⏳ transcribing…", 0.5)
  local task, err = runAsync(M.binPath .. "/pisper-stop", { sid }, function(exitCode, stdout, stderr)
    -- Se uma nova sessão começou enquanto esta transcrição rodava, o alerta
    -- daqui sobrescreveria o feedback visual da nova. Suprime o antigo — o
    -- texto já foi colado pelo pisper-stop via pbcopy+Cmd+V de qualquer jeito.
    if currentSession ~= nil and currentSession ~= sid then
      return
    end
    if exitCode == 0 then
      alert("✅", 0.3)
    else
      hs.alert.show("pisper: failed\n" .. (stderr ~= "" and stderr or stdout), 3)
    end
  end)
  if not task then
    hs.alert.show("pisper: stop failed\n" .. (err or "unknown"), 2)
  end
end

function M.init(opts)
  opts = opts or {}
  M.binPath = assert(opts.binPath, "pisper.init: binPath required")
  M.keyCode = opts.keyCode or DEFAULT_KEYCODE
  M.minDuration = opts.minDuration or DEFAULT_MIN_DURATION

  -- Reload do Hammerspoon durante gravação deixa ffmpeg órfão. Limpa sessões anteriores.
  runAsync(M.binPath .. "/pisper-cancel", nil, nil)

  -- permite reload via osascript/CLI (útil pra dev loop)
  hs.allowAppleScript(true)

  -- rawFlagMasks permite distinguir lado esquerdo/direito da mesma família.
  -- Sem isso, flags agregadas (flags.alt, flags.cmd etc.) travam em true
  -- enquanto a contraparte estiver pressionada: usuário configura Right
  -- Option como hotkey, segura com Left Option também → solta Right e a
  -- gravação "fica presa" porque flags.alt segue true por conta do Left.
  local rawMasks = hs.eventtap.event.rawFlagMasks
  local KEY_MASK = {
    [54] = rawMasks.cmdRight,
    [55] = rawMasks.cmdLeft,
    [56] = rawMasks.shiftLeft,
    [60] = rawMasks.shiftRight,
    [58] = rawMasks.alternateLeft,
    [61] = rawMasks.alternateRight,
    [59] = rawMasks.controlLeft,
    [62] = rawMasks.controlRight,
    [63] = rawMasks.secondaryFn,
  }
  local bit = require('bit')

  -- Detecta hold do modifier via flagsChanged. O keyCode identifica a tecla
  -- específica que mudou de estado (ex: Right Option, não qualquer Option).
  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    local code = event:getKeyCode()
    if code ~= M.keyCode then return false end

    local isDown
    local mask = KEY_MASK[code]
    if mask then
      -- Caminho preferido: bit específico da tecla física, imune a flags
      -- agregadas manterem-se true via contraparte left/right.
      local rawFlags = event:getRawEventData().CGEventData.flags or 0
      isDown = bit.band(rawFlags, mask) ~= 0
    else
      -- Fallback pros raros keyCodes sem mask mapeado.
      local flags = event:getFlags()
      isDown = flags.alt == true
    end

    if isDown and not isRecording then
      M.startRecording()
    elseif not isDown and isRecording then
      M.stopRecording()
    end
    return false
  end)

  M.tap:start()
  print("[pisper] active — hold keyCode " .. M.keyCode .. " to record")
  return M
end

return M
