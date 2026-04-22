-- pisper: voice-to-text global para macOS via Hammerspoon + OpenAI Whisper.
-- Hold-to-talk: segure a tecla configurada, fale, solte — o texto é colado no app em foco.

local M = {}

-- keyCode do Right Option (0x3D = 61). Outros úteis:
--   Right Command: 54 | Right Shift: 60 | Right Control: 62 | Fn: 63
--   F19: 80 (teclados com bloco numérico)
local DEFAULT_KEYCODE = 61
local DEFAULT_MIN_DURATION = 0.25 -- segundos; clicks rápidos são cancelados

local isRecording = false
local recordingStartedAt = nil

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
  task:start()
  return task
end

function M.startRecording()
  if isRecording then return end
  isRecording = true
  recordingStartedAt = hs.timer.secondsSinceEpoch()
  alert("🎤 pisper", 0.4)
  runAsync(M.binPath .. "/pisper-record", nil, function(exitCode, _, stderr)
    if exitCode ~= 0 then
      hs.alert.show("pisper: erro ao iniciar\n" .. stderr, 2)
    end
  end)
end

function M.stopRecording()
  if not isRecording then return end
  isRecording = false

  local elapsed = hs.timer.secondsSinceEpoch() - (recordingStartedAt or 0)
  recordingStartedAt = nil

  if elapsed < M.minDuration then
    runAsync(M.binPath .. "/pisper-cancel", nil, nil)
    return
  end

  alert("⏳ transcrevendo…", 0.5)
  runAsync(M.binPath .. "/pisper-stop", nil, function(exitCode, stdout, stderr)
    if exitCode == 0 then
      alert("✅", 0.3)
    else
      hs.alert.show("pisper: falha\n" .. (stderr ~= "" and stderr or stdout), 3)
    end
  end)
end

function M.init(opts)
  opts = opts or {}
  M.binPath = assert(opts.binPath, "pisper.init: binPath obrigatório")
  M.keyCode = opts.keyCode or DEFAULT_KEYCODE
  M.minDuration = opts.minDuration or DEFAULT_MIN_DURATION

  -- permite reload via osascript/CLI (útil pra dev loop)
  hs.allowAppleScript(true)

  -- Detecta hold do modifier via flagsChanged. O keyCode identifica a tecla
  -- específica que mudou de estado (ex: Right Option, não qualquer Option).
  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    if event:getKeyCode() ~= M.keyCode then return false end

    local flags = event:getFlags()
    local isDown = flags.alt == true

    if M.keyCode == 54 or M.keyCode == 55 then isDown = flags.cmd == true end
    if M.keyCode == 60 or M.keyCode == 56 then isDown = flags.shift == true end
    if M.keyCode == 62 or M.keyCode == 59 then isDown = flags.ctrl == true end
    if M.keyCode == 63 then isDown = flags.fn == true end

    if isDown and not isRecording then
      M.startRecording()
    elseif not isDown and isRecording then
      M.stopRecording()
    end
    return false
  end)

  M.tap:start()
  print("[pisper] ativo — hold keyCode " .. M.keyCode .. " pra gravar")
  return M
end

return M
