-- pisper: global voice-to-text for macOS via Hammerspoon + OpenAI Whisper.
-- Hold-to-talk: hold the configured key, speak, release — the transcribed text
-- is pasted into the focused app.

local M = {}

-- Right Option keyCode (0x3D = 61). Other useful ones:
--   Right Command: 54 | Right Shift: 60 | Right Control: 62 | Fn: 63
-- Only modifier keys work here — flagsChanged doesn't fire for regular keys
-- (F13–F19 and friends).
local DEFAULT_KEYCODE = 61
local DEFAULT_MIN_DURATION = 0.25 -- seconds; shorter clicks are cancelled silently

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
  -- hs.task.new returns nil when launchPath doesn't exist; task:start returns
  -- nil when the spawn fails. Without these checks the callback never fires
  -- and whatever state the caller set up becomes a zombie.
  if not task then return nil, "launch path not found" end
  if not task:start() then return nil, "task:start failed" end
  return task
end

function M.startRecording()
  if isRecording then return end
  sessionSeq = sessionSeq + 1
  local sid = tostring(sessionSeq)

  -- Register ownership before task:start so the callback can identify this
  -- session correctly even on an ultra-fast dispatch. isRecording flips to
  -- true only after we confirm the task started — that avoids a "recording"
  -- state with no actual recording when binPath is stale or the exec bit is
  -- gone.
  currentSession = sid

  local task, err = runAsync(M.binPath .. "/pisper-record", { sid }, function(exitCode, _, stderr)
    -- pisper-record can fail legitimately (mic denied, ffmpeg missing) or
    -- because pisper-cancel killed ffmpeg during a short-click (< minDuration)
    -- before the validation window closed. Only alert if we're still in this
    -- session — otherwise the user already cancelled and the alert would be
    -- noise, breaking the silent-cancel UX.
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
    -- The async callback will never fire — roll state back manually.
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
    -- If a new session started while this transcription was running, this
    -- alert would overwrite the new session's visual feedback. Suppress it —
    -- the text was already pasted by pisper-stop (pbcopy + Cmd+V) anyway.
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

  -- Reloading Hammerspoon during a recording leaves an orphan ffmpeg. Clear
  -- out any prior sessions before wiring things back up.
  runAsync(M.binPath .. "/pisper-cancel", nil, nil)

  -- Allow reload via osascript / CLI (useful in a dev loop).
  hs.allowAppleScript(true)

  -- rawFlagMasks lets us distinguish left/right within the same modifier
  -- family. Without this, the aggregate flags (flags.alt, flags.cmd, etc.)
  -- stay true as long as the opposite side is held: user configures Right
  -- Option as the hotkey and happens to be holding Left Option → releasing
  -- Right doesn't drop flags.alt and the recording "sticks".
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

  -- Detect hold of the modifier via flagsChanged. The keyCode identifies the
  -- specific physical key that changed state (e.g. Right Option, not any Option).
  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    local code = event:getKeyCode()
    if code ~= M.keyCode then return false end

    local isDown
    local mask = KEY_MASK[code]
    if mask then
      -- Preferred path: check the bit for this exact physical key, immune to
      -- aggregate flags staying true because of the opposite left/right key.
      local rawFlags = event:getRawEventData().CGEventData.flags or 0
      isDown = bit.band(rawFlags, mask) ~= 0
    else
      -- Fallback for the rare keyCode that isn't in the mask table.
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
