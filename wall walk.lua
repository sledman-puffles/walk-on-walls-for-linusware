-- wall walk for LinusWare (v10 — lw.ui window)
-- Re-running this script stops the previous copy. Stop any older wallwalk first.
-- Keys live in the Wall Walk window: Z toggle, LeftControl sprint, F dash, X let go.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local me = Players.LocalPlayer

local VERSION = "10"

local alive = true
do
    local prev = rawget(_G, "LW_WallWalkStop")
    rawset(_G, "LW_WallWalkStop", nil)
    if type(prev) == "function" then
        pcall(prev)
    end
end
local WORLD_UP = Vector3.new(0, 1, 0)
local SHIFT_LOCK_OFFSET = Vector3.new(1.75, 0, 0)
local MAX_TURN_RATE = 48
local LOG_FILE = "wallwalk_debug.log"
local REPORT_FILE = "wallwalk_report.txt"
local LOG_BUFFER_MAX = 80
local LOG_FILE_MAX_LINES = 3000
local TRAIL_MAX_POINTS = 14
local WALL_CHAIN_WINDOW = 1.35

pcall(function() RunService:UnbindFromRenderStep("LW_WallWalk_Render") end)

----------------------------------------------------------------------
-- Settings & Separate Tabbed Window
----------------------------------------------------------------------

local cfg = {
    toggleKey = Enum.KeyCode.Z,
    sprintKey = Enum.KeyCode.LeftControl,
    dashKey = Enum.KeyCode.F,
    dropKey = Enum.KeyCode.X,
    snapGroundKey = Enum.KeyCode.C,
    resetStatsKey = Enum.KeyCode.B,
    dumpKey = Enum.KeyCode.N,

    profile = "Custom",
    speed = 16,
    sprintMult = 1.8,
    wallClimbMult = 1.0,
    ceilingMult = 1.0,
    momentumKeep = 0.85,
    surfaceGrip = 1.0,
    maxSpeedCap = 350,
    jumpPower = 55,
    airJumpPower = 50,
    maxAirJumps = 1,
    wallJumpOutward = 24,
    wallChainBoost = 12,
    dashPower = 70,
    dashCooldown = 0.6,
    dashDecay = 5.0,
    hover = 3,
    smooth = 1,
    airControl = 1,
    fovBoost = 12,

    speedCapEnabled = false,
    antiRubberband = false,
    autoRecoverSnap = true,
    autoReattach = true,
    wallChain = true,
    clingWhenIdle = true,
    doubleJump = true,
    useGameAnims = true,
    walls = true,
    ceilings = true,
    wrap = true,
    innerCorner = true,
    mantleBoost = true,
    autoSprint = false,
    normalLine = true,
    velocityLine = false,
    surfaceTrail = false,
    leap = false,
    detachedAnims = true,
    forceShiftLock = false,
    extraOffset = false,
    hud = true,

    logLevel = 1,
    logToasts = false,
    logFile = false,
}

-- Preset fields are pushed into the window with :set. cfg.profile stays "Custom"
-- until the player picks a preset, so a saved slider is not overwritten on load.
local PRESETS = {
    ["Baseplate Max"] = {
        speedCapEnabled = false,
        maxSpeedCap = 350,
        antiRubberband = false,
        autoRecoverSnap = true,
        momentumKeep = 0.95,
        surfaceGrip = 1.25,
        dashDecay = 3.5,
    },
    ["Balanced"] = {
        speedCapEnabled = true,
        maxSpeedCap = 220,
        antiRubberband = true,
        autoRecoverSnap = true,
        momentumKeep = 0.85,
        surfaceGrip = 1.0,
        dashDecay = 5.0,
    },
    ["Safe / Anti-TP"] = {
        speedCapEnabled = true,
        maxSpeedCap = 115,
        antiRubberband = true,
        autoRecoverSnap = true,
        momentumKeep = 0.75,
        surfaceGrip = 1.0,
        dashDecay = 6.5,
    },
}
local PRESET_KEYS = {
    "speedCapEnabled", "maxSpeedCap", "antiRubberband", "autoRecoverSnap",
    "momentumKeep", "surfaceGrip", "dashDecay",
}

local ui = {
    ready = false,
    applying = false,
    win = nil,
    els = {},
}

local queued = {}

local function queueAction(name)
    queued[name] = true
end

local function consumeAction(name)
    if not queued[name] then return false end
    queued[name] = nil
    return true
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local enabled = false
local attached = false
local up = WORLD_UP
local smoothUp = WORLD_UP
local lastLook = Vector3.new(0, 0, -1)
local lastPos = nil
local lastAppliedVel = Vector3.zero
local anchorHit = nil
local anchorUntil = 0
local anchorLogged = false
local missSince = nil
local collideSaved = {}
local isNoColliding = false
local lastAssert = 0
local releaseUntil = 0
local noAttachUntil = 0
local curVel = Vector3.zero
local extraVel = Vector3.zero
local dashReadyAt = 0
local airJumpsUsed = 0
local wallChainStacks = 0
local lastWallJumpAt = 0
local leanPitch = 0
local leanRoll = 0
local savedCamOffset = Vector3.zero
local appliedShiftOffset = false
local baseFov = nil
local appliedFov = false
local lastSprinting = false
local lastFocused = true
local lastSurface = nil
local wasDown = {}

local jumping = false
local airVel = Vector3.zero
local jumpStarted = 0
local jumpGraceUntil = 0
local snapshotLoading = false
local animLoading = false
local lastCollideScan = 0
local humState = Enum.HumanoidStateType.Running
local humStateConn = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local cachedChar = nil

local tracks = {}
local currentAnim = nil
local loadedFor = nil
local detectedRigLabel = "unknown"
local lastAnimSpeeds = {}

local hud = nil
local hudNext = 0
local normalRayLine = nil
local velRayLine = nil
local trailPoints = {}
local trailLines = {}

-- Telemetry & counters
local rayCount = 0
local raysPerTick = 0
local stepMsEma = 0
local stepMsMax = 0
local ticksSince = 0
local tickRate = 0
local lastSnapshotAt = 0
local errorTotal = 0
local peakSpeed = 0
local wrapCount = 0
local jumpCount = 0
local airJumpCount = 0
local dashCount = 0
local snapRecoverCount = 0
local lastGroundDist = -1
local lastFrontDist = -1
local lastDiagDist = -1
local lastHeightError = 0
local lastCorrection = 0

----------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------

local logBuffer = {}
local logCooldowns = {}
local logFileLines = 0
local logFileStarted = false

local function fmtV(v)
    if not v then return "nil" end
    return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

local function bufferPush(line)
    logBuffer[#logBuffer + 1] = line
    if #logBuffer > LOG_BUFFER_MAX then
        table.remove(logBuffer, 1)
    end
end

local function fileAppend(line)
    if not logFileStarted or logFileLines >= LOG_FILE_MAX_LINES then
        logFileStarted = true
        logFileLines = 0
        pcall(writefile, LOG_FILE, "-- wallwalk v" .. VERSION .. " log\n")
    end
    if pcall(appendfile, LOG_FILE, line .. "\n") then
        logFileLines = logFileLines + 1
    end
end

local function wwLog(level, tag, msg, cooldown, kind)
    local problem = (kind == "warn" or kind == "error")
    local now = time()
    if cooldown and cooldown > 0 then
        local prev = logCooldowns[tag]
        if prev and now - prev < cooldown then return end
        logCooldowns[tag] = now
    end
    local show = problem or cfg.logLevel >= level
    if not show and level > 2 then return end

    local line = string.format("[WW %8.2f] %-13s %s", now, tostring(tag), tostring(msg))
    bufferPush(line)
    if not show then return end

    if problem then warn(line) else print(line) end
    if cfg.logFile then fileAppend(line) end
    if problem or cfg.logToasts then
        pcall(lw.log, "[WW] " .. tostring(msg), kind or "info")
    end
end

local function logE(tag, msg, cd) wwLog(1, tag, msg, cd) end
local function logV(tag, msg, cd) wwLog(2, tag, msg, cd) end
local function logT(tag, msg, cd) wwLog(3, tag, msg, cd) end
local function logW(tag, msg, cd) wwLog(1, tag, msg, cd, "warn") end
local function logX(tag, msg, cd) wwLog(1, tag, msg, cd, "error") end
local function logOK(tag, msg, cd) wwLog(1, tag, msg, cd, "success") end

local prevCfg = {}
local lastDiffAt = 0
local function diffSettings()
    local now = time()
    if now - lastDiffAt < 0.25 then return end
    for k, v in pairs(cfg) do
        local pv = prevCfg[k]
        if pv ~= nil and pv ~= v then
            lastDiffAt = now
            wwLog(2, "cfg_" .. k, string.format("%s: %s -> %s", k, tostring(pv), tostring(v)), 0.25)
        end
        prevCfg[k] = v
    end
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

local keyCache = {}

local function resolveKey(key)
    if type(key) ~= "string" then return nil end
    local c = keyCache[key]
    if c == nil then
        local ok, e = pcall(function() return Enum.KeyCode[key] end)
        c = (ok and e) or false
        keyCache[key] = c
    end
    return c or nil
end

local function keyDown(key)
    if key == nil then return false end
    local ok, down = pcall(lw.isKeyDown, key)
    if ok and down == true then return true end
    local e = resolveKey(key)
    if e then
        local ok2, d2 = pcall(function() return UserInputService:IsKeyDown(e) end)
        if ok2 and d2 == true then return true end
    end
    return false
end

local function spaceIsDown()
    if keyDown("Space") then return true end
    local ok, res = pcall(function() return UserInputService:IsKeyDown(Enum.KeyCode.Space) end)
    return ok and res == true
end

local function windowFocused()
    if input and type(input.focused) == "function" then
        local ok, res = pcall(input.focused)
        if ok then return res == true end
    end
    if isrbxactive then
        local ok, res = pcall(isrbxactive)
        if ok then return res == true end
    end
    return true
end

local function edge(name, down)
    local was = wasDown[name]
    wasDown[name] = down
    return down and not was
end

----------------------------------------------------------------------
-- Animations & Rig Detection
----------------------------------------------------------------------

local R15_ANIMS = {
    walk = "rbxassetid://507777826",
    climb = "rbxassetid://507765644",
    idle = "rbxassetid://507766388",
    jump = "rbxassetid://507765000",
    sit = "rbxassetid://2506281703",
    swim = "rbxassetid://507784897",
    fall = "rbxassetid://507767968",
}
local R6_ANIMS = {
    walk = "rbxassetid://180426354",
    climb = "rbxassetid://113608226",
    idle = "rbxassetid://180435571",
    jump = "rbxassetid://125750702",
    sit = "rbxassetid://178130996",
    swim = "rbxassetid://180426354",
    fall = "rbxassetid://180436148",
}

local R15_PARTS = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" }
local R6_PARTS = { "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local function detectRigType(char, hum)
    local rigTypeEnum = nil
    if hum then
        pcall(function() rigTypeEnum = hum.RigType end)
    end

    local r15Score = 0
    local r6Score = 0
    if char then
        for _, pName in ipairs(R15_PARTS) do
            if char:FindFirstChild(pName) then r15Score = r15Score + 1 end
        end
        for _, pName in ipairs(R6_PARTS) do
            if char:FindFirstChild(pName) then r6Score = r6Score + 1 end
        end
    end

    if r15Score > r6Score and r15Score >= 2 then
        return true, string.format("R15 (parts %d vs R6 %d)", r15Score, r6Score)
    end
    if r6Score > r15Score and r6Score >= 2 then
        return false, string.format("R6 (parts %d vs R15 %d)", r6Score, r15Score)
    end

    if rigTypeEnum == Enum.HumanoidRigType.R6 then
        return false, "R6 (Humanoid.RigType)"
    elseif rigTypeEnum == Enum.HumanoidRigType.R15 then
        return true, "R15 (Humanoid.RigType)"
    end

    if r6Score > 0 and r15Score == 0 then
        return false, "R6 (single part match)"
    end
    return true, "R15 (default fallback)"
end

local function extractGameAnimIds(char, baseIds)
    local ids = {}
    for k, v in pairs(baseIds) do ids[k] = v end
    if not (cfg.useGameAnims and char) then return ids, 0 end

    local animateScript = char:FindFirstChild("Animate")
    if not animateScript then return ids, 0 end

    local map = {
        walk = { "walk/WalkAnim", "run/RunAnim" },
        climb = { "climb/ClimbAnim" },
        idle = { "idle/Animation1", "idle/Animation2" },
        jump = { "jump/JumpAnim" },
        sit = { "sit/SitAnim" },
        swim = { "swim/Swim" },
        fall = { "fall/FallAnim" },
    }
    local overridden = 0
    for animKey, paths in pairs(map) do
        for _, relPath in ipairs(paths) do
            local folderName, childName = string.match(relPath, "^([^/]+)/([^/]+)$")
            local folder = folderName and animateScript:FindFirstChild(folderName)
            local animObj = folder and childName and folder:FindFirstChild(childName)
            if animObj and animObj:IsA("Animation") and type(animObj.AnimationId) == "string" and animObj.AnimationId ~= "" then
                ids[animKey] = animObj.AnimationId
                overridden = overridden + 1
                break
            end
        end
    end
    return ids, overridden
end

local function setAnim(name, fadeTime, speed)
    if name == nil then
        if currentAnim then
            local old = tracks[currentAnim]
            if old then pcall(function() old:Stop(fadeTime or 0.12) end) end
            logV("anim", "stop " .. tostring(currentAnim), 0.2)
            currentAnim = nil
        end
        return
    end

    local targetTrack = tracks[name] or tracks.walk or tracks.idle
    if not targetTrack then
        logW("anim_missing", "no usable animation track for '" .. name .. "'", 3.0)
        return
    end

    local fade = fadeTime or 0.16
    local targetSpeed = speed or 1
    if name ~= currentAnim then
        local old = tracks[currentAnim]
        if old and old ~= targetTrack then
            pcall(function() old:Stop(fade) end)
        end
        local okPlay = pcall(function() targetTrack:Play(fade, 1, targetSpeed) end)
        if not okPlay then
            logW("anim_play", "failed playing track '" .. name .. "', retrying once", 1.0)
            pcall(function() targetTrack:Play(0.05, 1, targetSpeed) end)
        end
        logV("anim", string.format("%s -> %s (x%.2f)", tostring(currentAnim), name, targetSpeed), 0.2)
        lastAnimSpeeds[name] = targetSpeed
        currentAnim = name
    else
        local prevSpeed = lastAnimSpeeds[name] or 1
        if math.abs(targetSpeed - prevSpeed) > 0.05 then
            lastAnimSpeeds[name] = targetSpeed
            pcall(function() targetTrack:AdjustSpeed(targetSpeed) end)
        end
    end
end

local function bindHumanoidState(hum)
    if humStateConn then
        pcall(function() humStateConn:Disconnect() end)
        humStateConn = nil
    end
    if not hum then return end
    pcall(function() humState = hum:GetState() end)
    local ok, conn = pcall(function()
        return hum.StateChanged:Connect(function(_, newState)
            humState = newState
            logV("hum_state", "humanoid state -> " .. tostring(newState and newState.Name or newState), 0.3)
        end)
    end)
    if ok then
        humStateConn = conn
    else
        logW("hum_state", "Humanoid.StateChanged not available, using hum.Sit only: " .. tostring(conn), 10)
    end
end

local function loadAnims(char, hum)
    loadedFor = hum
    bindHumanoidState(hum)

    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = hum
        task.wait()
    end

    local isR15, rigReason = detectRigType(char, hum)
    detectedRigLabel = rigReason
    local baseIds = isR15 and R15_ANIMS or R6_ANIMS
    local ids, gameOverrides = extractGameAnimIds(char, baseIds)

    for _, track in pairs(tracks) do
        pcall(function()
            track:Stop(0)
            track:Destroy()
        end)
    end
    table.clear(tracks)
    table.clear(lastAnimSpeeds)
    currentAnim = nil

    local loaded, fellBack, failed = 0, {}, {}
    for name, id in pairs(ids) do
        local anim = Instance.new("Animation")
        anim.AnimationId = id

        local okTrack, track = pcall(function() return animator:LoadAnimation(anim) end)
        if not (okTrack and track) and id ~= baseIds[name] then
            anim.AnimationId = baseIds[name]
            okTrack, track = pcall(function() return animator:LoadAnimation(anim) end)
            if okTrack and track then
                fellBack[#fellBack + 1] = name
            end
        end

        if okTrack and track then
            pcall(function()
                track.Looped = (name ~= "jump")
                track.Priority = (name == "jump") and Enum.AnimationPriority.Action or Enum.AnimationPriority.Movement
            end)
            tracks[name] = track
            lastAnimSpeeds[name] = 1
            loaded = loaded + 1
        else
            failed[#failed + 1] = name
        end
        pcall(function() anim:Destroy() end)
    end

    local msg = string.format("loaded %d/7 animations [%s] (gameOverrides=%d)",
        loaded, rigReason, gameOverrides)
    if #fellBack > 0 then
        msg = msg .. " (defaultFallback=" .. table.concat(fellBack, ",") .. ")"
    end
    if #failed > 0 then
        logW("anims", msg .. ", failed: " .. table.concat(failed, ", "))
    else
        logOK("anims", msg)
    end
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function parts()
    local char = me.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not (root and hum) then return end
    return char, root, hum
end

local function project(v, n)
    return v - n * v:Dot(n)
end

local function clampMag(v, maxLen)
    local mag = v.Magnitude
    if mag > maxLen and mag > 1e-4 then
        return v * (maxLen / mag), true
    end
    return v, false
end

local function applySafeVelocity(root, targetVel, dt)
    if not root then return end
    local vel = targetVel
    if cfg.speedCapEnabled and cfg.maxSpeedCap > 0 then
        local capped, wasCapped = clampMag(vel, cfg.maxSpeedCap)
        vel = capped
        if wasCapped then
            logV("speed_cap", string.format("clamped velocity to %.0f studs/s", cfg.maxSpeedCap), 1.0)
        end
    end
    if cfg.antiRubberband then
        local maxDelta = math.max(cfg.speed * 20, 320) * math.clamp(dt * 16, 0.2, 1.0)
        local diff = vel - lastAppliedVel
        if diff.Magnitude > maxDelta then
            vel = lastAppliedVel + diff.Unit * maxDelta
        end
    end
    lastAppliedVel = vel
    root.AssemblyLinearVelocity = vel
end

local function getSurfaceSpeedMult(surfaceUp)
    if not surfaceUp then return 1 end
    if surfaceUp.Y < -0.7 then return cfg.ceilingMult end
    if surfaceUp.Y <= 0.7 then return cfg.wallClimbMult end
    return 1
end

local function getGravity()
    local ok, g = pcall(function() return workspace.Gravity end)
    if ok and type(g) == "number" and g > 0 then return g end
    return 196.2
end

local function isShiftLocked()
    if cfg.forceShiftLock then return true end
    local ok, behavior = pcall(function() return UserInputService.MouseBehavior end)
    if not ok or behavior ~= Enum.MouseBehavior.LockCenter then return false end
    local cam = workspace.CurrentCamera
    if cam and (cam.CFrame.Position - cam.Focus.Position).Magnitude < 1.5 then return false end
    return true
end

local function syncShiftLockOffset(hum, active)
    if not hum then return end
    if active then
        if not appliedShiftOffset then
            savedCamOffset = hum.CameraOffset
            appliedShiftOffset = true
            logV("shiftlock", "extra camera offset applied")
        end
        hum.CameraOffset = hum.CameraOffset:Lerp(savedCamOffset + SHIFT_LOCK_OFFSET, 0.3)
    elseif appliedShiftOffset then
        hum.CameraOffset = savedCamOffset
        appliedShiftOffset = false
        logV("shiftlock", "extra camera offset removed")
    end
end

local function updateCameraEffects(camObj, active, speedRatio, dt)
    if not camObj then return end
    if active and cfg.fovBoost > 0 then
        if not baseFov then
            baseFov = camObj.FieldOfView
            logV("fov", string.format("base FOV captured: %.1f", baseFov))
        end
        local boost = cfg.fovBoost * math.clamp((speedRatio - 1) / 0.8, 0, 1)
        local k = 1 - math.exp(-10 * dt)
        camObj.FieldOfView = camObj.FieldOfView + (baseFov + boost - camObj.FieldOfView) * k
        appliedFov = true
    elseif appliedFov and baseFov then
        camObj.FieldOfView = baseFov
        appliedFov = false
        baseFov = nil
        logV("fov", "FOV restored")
    end
end

local function noCollide(char, rescan)
    if isNoColliding and not rescan then return 0 end
    isNoColliding = true
    local count = 0
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            collideSaved[part] = true
            part.CanCollide = false
            count = count + 1
        end
    end
    return count
end

local function reassertCollide()
    local fixed = 0
    for part in pairs(collideSaved) do
        if part and part.Parent and part.CanCollide then
            part.CanCollide = false
            fixed = fixed + 1
        end
    end
    return fixed
end

local function restoreCollide()
    if not isNoColliding then return end
    isNoColliding = false
    local count = 0
    for part in pairs(collideSaved) do
        if part and part.Parent then
            part.CanCollide = true
            count = count + 1
        end
    end
    table.clear(collideSaved)
    logV("collide", "collisions restored on " .. count .. " parts", 0.3)
end

local function cast(char, origin, direction)
    if cachedChar ~= char then
        cachedChar = char
        rayParams.FilterDescendantsInstances = { char }
    end
    rayCount = rayCount + 1
    local hit, why = workspace:Raycast(origin, direction, rayParams)
    if why == "world snapshot still loading" then
        snapshotLoading = true
    end
    return hit
end

local function surfaceAllowed(n)
    if n.Y < -0.7 then return cfg.ceilings end
    if n.Y <= 0.7 then return cfg.walls end
    return true
end

local function blockedReason(hum)
    local sit = false
    pcall(function() sit = hum.Sit == true end)
    if sit or humState == Enum.HumanoidStateType.Seated then return "seated" end
    if humState == Enum.HumanoidStateType.Swimming then return "swimming" end
    return nil
end

local function clearTrail()
    table.clear(trailPoints)
    for _, lineObj in ipairs(trailLines) do
        if lineObj then pcall(function() lineObj.Visible = false end) end
    end
end

local function destroyVisuals()
    if hud then
        pcall(function() hud:Remove() end)
        hud = nil
    end
    if normalRayLine then
        pcall(function() normalRayLine:Remove() end)
        normalRayLine = nil
    end
    if velRayLine then
        pcall(function() velRayLine:Remove() end)
        velRayLine = nil
    end
    for _, lineObj in ipairs(trailLines) do
        if lineObj then pcall(function() lineObj:Remove() end) end
    end
    table.clear(trailLines)
    table.clear(trailPoints)
end

----------------------------------------------------------------------
-- Attach / detach
----------------------------------------------------------------------

local function detach(root, hum, char, snapToGround, reason)
    local wasAttached = attached
    local wasJumping = jumping
    attached = false
    lastSurface = nil
    lastPos = nil
    lastAppliedVel = Vector3.zero
    anchorHit = nil
    anchorUntil = 0
    anchorLogged = false
    up = WORLD_UP
    smoothUp = WORLD_UP
    curVel = Vector3.zero
    extraVel = Vector3.zero
    airVel = Vector3.zero
    jumpStarted = 0
    leanPitch = 0
    leanRoll = 0
    missSince = nil
    jumping = false
    airJumpsUsed = 0
    wallChainStacks = 0
    clearTrail()
    setAnim(nil, snapToGround and 0.05 or 0.12)
    if snapToGround then
        updateCameraEffects(workspace.CurrentCamera, false, 0, 1 / 60)
    end
    if hum then
        syncShiftLockOffset(hum, false)
        pcall(function()
            hum.PlatformStand = false
            hum.AutoRotate = true
        end)
    end
    if root then
        local look = project(root.CFrame.LookVector, WORLD_UP)
        if look.Magnitude < 0.01 then look = project(lastLook, WORLD_UP) end
        if look.Magnitude < 0.01 then look = Vector3.new(0, 0, -1) end
        look = look.Unit

        local pos = root.Position
        local snapped = false
        if snapToGround and char and hum then
            local okHip, hip = pcall(function() return hum.HipHeight end)
            local standHeight = ((okHip and type(hip) == "number") and hip or 2) + root.Size.Y / 2
            standHeight = math.max(standHeight, 3)
            local floorHit = cast(char, pos + WORLD_UP * 1.5, -WORLD_UP * (standHeight + 12))
            if floorHit then
                pos = floorHit.Position + WORLD_UP * standHeight
                snapped = true
            end
        end

        root.CFrame = CFrame.lookAt(pos, pos + look)
        if snapToGround then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            logV("snap", snapped and "stood upright on the floor below" or "no floor within 15 studs, left in place")
        end
    end
    restoreCollide()
    if wasAttached or wasJumping or snapToGround then
        logE("detach", string.format("reason=%s snap=%s (was %s)", tostring(reason or "?"),
            tostring(snapToGround), wasJumping and "jumping" or (wasAttached and "attached" or "free")), 0.2)
    end
end

local function requestAnims(char, hum)
    if not char or not hum or hum == loadedFor or animLoading then return end
    animLoading = true
    task.spawn(function()
        local ok, err = pcall(loadAnims, char, hum)
        animLoading = false
        if not ok then
            if loadedFor == hum then loadedFor = nil end
            logX("anims", "loadAnims failed: " .. tostring(err), 2)
        end
    end)
end

local function setEnabled(on)
    enabled = on
    wasDown = {}
    local char, root, hum = parts()
    if not on then
        releaseUntil = time() + 0.5
        detach(root, hum, char, true, "script turned off")
    else
        missSince = nil
        noAttachUntil = 0
        lastSurface = nil
        airJumpsUsed = 0
        wallChainStacks = 0
        lastPos = root and root.Position or nil
        lastAppliedVel = Vector3.zero
        if not (char and root and hum) then
            logW("enable", "turned on but no character yet, waiting", 1.5)
        else
            requestAnims(char, hum)
            logE("enable", string.format("turned on (profile=%s speed=%d cap=%s(%d) hover=%d)",
                cfg.profile, cfg.speed, tostring(cfg.speedCapEnabled), cfg.maxSpeedCap, cfg.hover))
        end
    end
    pcall(lw.log, on and "Wall walk ON" or "Wall walk OFF", on and "success" or "info")
end

----------------------------------------------------------------------
-- Surface detection
----------------------------------------------------------------------

local SAMPLE_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function sampleNormal(char, pos, hit, surfaceUp, f, r, reach)
    local sum = hit.Normal
    local count = 1
    for _, o in ipairs(SAMPLE_OFFSETS) do
        local origin = pos + (f * o[1] + r * o[2]) * 1.1
        local h = cast(char, origin, -surfaceUp * reach)
        if h and math.abs(h.Distance - hit.Distance) < 1.5 and h.Normal:Dot(hit.Normal) > 0.5 then
            sum = sum + h.Normal
            count = count + 1
        end
    end
    local n = sum / count
    if n.Magnitude < 0.01 then return hit.Normal, 1 end
    return n.Unit, count
end

local WRAP_RISES = { 0.8, 2.0, 3.2 }
local WRAP_INSETS = { 0.3, 1.0, 2.0 }

local function findWrap(char, pos, dir, surfaceUp, lead)
    local hover = cfg.hover
    for _, rise in ipairs(WRAP_RISES) do
        for _, inset in ipairs(WRAP_INSETS) do
            local origin = pos + dir * (hover + rise + lead) - surfaceUp * (hover + inset)
            local h = cast(char, origin, -dir * (hover + rise + lead + 3.5))
            if h and h.Normal:Dot(dir) > 0.5 then
                return h, string.format("rise=%.1f inset=%.1f", rise, inset)
            end
        end
    end
    local origin = pos + dir * (hover + 1.6 + lead) - surfaceUp * (hover + 1.8)
    local h = cast(char, origin, (-dir - surfaceUp * 0.3).Unit * (hover + 3.2 + lead))
    return h, "diagonal"
end

local function findInnerCorner(char, pos, dir, surfaceUp, lead)
    local hover = cfg.hover
    local sweep = (dir - surfaceUp * 0.45).Unit
    return cast(char, pos, sweep * (hover + 2.4 + lead))
end

local function getSurfaceBasis(cam, surfaceUp)
    local look = cam.LookVector
    local f = project(look, surfaceUp)

    if math.abs(surfaceUp.Y) < 0.7 then
        local wallUp = project(WORLD_UP, surfaceUp)
        if wallUp.Magnitude > 0.05 then
            wallUp = wallUp.Unit
            local into = -look:Dot(surfaceUp)
            local w = math.clamp((into - 0.45) / 0.35, 0, 1)
            if f.Magnitude < 0.08 then
                f = wallUp
            elseif w > 0 then
                f = f.Unit * (1 - w) + wallUp * w
                if f.Magnitude < 0.05 then f = wallUp end
            end
        end
    end

    if f.Magnitude < 0.08 then
        f = project(cam.UpVector, surfaceUp)
        if f.Magnitude < 0.08 then f = cam.RightVector:Cross(surfaceUp) end
    end
    f = f.Unit
    local r = f:Cross(surfaceUp).Unit
    return f, r
end

----------------------------------------------------------------------
-- Orientation
----------------------------------------------------------------------

local function computeFacing(cam, shiftLocked, moving, dir, f, surfaceUp)
    local look
    if shiftLocked then
        look = project(cam.LookVector, surfaceUp)
        if look.Magnitude < 0.08 then look = project(cam.UpVector, surfaceUp) end
        if look.Magnitude < 0.01 then look = f end
    else
        look = moving and dir or project(lastLook, surfaceUp)
        if look.Magnitude < 0.05 then look = f end
    end
    look = look.Unit
    lastLook = look
    return CFrame.fromMatrix(Vector3.zero, look:Cross(surfaceUp), surfaceUp, -look)
end

local function updateLean(baseRot, vel, isJumping, vertVel, dt)
    local localVel = baseRot:VectorToObjectSpace(vel)
    local scale = math.clamp(cfg.speed, 16, 80)
    local targetRoll = math.clamp(-localVel.X / scale, -1, 1) * math.rad(6)
    local targetPitch = 0
    if isJumping then
        targetPitch = math.clamp(-vertVel / 80, -0.25, 0.25) * math.rad(8)
    end
    local k = 1 - math.exp(-14 * dt / cfg.smooth)
    leanRoll = leanRoll + (targetRoll - leanRoll) * k
    leanPitch = leanPitch + (targetPitch - leanPitch) * k
    return CFrame.Angles(leanPitch, 0, leanRoll)
end

local function steerRotation(root, goal, shiftLocked, dt)
    local rate = math.min((shiftLocked and 32 or 14) / cfg.smooth, 0.8 / dt)
    local current = root.CFrame.Rotation
    local delta = goal * current:Inverse()
    local axis, angle = delta:ToAxisAngle()
    if angle > math.pi then angle = angle - 2 * math.pi end
    local w = axis * (angle * rate)
    if w.Magnitude > MAX_TURN_RATE then w = w.Unit * MAX_TURN_RATE end
    root.AssemblyAngularVelocity = w
end

----------------------------------------------------------------------
-- Status text, normal/velocity/trail lines, reports
----------------------------------------------------------------------

local function surfaceLabel()
    if jumping then return "jump" end
    if not attached then return "air" end
    local y = up.Y
    if y > 0.85 then return "floor" end
    if y > 0.15 then return "slope" end
    if y >= -0.15 then return "wall" end
    if y > -0.85 then return "overhang" end
    return "ceiling"
end

local function surfaceColor()
    if jumping then return Color3.fromRGB(245, 195, 75) end
    if not attached then return Color3.fromRGB(160, 160, 175) end
    local y = up.Y
    if y > 0.85 then return Color3.fromRGB(110, 220, 150) end
    if y > 0.15 then return Color3.fromRGB(130, 210, 245) end
    if y >= -0.15 then return Color3.fromRGB(110, 168, 240) end
    return Color3.fromRGB(225, 120, 245)
end

local function drawWorldLine(lineObj, startWorld, endWorld, color, thickness, transparency)
    if not lineObj then
        lineObj = Drawing.new("Line")
        lineObj.Thickness = thickness or 2
        lineObj.Transparency = transparency or 0.85
    end
    local camObj = workspace.CurrentCamera
    if not camObj then
        lineObj.Visible = false
        return lineObj
    end
    local p1, vis1 = camObj:WorldToViewportPoint(startWorld)
    local p2, vis2 = camObj:WorldToViewportPoint(endWorld)
    if vis1 and vis2 and p1.Z > 0 and p2.Z > 0 then
        lineObj.From = Vector2.new(p1.X, p1.Y)
        lineObj.To = Vector2.new(p2.X, p2.Y)
        lineObj.Color = color
        lineObj.Transparency = transparency or 0.85
        lineObj.Visible = true
    else
        lineObj.Visible = false
    end
    return lineObj
end

local function updateTrail(root)
    if not (enabled and cfg.surfaceTrail and attached and root) then
        clearTrail()
        return
    end
    local lastPt = trailPoints[#trailPoints]
    if not lastPt or (root.Position - lastPt).Magnitude >= 1.2 then
        trailPoints[#trailPoints + 1] = root.Position
        if #trailPoints > TRAIL_MAX_POINTS then
            table.remove(trailPoints, 1)
        end
    end
    local col = surfaceColor()
    for i = 1, #trailPoints - 1 do
        local alpha = i / math.max(#trailPoints - 1, 1)
        trailLines[i] = drawWorldLine(trailLines[i], trailPoints[i], trailPoints[i + 1], col, 2, 0.35 + alpha * 0.55)
    end
    for i = #trailPoints, #trailLines do
        if trailLines[i] then trailLines[i].Visible = false end
    end
end

local function updateVisualLines(root)
    local active = enabled and attached and root ~= nil
    if not active then
        if normalRayLine then normalRayLine.Visible = false end
        if velRayLine then velRayLine.Visible = false end
        clearTrail()
        return
    end
    if cfg.normalLine then
        normalRayLine = drawWorldLine(normalRayLine, root.Position, root.Position + smoothUp * 3.5, surfaceColor(), 2, 0.85)
    elseif normalRayLine then
        normalRayLine.Visible = false
    end
    if cfg.velocityLine then
        local v = jumping and airVel or (curVel + extraVel)
        local dirLen = math.clamp(v.Magnitude * 0.12, 0.5, 8)
        local endPt = v.Magnitude > 0.5 and (root.Position + v.Unit * dirLen) or root.Position
        velRayLine = drawWorldLine(velRayLine, root.Position, endPt, Color3.fromRGB(255, 220, 95), 2, 0.85)
    elseif velRayLine then
        velRayLine.Visible = false
    end
    updateTrail(root)
end

local function updateHud(root)
    pcall(updateVisualLines, root)

    if not (enabled and cfg.hud) then
        if hud then hud.Visible = false end
        return
    end
    local now = time()
    if now < hudNext then return end
    hudNext = now + 0.1

    if not hud then
        hud = Drawing.new("Text")
        hud.Size = 16
        hud.Outline = true
        hud.Color = Color3.fromRGB(110, 168, 240)
        hud.Position = Vector2.new(20, 140)
        hud.Font = Drawing.Fonts.UI
    end
    local sp = (jumping and airVel or (curVel + extraVel)).Magnitude
    if sp > peakSpeed then peakSpeed = sp end
    local text = string.format("WALL WALK v%s   %s   %d studs/s (peak %d)",
        VERSION, surfaceLabel(), math.floor(sp + 0.5), math.floor(peakSpeed + 0.5))
    if lastSprinting then text = text .. "   SPRINT" end
    if wallChainStacks > 0 and (now - lastWallJumpAt) <= WALL_CHAIN_WINDOW then
        text = text .. string.format("   CHAIN x%d", wallChainStacks)
    end
    if cfg.doubleJump and jumping then
        text = text .. string.format("   AIRJ %d/%d", math.max(0, cfg.maxAirJumps - airJumpsUsed), cfg.maxAirJumps)
    end
    if cfg.speedCapEnabled then text = text .. string.format("   CAP %d", cfg.maxSpeedCap) end
    if now < dashReadyAt then
        text = text .. string.format("   DASH %.1fs", dashReadyAt - now)
    end
    if cfg.logLevel >= 2 then
        text = text .. string.format("   %.2fms  %.1f rays", stepMsEma, raysPerTick)
    end
    hud.Color = surfaceColor()
    hud.Text = text
    hud.Visible = true
end

local function compactSnapshot()
    local fps = nil
    pcall(function() fps = lw.fps() end)
    return string.format(
        "surf=%s up=%s spd=%.1f(peak=%.1f) ground=%.2f front=%.2f diag=%.2f herr=%.2f corr=%.1f anim=%s "
            .. "rays/tick=%.1f step=%.2fms(max %.2f) ticks/s=%.0f fps=%s",
        surfaceLabel(), fmtV(up), (jumping and airVel or (curVel + extraVel)).Magnitude, peakSpeed,
        lastGroundDist, lastFrontDist, lastDiagDist, lastHeightError, lastCorrection,
        tostring(currentAnim), raysPerTick, stepMsEma, stepMsMax, tickRate,
        fps and string.format("%.0f", fps) or "?")
end

local function makeSnapshot()
    local _, root, hum = parts()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add(string.format("version=%s time=%.2f", VERSION, time()))
    add(string.format("enabled=%s attached=%s jumping=%s airJumpsUsed=%d chain=%d surface=%s blocked=%s",
        tostring(enabled), tostring(attached), tostring(jumping), airJumpsUsed, wallChainStacks,
        surfaceLabel(), tostring(hum and blockedReason(hum))))
    add(string.format("up=%s smoothUp=%s", fmtV(up), fmtV(smoothUp)))
    add(string.format("curVel=%s (%.1f) extraVel=%.1f airVel=%s (%.1f) peakSpeed=%.1f",
        fmtV(curVel), curVel.Magnitude, extraVel.Magnitude, fmtV(airVel), airVel.Magnitude, peakSpeed))
    add(string.format("stats: wraps=%d jumps=%d airJumps=%d dashes=%d snapRecovers=%d errors=%d",
        wrapCount, jumpCount, airJumpCount, dashCount, snapRecoverCount, errorTotal))
    if root then
        add(string.format("root pos=%s vel=%s ang=%s", fmtV(root.Position),
            fmtV(root.AssemblyLinearVelocity), fmtV(root.AssemblyAngularVelocity)))
    else
        add("root=nil (no character)")
    end
    if hum then
        local ps, ar, health, sit
        pcall(function()
            ps = hum.PlatformStand
            ar = hum.AutoRotate
            health = hum.Health
            sit = hum.Sit
        end)
        add(string.format("humanoid state=%s platformStand=%s autoRotate=%s health=%s sit=%s",
            tostring(humState and humState.Name), tostring(ps), tostring(ar), tostring(health), tostring(sit)))
    end
    local parts_n = 0
    for _ in pairs(collideSaved) do parts_n = parts_n + 1 end
    add(string.format("collision off on %d parts (flag=%s)", parts_n, tostring(isNoColliding)))
    add(string.format("last rays: ground=%.2f front=%.2f diag=%.2f heightError=%.2f spring=%.1f",
        lastGroundDist, lastFrontDist, lastDiagDist, lastHeightError, lastCorrection))
    add(string.format("anchor active=%s  noAttachUntil=%.2f  dashReadyAt=%.2f  missSince=%s",
        tostring(anchorHit ~= nil and time() < anchorUntil), noAttachUntil, dashReadyAt, tostring(missSince)))
    add(string.format("camera baseFov=%s appliedFov=%s shiftLocked=%s",
        tostring(baseFov), tostring(appliedFov), tostring(isShiftLocked())))
    local names = {}
    for n in pairs(tracks) do names[#names + 1] = n end
    table.sort(names)
    add(string.format("animations rig=[%s] current=%s loaded=[%s]",
        detectedRigLabel, tostring(currentAnim), table.concat(names, ",")))
    add(compactSnapshot())
    return table.concat(lines, "\n")
end

local function dumpReport(reason)
    local out = {}
    out[#out + 1] = "===== WALL WALK DEBUG REPORT (" .. tostring(reason) .. ") ====="
    local ok, snap = pcall(makeSnapshot)
    out[#out + 1] = ok and snap or ("snapshot failed: " .. tostring(snap))
    out[#out + 1] = "--- settings ---"
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = string.format("%s = %s", k, tostring(cfg[k]))
    end
    out[#out + 1] = "--- last events (oldest first) ---"
    for _, l in ipairs(logBuffer) do out[#out + 1] = l end
    out[#out + 1] = "===== END ====="
    local text = table.concat(out, "\n")
    print(text)
    local wrote = pcall(writefile, REPORT_FILE, text)
    pcall(lw.log, wrote and ("Debug report written to " .. REPORT_FILE) or "Debug report printed (could not write the file)",
        wrote and "success" or "warn")
end

local function periodicLogs(now)
    if stepMsEma > 5 then
        logW("perf", string.format("slow steps: average %.2f ms (max %.2f)", stepMsEma, stepMsMax), 5)
    end
    if not enabled or cfg.logLevel < 2 then return end
    local interval = cfg.logLevel >= 3 and 1.0 or 3.0
    if now - lastSnapshotAt < interval then return end
    tickRate = ticksSince / math.max(now - lastSnapshotAt, 0.001)
    ticksSince = 0
    lastSnapshotAt = now
    logV("snapshot", compactSnapshot(), 0)
    stepMsMax = 0
end

----------------------------------------------------------------------
-- Character events
----------------------------------------------------------------------

me.CharacterAdded:Connect(function(c)
    logE("character", "character added: " .. tostring(c and c.Name))
end)

me.CharacterRemoving:Connect(function()
    if humStateConn then
        pcall(function() humStateConn:Disconnect() end)
        humStateConn = nil
    end
    anchorHit = nil
    anchorUntil = 0
    anchorLogged = false
    isNoColliding = false
    appliedShiftOffset = false
    appliedFov = false
    baseFov = nil
    table.clear(collideSaved)
    attached = false
    lastSurface = nil
    lastPos = nil
    lastAppliedVel = Vector3.zero
    curVel = Vector3.zero
    extraVel = Vector3.zero
    airVel = Vector3.zero
    jumpStarted = 0
    leanPitch = 0
    leanRoll = 0
    up = WORLD_UP
    smoothUp = WORLD_UP
    missSince = nil
    noAttachUntil = 0
    jumping = false
    airJumpsUsed = 0
    wallChainStacks = 0
    loadedFor = nil
    detectedRigLabel = "unknown"
    destroyVisuals()
    logE("character", "character removing, state reset")
end)

----------------------------------------------------------------------
-- Main step
----------------------------------------------------------------------

local function wishVector(cam, fwd, side)
    local f = project(cam.LookVector, WORLD_UP)
    if f.Magnitude < 0.05 then f = project(cam.UpVector, WORLD_UP) end
    if f.Magnitude < 0.05 then f = Vector3.new(0, 0, -1) end
    f = f.Unit
    local r = project(cam.RightVector, WORLD_UP)
    if r.Magnitude < 0.05 then r = WORLD_UP:Cross(f) end
    r = r.Unit
    local w = f * fwd + r * side
    if w.Magnitude > 1 then w = w.Unit end
    return w
end

local function boundKey(name, fallback)
    if ui.ready then
        local el = ui.els[name]
        if el then
            local ok, key = pcall(function() return el:get() end)
            if ok then return key end
        end
    end
    return fallback
end

local function step(dt)
    if not alive then return end
    if not enabled then
        updateCameraEffects(workspace.CurrentCamera, false, 0, dt)
        if time() < releaseUntil then
            local _, _, hum = parts()
            if hum then
                pcall(function()
                    hum.PlatformStand = false
                    hum.AutoRotate = true
                end)
            end
        end
        return
    end

    dt = math.clamp(dt or 1 / 60, 1 / 240, 0.05)
    snapshotLoading = false
    local char, root, hum = parts()
    local camObj = workspace.CurrentCamera
    if not char or not camObj then
        logW("context", "missing character or CurrentCamera", 2.0)
        return
    end
    if hum.Health <= 0 then
        if attached or jumping then detach(root, hum, char, false, "humanoid died") end
        return
    end

    if lastPos and (attached or jumping) then
        local movedDist = (root.Position - lastPos).Magnitude
        local expectedMaxDist = math.max(lastAppliedVel.Magnitude * dt * 2.5 + 14, 40)
        if movedDist > expectedMaxDist and lastAppliedVel.Magnitude > 55 then
            snapRecoverCount = snapRecoverCount + 1
            logW("tp_snap", string.format("large position jump %.1f studs at vel %.1f (recover=%s)",
                movedDist, lastAppliedVel.Magnitude, tostring(cfg.autoRecoverSnap)), 1.0)
            if cfg.autoRecoverSnap then
                curVel = curVel * 0.25
                extraVel = Vector3.zero
                airVel = airVel * 0.25
                lastAppliedVel = Vector3.zero
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end
    end
    lastPos = root.Position

    local now = time()
    if wallChainStacks > 0 and (now - lastWallJumpAt) > WALL_CHAIN_WINDOW then
        wallChainStacks = 0
    end

    local hover = cfg.hover
    local cam = camObj.CFrame

    local blocked = blockedReason(hum)
    if blocked then
        if attached or jumping then detach(root, hum, char, false, "paused: " .. blocked) end
        logV("paused", "paused while " .. blocked, 2.0)
        updateCameraEffects(camObj, false, 0, dt)
        if cfg.detachedAnims then
            if blocked == "seated" then setAnim("sit", 0.15, 1) else setAnim("swim", 0.16, 1) end
        else
            setAnim(nil, 0.12)
        end
        return
    end

    local g = getGravity()

    local focused = windowFocused()
    if focused ~= lastFocused then
        lastFocused = focused
        logV("focus", focused and "game window focused" or "game window lost focus, input ignored")
    end
    local fwd, side = 0, 0
    local sprinting = false
    if focused then
        fwd = (keyDown("W") and 1 or 0) - (keyDown("S") and 1 or 0)
        side = (keyDown("D") and 1 or 0) - (keyDown("A") and 1 or 0)
        local hasMoveInput = (fwd ~= 0 or side ~= 0)
        local sprintKey = boundKey("sprint", cfg.sprintKey)
        sprinting = keyDown(sprintKey) or (cfg.autoSprint and hasMoveInput)
    end
    if sprinting ~= lastSprinting then
        logV("sprint", sprinting and "sprint on" or "sprint off", 0.2)
    end
    lastSprinting = sprinting
    local spaceJust = edge("space", focused and spaceIsDown())
    local dashJust = edge("dash", focused and keyDown(boundKey("dash", cfg.dashKey)))
    local dropJust = edge("drop", focused and keyDown(boundKey("drop", cfg.dropKey)))
    local snapFloorJust = edge("snapfloor", focused and keyDown(boundKey("snap", cfg.snapGroundKey)))
    local resetStatsJust = edge("resetstats", focused and keyDown(boundKey("reset", cfg.resetStatsKey)))

    if resetStatsJust then
        peakSpeed = 0
        wrapCount = 0
        jumpCount = 0
        airJumpCount = 0
        dashCount = 0
        snapRecoverCount = 0
        airJumpsUsed = 0
        wallChainStacks = 0
        clearTrail()
        logE("reset_stats", "session stats reset", 0.25)
    end

    if snapFloorJust then
        detach(root, hum, char, true, "snap to floor key")
        return
    end

    local surfMult = getSurfaceSpeedMult(up)
    local moveSpeed = cfg.speed * (sprinting and cfg.sprintMult or 1) * surfMult
    if cfg.speedCapEnabled and cfg.maxSpeedCap > 0 then
        moveSpeed = math.min(moveSpeed, cfg.maxSpeedCap)
    end

    local f, r = getSurfaceBasis(cam, up)
    local move = f * fwd + r * side
    local moving = move.Magnitude > 0.01
    local dir = moving and move.Unit or Vector3.zero
    if jumping then
        local wish = wishVector(cam, fwd, side)
        if wish.Magnitude > 0.01 then
            dir = wish.Unit
            moving = true
        end
    end

    if dropJust and (attached or jumping) then
        local v = jumping and airVel or (curVel + extraVel + up * 6)
        detach(root, hum, char, false, "let go key")
        applySafeVelocity(root, v, dt)
        noAttachUntil = now + 0.5
        return
    end
    if not attached and now < noAttachUntil then
        restoreCollide()
        updateCameraEffects(camObj, true, 0, dt)
        logT("noattach", string.format("not grabbing surfaces for %.2fs more", noAttachUntil - now), 0.25)
        return
    end

    if not attached and not jumping and cfg.autoReattach and now >= noAttachUntil then
        local fallProbe = cast(char, root.Position, -WORLD_UP * (hover + 3.5))
        if fallProbe and surfaceAllowed(fallProbe.Normal) then
            up = fallProbe.Normal
            smoothUp = up
            attached = true
            airJumpsUsed = 0
            logOK("auto_reattach", string.format("reattached to surface normal=%s dist=%.2f", fmtV(up), fallProbe.Distance), 0.3)
        end
    end

    if spaceJust and attached and not jumping then
        local from = surfaceLabel()
        local steep = math.abs(up.Y) < 0.7
        local push = steep and cfg.wallJumpOutward or 0
        if steep and cfg.wallChain then
            if (now - lastWallJumpAt) <= WALL_CHAIN_WINDOW then
                wallChainStacks = math.min(wallChainStacks + 1, 5)
            else
                wallChainStacks = 1
            end
            lastWallJumpAt = now
            local chainDir = moving and dir or project(lastLook, up)
            if chainDir.Magnitude > 0.05 then
                extraVel = extraVel + chainDir.Unit * (cfg.wallChainBoost * wallChainStacks)
            end
        end
        -- Gravity stays on world up. The old jump accelerated along the surface
        -- normal, so a wall jump fell back into the wall it left.
        local launch
        if cfg.leap then
            launch = cam.LookVector * cfg.jumpPower
            if steep then launch = launch + up * push end
        else
            launch = WORLD_UP * cfg.jumpPower
            if steep then launch = launch + up * push end
            launch = launch + curVel + extraVel
        end
        airVel = launch
        curVel = Vector3.zero
        extraVel = Vector3.zero
        jumping = true
        jumpStarted = now
        airJumpsUsed = 0
        jumpCount = jumpCount + 1
        jumpGraceUntil = now + 0.22
        restoreCollide()
        setAnim("jump", 0.08, 1)
        logE("jump", string.format("jump off %s: vel=%s chain=%d wallPush=%.0f",
            from, fmtV(airVel), wallChainStacks, push), 0.25)
    elseif spaceJust and jumping and cfg.doubleJump and airJumpsUsed < cfg.maxAirJumps then
        airJumpsUsed = airJumpsUsed + 1
        airJumpCount = airJumpCount + 1
        local horiz = project(airVel, WORLD_UP)
        local vy = math.max(airVel.Y, 0) * 0.35 + cfg.airJumpPower
        if moving then
            horiz = horiz:Lerp(dir * math.max(moveSpeed, horiz.Magnitude), 0.65)
        elseif cfg.leap then
            local v = project(cam.LookVector * cfg.airJumpPower, WORLD_UP)
            if v.Magnitude > 0.1 then horiz = v end
        end
        airVel = horiz + Vector3.new(0, vy, 0)
        jumpGraceUntil = now + 0.16
        setAnim("jump", 0.05, 1.15)
        logE("air_jump", string.format("air jump #%d/%d power=%.0f", airJumpsUsed, cfg.maxAirJumps, vy), 0.2)
    end

    if dashJust and (attached or jumping) then
        if now < dashReadyAt then
            logV("dash", string.format("dash on cooldown (%.2fs left)", dashReadyAt - now), 0.3)
        else
            local d = moving and dir or project(lastLook, up)
            if d.Magnitude > 0.01 then
                local power = cfg.dashPower
                if cfg.speedCapEnabled and cfg.maxSpeedCap > 0 then
                    power = math.min(power, cfg.maxSpeedCap)
                end
                if jumping then
                    airVel = airVel + d.Unit * power
                else
                    extraVel = d.Unit * power
                end
                dashCount = dashCount + 1
                dashReadyAt = now + cfg.dashCooldown
                logE("dash", string.format("dash power=%.0f dir=%s cooldown=%.1fs", power, fmtV(d.Unit), cfg.dashCooldown), 0.25)
            end
        end
    end

    local pos = root.Position
    local reach = hover + 2.5
    local hit = nil

    if jumping then
        if now >= jumpGraceUntil then
            local downHit = cast(char, pos, -WORLD_UP * (hover + 5))
            lastGroundDist = downHit and downHit.Distance or -1
            local land = nil
            if downHit and downHit.Distance <= hover + 1.05 and airVel.Y <= 4 and surfaceAllowed(downHit.Normal) then
                land = downHit
            elseif airVel.Magnitude > 10 then
                local velHit = cast(char, pos, airVel.Unit * math.min(hover + 2.5, 8))
                if velHit and velHit.Distance <= hover + 0.9 and airVel:Dot(velHit.Normal) < -6
                    and surfaceAllowed(velHit.Normal) then
                    land = velHit
                end
            end
            if land then
                up = land.Normal
                hit = land
                curVel = project(airVel, up)
                extraVel = Vector3.zero
                airVel = Vector3.zero
                jumping = false
                airJumpsUsed = 0
                logE("landed", string.format("landed on %s (dist=%.2f)", surfaceLabel(), land.Distance), 0.25)
            end
        else
            lastGroundDist = -1
        end
    elseif now >= jumpGraceUntil then
        hit = cast(char, pos, -up * reach)
        lastGroundDist = hit and hit.Distance or -1
    else
        lastGroundDist = -1
    end

    local travel = jumping and airVel or (curVel + extraVel)
    local lead = math.min(travel.Magnitude * dt * 1.65, 48)

    local switched = false
    lastFrontDist, lastDiagDist = -1, -1
    local allowStick = not (jumping and now < jumpGraceUntil)
    if moving and allowStick then
        local front = cast(char, pos, dir * (hover + 2.0 + lead))
        lastFrontDist = front and front.Distance or -1
        local frontClose = front and front.Distance <= hover + 0.75 + lead and front.Normal:Dot(up) < 0.85

        if frontClose and surfaceAllowed(front.Normal) then
            local prevUp = up
            local incoming = jumping and airVel or curVel
            local keptSpeed = incoming.Magnitude * cfg.momentumKeep
            up = front.Normal
            airVel = Vector3.zero
            jumping = false
            airJumpsUsed = 0
            hit = cast(char, pos, -up * reach) or front
            switched = true
            if keptSpeed > 1 then
                local alongNew = project(dir, up)
                if alongNew.Magnitude > 0.05 then
                    curVel = alongNew.Unit * math.max(keptSpeed, curVel.Magnitude * 0.5)
                end
            end
            logE("front", string.format("front surface dist=%.2f normal=%s turn=%.0fdeg", front.Distance, fmtV(up),
                math.deg(math.acos(math.clamp(prevUp:Dot(up), -1, 1)))), 0.3)
        else
            if frontClose then
                logV("blocked", string.format("front surface ignored by the walls/ceilings setting, normal=%s", fmtV(front.Normal)), 1.5)
            end
            local diagDir = (dir + up * 0.65).Unit
            local diagHit = cast(char, pos, diagDir * (hover + 2.2 + lead))
            lastDiagDist = diagHit and diagHit.Distance or -1

            if diagHit and diagHit.Distance <= hover + 1.0 + lead
                and diagHit.Normal:Dot(up) < 0.85 and surfaceAllowed(diagHit.Normal) then
                local incoming = jumping and airVel or curVel
                up = diagHit.Normal
                if incoming.Magnitude > curVel.Magnitude then
                    curVel = project(incoming, up)
                end
                airVel = Vector3.zero
                jumping = false
                airJumpsUsed = 0
                hit = cast(char, pos, -up * reach) or diagHit
                switched = true
                logE("diag", string.format("diagonal surface dist=%.2f normal=%s", diagHit.Distance, fmtV(up)), 0.3)
            elseif not jumping and attached and cfg.innerCorner then
                local innerHit = findInnerCorner(char, pos, dir, up, lead)
                if innerHit and innerHit.Distance <= hover + 1.2 + lead
                    and innerHit.Normal:Dot(up) < 0.85 and surfaceAllowed(innerHit.Normal) then
                    up = innerHit.Normal
                    hit = innerHit
                    switched = true
                    logE("corner", string.format("inner corner dist=%.2f normal=%s", innerHit.Distance, fmtV(up)), 0.3)
                end
            end
        end

        if not switched and not jumping and attached and cfg.wrap then
            local needWrap = hit == nil
            if hit then
                needWrap = cast(char, pos + dir * (1.6 + lead), -up * reach) == nil
            end
            if needWrap then
                local prevUp = up
                local wrap, how = findWrap(char, pos, dir, up, lead)
                if wrap and surfaceAllowed(wrap.Normal) then
                    up = wrap.Normal
                    hit = wrap
                    anchorHit = wrap
                    anchorUntil = now + 0.4
                    anchorLogged = false
                    wrapCount = wrapCount + 1
                    if cfg.mantleBoost then
                        local push = project(-prevUp, wrap.Normal)
                        if push.Magnitude > 0.1 then
                            extraVel = extraVel + push.Unit * 10
                        end
                    end
                    logE("wrap", string.format("wrapped onto normal=%s via %s dist=%.2f", fmtV(up), how, wrap.Distance), 0.3)
                elseif wrap then
                    logV("blocked", string.format("wrap surface ignored by the walls/ceilings setting, normal=%s", fmtV(wrap.Normal)), 1.5)
                else
                    logV("wrap_none", "edge ahead but no surface found to wrap onto", 0.6)
                end
            end
        end
    end

    local usingAnchor = false
    if anchorHit and now < anchorUntil and attached and not jumping then
        if hit == anchorHit then
            usingAnchor = true
        elseif not hit then
            hit = anchorHit
            usingAnchor = true
        elseif (anchorHit.Position - hit.Position):Dot(anchorHit.Normal) > 1.0 then
            hit = anchorHit
            usingAnchor = true
        elseif hit.Normal:Dot(anchorHit.Normal) > 0.8 then
            anchorUntil = 0
            logV("anchor", "anchor released: standing on the new surface")
        end
        if usingAnchor and not anchorLogged then
            anchorLogged = true
            logV("anchor", string.format("using anchor surface (%.2fs left)", anchorUntil - now))
        end
    end

    local shiftLocked = isShiftLocked()
    local wantOffset = shiftLocked and cfg.extraOffset
    local totalSpeed = (jumping and airVel or (curVel + extraVel)).Magnitude
    local speedRatio = totalSpeed / math.max(cfg.speed, 1)

    if jumping then
        if now - lastAssert > 0.2 then
            lastAssert = now
            pcall(function()
                hum.PlatformStand = true
                hum.AutoRotate = false
            end)
        end
        syncShiftLockOffset(hum, wantOffset)
        updateCameraEffects(camObj, true, speedRatio, dt)

        if now - jumpStarted > 6 then
            local near = cast(char, pos, -WORLD_UP * 40)
            if not near then
                local v = airVel
                detach(root, hum, char, false, "air time")
                applySafeVelocity(root, v, dt)
                noAttachUntil = now + 0.35
                return
            end
        end

        local smooth = math.max(cfg.smooth, 0.25)
        local kAir = (1 - math.exp(-8 * dt / smooth)) * cfg.airControl
        local horiz = project(airVel, WORLD_UP)
        local vert = airVel.Y - g * dt
        if moving then
            horiz = horiz:Lerp(dir * moveSpeed, kAir)
        else
            horiz = horiz * math.exp(-1.5 * dt)
        end
        airVel = horiz + Vector3.new(0, vert, 0)
        smoothUp = smoothUp:Lerp(WORLD_UP, 1 - math.exp(-10 * dt))
        if smoothUp.Magnitude < 0.01 then smoothUp = WORLD_UP end
        smoothUp = smoothUp.Unit

        local faceF, _faceR = getSurfaceBasis(cam, WORLD_UP)
        local baseGoal = computeFacing(cam, shiftLocked, moving, dir, faceF, WORLD_UP)
        local lean = updateLean(baseGoal, airVel, true, airVel.Y, dt)
        steerRotation(root, baseGoal * lean, shiftLocked, dt)

        applySafeVelocity(root, airVel, dt)
        if cfg.logLevel >= 3 then
            logT("trace", string.format("air vel=%s ground=%.2f", fmtV(airVel), lastGroundDist), 0.25)
        end
        setAnim("jump", 0.08, 1)
        return
    end

    if not hit then
        if snapshotLoading then
            logW("world", "world snapshot still loading, holding on", 2)
            return
        end
        if not attached then
            restoreCollide()
            updateCameraEffects(camObj, true, speedRatio, dt)
            if cfg.detachedAnims then
                setAnim(nil, 0.12)
            end
            return
        end
        missSince = missSince or now
        local grace = 0.16 * math.clamp(cfg.surfaceGrip, 0.5, 2.0)
        if now - missSince < grace then
            local antiDrop = WORLD_UP * math.max(0, -root.AssemblyLinearVelocity.Y) * 0.65
            applySafeVelocity(root, curVel + extraVel + antiDrop, dt)
            root.AssemblyAngularVelocity = Vector3.zero
            updateCameraEffects(camObj, true, speedRatio, dt)
            logT("miss", string.format("surface lost, grace %.2fs of %.2fs", now - missSince, grace), 0.1)
            return
        end
        detach(root, hum, char, false, string.format("surface lost for %.2fs (ray length %.1f)", now - missSince, reach))
        return
    end

    missSince = nil
    airJumpsUsed = 0
    noCollide(char)

    if not attached or now - lastAssert > 0.2 then
        lastAssert = now
        local ps, ar
        pcall(function()
            ps = hum.PlatformStand
            ar = hum.AutoRotate
        end)
        if attached and (ps == false or ar == true) then
            logV("reassert", string.format("game changed humanoid (PlatformStand=%s AutoRotate=%s), setting it again", tostring(ps), tostring(ar)), 1.0)
        end
        pcall(function()
            hum.PlatformStand = true
            hum.AutoRotate = false
        end)
        isNoColliding = false
        local again = noCollide(char)
        if attached and again > 0 then
            logV("collide", string.format("game re-enabled collision on %d parts, switched off again", again), 1.0)
        end
    end
    syncShiftLockOffset(hum, wantOffset)

    local samples = 0
    if usingAnchor then
        up = hit.Normal
    else
        local bf, br = getSurfaceBasis(cam, hit.Normal)
        up, samples = sampleNormal(char, pos, hit, hit.Normal, bf, br, reach)
    end
    f, r = getSurfaceBasis(cam, up)
    move = f * fwd + r * side
    moving = move.Magnitude > 0.01
    dir = moving and move.Unit or Vector3.zero

    local normRate = (shiftLocked and 24 or 16) * math.clamp(cfg.surfaceGrip, 0.5, 2.0)
    local kNorm = 1 - math.exp(-normRate * dt / cfg.smooth)
    if not attached then
        smoothUp = up
        logOK("attach", string.format("attached (hover=%d dist=%.2f normal=%s)", hover, hit.Distance, fmtV(up)), 0.4)
    end
    attached = true
    smoothUp = smoothUp:Lerp(up, kNorm)
    if smoothUp.Magnitude < 0.01 then smoothUp = up end
    smoothUp = smoothUp.Unit

    local surfName = surfaceLabel()
    if surfName ~= lastSurface then
        logE("surface", string.format("%s -> %s", tostring(lastSurface), surfName), 0.2)
        lastSurface = surfName
    end

    local kVel = 1 - math.exp(-(moving and 24 or (cfg.clingWhenIdle and 28 or 18)) * dt / cfg.smooth)
    local targetVel = moving and (dir * moveSpeed) or Vector3.zero
    local projectedCur = project(curVel, up)
    if not moving and cfg.clingWhenIdle and extraVel.Magnitude < 0.5 then
        curVel = projectedCur * math.exp(-24 * dt)
        if curVel.Magnitude < 0.15 then curVel = Vector3.zero end
    elseif moving and cfg.momentumKeep > 0 and projectedCur.Magnitude > targetVel.Magnitude then
        projectedCur = projectedCur:Lerp(targetVel, math.min(kVel, (1 - cfg.momentumKeep * 0.5)))
        curVel = projectedCur
    else
        curVel = projectedCur:Lerp(targetVel, kVel)
    end
    if not moving and curVel.Magnitude < 0.2 then curVel = Vector3.zero end

    extraVel = project(extraVel, up) * math.exp(-cfg.dashDecay * dt)
    if extraVel.Magnitude < 0.5 then extraVel = Vector3.zero end

    local baseGoal = computeFacing(cam, shiftLocked, moving, dir, f, smoothUp)
    local lean = updateLean(baseGoal, curVel + extraVel, false, 0, dt)
    steerRotation(root, baseGoal * lean, shiftLocked, dt)

    local currentDist = (pos - hit.Position):Dot(up)
    local heightError = hover - currentDist
    local gain = math.min(28 * cfg.surfaceGrip, 1.0 / dt)
    local correction = math.clamp(heightError * gain, -65, 65)
    lastHeightError = heightError
    lastCorrection = correction
    if math.abs(heightError) > 2.5 then
        logV("height", string.format("large height error %.2f (dist=%.2f hover=%d)", heightError, currentDist, hover), 1.0)
    end

    local lateralPull = Vector3.zero
    if usingAnchor then
        local toAnchor = project(hit.Position - pos, up)
        local dist = toAnchor.Magnitude
        if dist > 0.3 then
            lateralPull = toAnchor.Unit * math.min(dist * 10 * cfg.surfaceGrip, 32)
        end
    end

    local currentSpeed = (curVel + extraVel).Magnitude
    applySafeVelocity(root, curVel + extraVel + lateralPull + up * correction, dt)
    updateCameraEffects(camObj, true, currentSpeed / math.max(cfg.speed, 1), dt)

    if cfg.logLevel >= 3 then
        logT("trace", string.format("%s ground=%.2f front=%.2f diag=%.2f herr=%.2f spring=%.1f spd=%.1f samples=%d anchor=%s",
            surfName, lastGroundDist, lastFrontDist, lastDiagDist, heightError, correction, currentSpeed, samples, tostring(usingAnchor)), 0.25)
    end

    local walking = moving or currentSpeed > (currentAnim == "walk" and 0.6 or 1.5)
    if walking then
        local anim = math.abs(up.Y) < 0.55 and "climb" or "walk"
        setAnim(anim, 0.16, math.clamp(currentSpeed / 16, 0.35, 6))
    else
        setAnim("idle", 0.16, 1)
    end
end

----------------------------------------------------------------------
-- Tick wrapper, errors and performance
----------------------------------------------------------------------

local errorStreak = 0

local function onStepError(e)
    return tostring(e) .. "\n" .. debug.traceback("", 2)
end

RunService.Heartbeat:Connect(function(dt)
    ticksSince = ticksSince + 1
    local _, root = parts()

    if edge("dumpkey", windowFocused() and keyDown(cfg.dumpKey)) then
        pcall(dumpReport, "key")
    end

    local t0 = os.clock()
    local rays0 = rayCount
    local ok, err = xpcall(step, onStepError, dt)
    local ms = (os.clock() - t0) * 1000
    stepMsEma = stepMsEma * 0.95 + ms * 0.05
    if ms > stepMsMax then stepMsMax = ms end
    raysPerTick = raysPerTick * 0.95 + (rayCount - rays0) * 0.05

    if ok then
        errorStreak = 0
    else
        errorStreak = errorStreak + 1
        errorTotal = errorTotal + 1
        if errorStreak == 1 then
            logX("step_error", tostring(err), 1.0)
            pcall(dumpReport, "step error")
        end
        if errorStreak >= 30 then
            errorStreak = 0
            pcall(setEnabled, false)
            logX("auto_off", "turned off after 30 errors in a row, see wallwalk_report.txt", 1.0)
            pcall(dumpReport, "auto off")
        end
    end

    pcall(updateHud, root)
    pcall(periodicLogs, time())
end)

----------------------------------------------------------------------
-- Settings loop. Runs every tick: widgets must be declared every time.
----------------------------------------------------------------------

logE("start", string.format("wall walk v%s loaded", VERSION))

while true do
    local okRead, readErr = pcall(readSettings)
    if not okRead then
        logX("settings", "readSettings failed: " .. tostring(readErr), 2.0)
    else
        pcall(diffSettings)
    end

    if enabled then
        local char, _, hum = parts()
        if char and hum and hum ~= loadedFor then
            local ok, err = pcall(loadAnims, char, hum)
            if not ok then
                logX("anims", "loadAnims failed: " .. tostring(err), 2.0)
            end
        end
    end

    local okKey, pressed = pcall(function()
        return cfg.toggleKey and lw.keyPressed(cfg.toggleKey)
    end)
    if not okKey then
        logX("toggle_key", "toggle key check failed: " .. tostring(pressed), 2.0)
    elseif pressed then
        setEnabled(not enabled)
    end

    task.wait()
end
