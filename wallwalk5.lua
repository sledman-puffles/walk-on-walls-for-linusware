-- Spider-Man wall walk for LinusWare (v5)
--
-- Toggle with the keybind in the SETTINGS card (default Z). Stop any older
-- wallwalk script before running this one.
--
-- Movement
--   WASD            move, relative to the camera. Look at a wall and press W to climb it.
--   Space           jump relative to the surface you are on
--   Sprint (hold)   faster movement (default Left Ctrl)
--   Dash            burst of speed in the direction you are moving (default F)
--   Let go          drop off the surface and fall (default X)
-- Walk into a wall, ceiling or slope to climb it, walk off an edge to wrap around
-- it, or climb over the top of a wall onto the roof.
--
-- All keys are rebindable in the SETTINGS card, together with speed, smoothness,
-- which surfaces to climb and the shift lock options.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local me = Players.LocalPlayer

local WORLD_UP = Vector3.new(0, 1, 0)
local SHIFT_LOCK_OFFSET = Vector3.new(1.75, 0, 0)
local MAX_TURN_RATE = 40 -- rad/s

-- earlier versions bound a render step; make sure none is left over
pcall(function() RunService:UnbindFromRenderStep("LW_WallWalk_Render") end)

----------------------------------------------------------------------
-- Settings. Everything the SETTINGS card controls lives in this table.
----------------------------------------------------------------------

local cfg = {
    toggleKey = Enum.KeyCode.Z,
    sprintKey = nil,
    dashKey = nil,
    dropKey = nil,
    speed = 16,
    sprintMult = 1.8,
    jumpPower = 55,
    dashPower = 70,
    hover = 3,
    smooth = 1,
    airControl = 1,
    walls = true,
    ceilings = true,
    wrap = true,
    leap = false,
    forceShiftLock = false,
    extraOffset = false,
    hud = true,
}

local function readSettings()
    cfg.toggleKey = lw.keybind("Wall walk key", Enum.KeyCode.Z)
    cfg.sprintKey = lw.keybind("Sprint key (hold)", Enum.KeyCode.LeftControl)
    cfg.dashKey = lw.keybind("Dash key", Enum.KeyCode.F)
    cfg.dropKey = lw.keybind("Let go key", Enum.KeyCode.X)

    cfg.speed = lw.slider("Walk speed", 16, 4, 500)
    cfg.sprintMult = lw.slider("Sprint multiplier", 1.8, 1, 5, 1)
    cfg.jumpPower = lw.slider("Jump off power", 55, 10, 500)
    cfg.dashPower = lw.slider("Dash power", 70, 20, 400)
    cfg.hover = lw.slider("Hover height", 3, 2, 10, 1)
    cfg.smooth = lw.slider("Smoothness", 1, 0.1, 5, 1)
    cfg.airControl = lw.slider("Air control", 1, 0, 1, 2)

    cfg.walls = lw.toggle("Climb walls", true)
    cfg.ceilings = lw.toggle("Climb ceilings", true)
    cfg.wrap = lw.toggle("Wrap around edges", true)
    cfg.leap = lw.toggle("Jump toward camera", false)
    cfg.forceShiftLock = lw.toggle("Shift lock mode (face camera)", false)
    cfg.extraOffset = lw.toggle("Extra shift lock camera offset", false)
    cfg.hud = lw.toggle("Show status text", true)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local enabled = false
local attached = false -- true while we are driving the character on a surface
local up = WORLD_UP
local smoothUp = WORLD_UP
local lastLook = Vector3.new(0, 0, -1)
local anchorHit = nil -- the surface we just wrapped onto (ledge climbs)
local anchorUntil = 0
local missSince = nil
local collideSaved = {}
local isNoColliding = false
local lastAssert = 0
local releaseUntil = 0
local noAttachUntil = 0 -- after letting go, don't grab a surface straight away
local curVel = Vector3.zero -- smoothed velocity along the surface
local extraVel = Vector3.zero -- dash burst, decays by itself
local dashReadyAt = 0
local leanPitch = 0
local leanRoll = 0
local savedCamOffset = Vector3.zero
local appliedShiftOffset = false
local lastSprinting = false
local wasDown = {}

-- jump state
local jumping = false
local jumpVel = 0
local jumpGraceUntil = 0

-- cached raycast parameters
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local cachedChar = nil

-- animations
local tracks = {}
local currentAnim = nil
local loadedFor = nil
local lastWalkSpeed = 1

-- status text
local hud = nil
local hudNext = 0

----------------------------------------------------------------------
-- Input helpers
----------------------------------------------------------------------

local function keyDown(key)
    if key == nil then return false end
    local ok, down = pcall(lw.isKeyDown, key)
    return ok and down == true
end

local function spaceIsDown()
    if keyDown("Space") then return true end
    local ok, res = pcall(function()
        return UserInputService:IsKeyDown(Enum.KeyCode.Space)
    end)
    return ok and res == true
end

local function windowFocused()
    if isrbxactive then
        local ok, res = pcall(isrbxactive)
        if ok then return res and true or false end
    end
    return true
end

-- true on the tick a key goes down
local function edge(name, down)
    local was = wasDown[name]
    wasDown[name] = down
    return down and not was
end

----------------------------------------------------------------------
-- Animations
----------------------------------------------------------------------

local function setAnim(name, fadeTime)
    if name == currentAnim then return end
    local fade = fadeTime or 0.16
    local old = tracks[currentAnim]
    if old then old:Stop(fade) end
    local new = tracks[name]
    if new then
        new:Play(fade, 1, 1)
    end
    currentAnim = name
end

local function loadAnims(char, hum)
    loadedFor = hum
    local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
    local r15 = char:FindFirstChild("UpperTorso") ~= nil
    -- default Roblox animation ids. If your game uses custom ones, swap them here.
    local ids = r15
        and {
            walk = "rbxassetid://507777826",
            idle = "rbxassetid://507766388",
            jump = "rbxassetid://507765000",
        }
        or {
            walk = "rbxassetid://180426354",
            idle = "rbxassetid://180435571",
            jump = "rbxassetid://125750702",
        }

    for _, track in tracks do
        track:Stop(0)
        track:Destroy()
    end
    tracks = {}
    currentAnim = nil

    for name, id in ids do
        local anim = Instance.new("Animation")
        anim.AnimationId = id
        local track = animator:LoadAnimation(anim)
        track.Looped = (name ~= "jump")
        if name == "jump" then
            track.Priority = Enum.AnimationPriority.Action
        end
        tracks[name] = track
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

local function getGravity()
    local ok, g = pcall(function()
        return workspace.Gravity
    end)
    if ok and type(g) == "number" and g > 0 then
        return g
    end
    return 196.2
end

local function isShiftLocked()
    if cfg.forceShiftLock then return true end
    local ok, behavior = pcall(function()
        return UserInputService.MouseBehavior
    end)
    if not ok or behavior ~= Enum.MouseBehavior.LockCenter then
        return false
    end
    local cam = workspace.CurrentCamera
    if cam and (cam.CFrame.Position - cam.Focus.Position).Magnitude < 1.5 then
        return false
    end
    return true
end

-- Optional: only touches the camera when "Extra shift lock camera offset" is on.
local function syncShiftLockOffset(hum, active)
    if not hum then return end
    if active then
        if not appliedShiftOffset then
            savedCamOffset = hum.CameraOffset
            appliedShiftOffset = true
        end
        hum.CameraOffset = hum.CameraOffset:Lerp(savedCamOffset + SHIFT_LOCK_OFFSET, 0.3)
    elseif appliedShiftOffset then
        hum.CameraOffset = savedCamOffset
        appliedShiftOffset = false
    end
end

local function noCollide(char)
    if isNoColliding then return end
    isNoColliding = true
    for _, part in char:GetDescendants() do
        if part:IsA("BasePart") and part.CanCollide then
            collideSaved[part] = true
            part.CanCollide = false
        end
    end
end

local function restoreCollide()
    if not isNoColliding then return end
    isNoColliding = false
    for part in collideSaved do
        if part and part.Parent then
            part.CanCollide = true
        end
    end
    table.clear(collideSaved)
end

local function cast(char, origin, direction)
    if cachedChar ~= char then
        cachedChar = char
        rayParams.FilterDescendantsInstances = { char }
    end
    return workspace:Raycast(origin, direction, rayParams)
end

-- Walls and ceilings can be switched off in the SETTINGS card.
local function surfaceAllowed(n)
    if n.Y < -0.7 then return cfg.ceilings end
    if n.Y <= 0.7 then return cfg.walls end
    return true
end

----------------------------------------------------------------------
-- Attach / detach
----------------------------------------------------------------------

-- Hand the character back to Roblox. With snapToGround (turning the script off)
-- it is stood upright on the floor below, stopped, and collisions come back
-- only after that. Falling off a surface keeps its momentum.
local function detach(root, hum, char, snapToGround)
    attached = false
    anchorUntil = 0
    up = WORLD_UP
    smoothUp = WORLD_UP
    curVel = Vector3.zero
    extraVel = Vector3.zero
    leanPitch = 0
    leanRoll = 0
    missSince = nil
    jumping = false
    jumpVel = 0
    setAnim(nil, snapToGround and 0.05 or 0.12)
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
        if snapToGround and char and hum then
            local okHip, hip = pcall(function() return hum.HipHeight end)
            local standHeight = ((okHip and type(hip) == "number") and hip or 2) + root.Size.Y / 2
            standHeight = math.max(standHeight, 3) -- R6 reports a hip height of 0
            local floorHit = cast(char, pos + WORLD_UP * 1.5, -WORLD_UP * (standHeight + 12))
            if floorHit then
                pos = floorHit.Position + WORLD_UP * standHeight
            end
        end

        root.CFrame = CFrame.lookAt(pos, pos + look)
        if snapToGround then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end
    restoreCollide()
end

local function setEnabled(on)
    enabled = on
    wasDown = {}
    local char, root, hum = parts()
    if not on then
        releaseUntil = time() + 0.5
        detach(root, hum, char, true)
    else
        missSince = nil
        noAttachUntil = 0
    end
    lw.log(on and "Wall walk ON" or "Wall walk OFF", on and "success" or "info")
end

----------------------------------------------------------------------
-- Surface detection
----------------------------------------------------------------------

-- Average the surface normal over a few rays around the character, so bumps,
-- stairs and rough geometry don't make the orientation shake.
local SAMPLE_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function sampleNormal(char, pos, hit, surfaceUp, f, r, reach)
    local sum = hit.Normal
    local count = 1
    for _, o in SAMPLE_OFFSETS do
        local origin = pos + (f * o[1] + r * o[2]) * 1.1
        local h = cast(char, origin, -surfaceUp * reach)
        if h and math.abs(h.Distance - hit.Distance) < 1.5 and h.Normal:Dot(hit.Normal) > 0.5 then
            sum = sum + h.Normal
            count = count + 1
        end
    end
    local n = sum / count
    if n.Magnitude < 0.01 then
        return hit.Normal
    end
    return n.Unit
end

-- Find the surface to wrap onto when the current one runs out (the top of a wall,
-- the side of a ledge). Rays start beyond the edge, at a few depths so thin and
-- thick walls both work, and look back along our direction of travel. The surface
-- we want faces the way we are going.
local WRAP_RISES = { 0.8, 2.0 }
local WRAP_INSETS = { 0.3, 1.0, 2.0 }

local function findWrap(char, pos, dir, surfaceUp, lead)
    local hover = cfg.hover
    for _, rise in WRAP_RISES do
        for _, inset in WRAP_INSETS do
            local origin = pos + dir * (hover + rise + lead) - surfaceUp * (hover + inset)
            local h = cast(char, origin, -dir * (hover + rise + lead + 3.5))
            if h and h.Normal:Dot(dir) > 0.5 then
                return h
            end
        end
    end
    -- sloped edges: a diagonal ray, no direction check
    local origin = pos + dir * (hover + 1.6 + lead) - surfaceUp * (hover + 1.8)
    return cast(char, origin, (-dir - surfaceUp * 0.3).Unit * (hover + 3.2 + lead))
end

-- Surface-aligned forward and right vectors, stable on ceilings and overhangs
local function getSurfaceBasis(cam, surfaceUp)
    local look = cam.LookVector
    local f = project(look, surfaceUp)

    -- On a wall, looking at it and pressing W climbs straight up it, whatever the
    -- camera pitch. Looking along the wall still runs you sideways along it.
    if math.abs(surfaceUp.Y) < 0.7 then
        local wallUp = project(WORLD_UP, surfaceUp)
        if wallUp.Magnitude > 0.05 then
            wallUp = wallUp.Unit
            local into = -look:Dot(surfaceUp) -- 1 when looking straight at the wall
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
        if f.Magnitude < 0.08 then
            f = cam.RightVector:Cross(surfaceUp)
        end
    end
    f = f.Unit
    local r = f:Cross(surfaceUp).Unit
    return f, r
end

----------------------------------------------------------------------
-- Orientation
----------------------------------------------------------------------

-- Which way the character should face. With shift lock it faces the camera
-- (flattened onto the surface), otherwise the way it is walking.
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

-- Small lean into the movement, smoothed with plain numbers
local function updateLean(baseRot, vel, isJumping, vertVel, dt)
    local localVel = baseRot:VectorToObjectSpace(vel)
    local scale = math.clamp(cfg.speed, 16, 80)
    local targetRoll = math.clamp(-localVel.X / scale, -1, 1) * math.rad(10)
    local targetPitch = math.clamp(localVel.Z / scale, -1, 1) * math.rad(6)
    if isJumping then
        targetPitch = targetPitch - math.clamp(vertVel / 60, -0.5, 1) * math.rad(12)
    end
    local k = 1 - math.exp(-14 * dt / cfg.smooth)
    leanRoll = leanRoll + (targetRoll - leanRoll) * k
    leanPitch = leanPitch + (targetPitch - leanPitch) * k
    return CFrame.Angles(leanPitch, 0, leanRoll)
end

-- Turn toward `goal` with angular velocity instead of writing the CFrame. The
-- physics then does the turning, exactly like normal walking, so it stays smooth.
local function steerRotation(root, goal, shiftLocked, dt)
    local rate = math.min((shiftLocked and 32 or 14) / cfg.smooth, 0.8 / dt)
    local current = root.CFrame.Rotation
    local delta = goal * current:Inverse()
    local axis, angle = delta:ToAxisAngle()
    if angle > math.pi then angle = angle - 2 * math.pi end
    local w = axis * (angle * rate)
    if w.Magnitude > MAX_TURN_RATE then
        w = w.Unit * MAX_TURN_RATE
    end
    root.AssemblyAngularVelocity = w
end

----------------------------------------------------------------------
-- Status text
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

local function updateHud()
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
    local sp = (curVel + extraVel).Magnitude
    local text = string.format("WALL WALK   %s   %d studs/s", surfaceLabel(), math.floor(sp + 0.5))
    if lastSprinting then text = text .. "   SPRINT" end
    hud.Text = text
    hud.Visible = true
end

----------------------------------------------------------------------
-- Main step
----------------------------------------------------------------------

me.CharacterRemoving:Connect(function()
    anchorUntil = 0
    isNoColliding = false
    appliedShiftOffset = false
    table.clear(collideSaved)
    attached = false
    curVel = Vector3.zero
    extraVel = Vector3.zero
    leanPitch = 0
    leanRoll = 0
    up = WORLD_UP
    smoothUp = WORLD_UP
    missSince = nil
    noAttachUntil = 0
    jumping = false
    jumpVel = 0
    loadedFor = nil
end)

local function step(dt)
    if not enabled then
        -- for half a second after turning off, keep the humanoid free in case
        -- the game or shift lock flips PlatformStand / AutoRotate back
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
    local char, root, hum = parts()
    local camObj = workspace.CurrentCamera
    if not char or not camObj then return end
    if hum.Health <= 0 then
        if attached or jumping then detach(root, hum, char, false) end
        return
    end

    local now = time()
    local hover = cfg.hover
    local cam = camObj.CFrame

    -- Physics moves the root a bit between our ticks, and gravity pulls it down
    -- while it does. Adding half a tick of gravity to the velocity we set cancels
    -- that drift, which keeps walls and ceilings steady.
    local g = getGravity()
    local gComp = Vector3.new(0, 0.5 * g * dt, 0)

    -- Input. Nothing moves while the game window is not focused.
    local focused = windowFocused()
    local fwd, side = 0, 0
    local sprinting = false
    if focused then
        fwd = (keyDown("W") and 1 or 0) - (keyDown("S") and 1 or 0)
        side = (keyDown("D") and 1 or 0) - (keyDown("A") and 1 or 0)
        sprinting = keyDown(cfg.sprintKey)
    end
    lastSprinting = sprinting
    local spaceJust = edge("space", focused and spaceIsDown())
    local dashJust = edge("dash", focused and keyDown(cfg.dashKey))
    local dropJust = edge("drop", focused and keyDown(cfg.dropKey))
    local moveSpeed = cfg.speed * (sprinting and cfg.sprintMult or 1)

    -- Camera-relative movement flattened onto the surface
    local f, r = getSurfaceBasis(cam, up)
    local move = f * fwd + r * side
    local moving = move.Magnitude > 0.01
    local dir = moving and move.Unit or Vector3.zero

    -- Let go: drop off the surface and fall, keeping the momentum
    if dropJust and (attached or jumping) then
        local v = curVel + extraVel + up * (jumping and jumpVel or 6)
        detach(root, hum, char, false)
        root.AssemblyLinearVelocity = v
        noAttachUntil = now + 0.5
        return
    end
    if not attached and now < noAttachUntil then
        restoreCollide()
        return
    end

    -- Jump from any surface
    if spaceJust and attached and not jumping then
        jumping = true
        jumpVel = cfg.jumpPower
        if cfg.leap then
            -- leap the way the camera points, but never into the surface
            local v = cam.LookVector * cfg.jumpPower
            curVel = project(v, up)
            jumpVel = math.max(v:Dot(up), cfg.jumpPower * 0.3)
        end
        jumpGraceUntil = now + 0.16
        restoreCollide()
        setAnim("jump", 0.08)
    end

    -- Dash along the surface (or through the air mid-jump)
    if dashJust and (attached or jumping) and now >= dashReadyAt then
        local d = moving and dir or project(lastLook, up)
        if d.Magnitude > 0.01 then
            extraVel = d.Unit * cfg.dashPower
            dashReadyAt = now + 0.6
        end
    end

    local pos = root.Position
    local reach = hover + 2.5
    local hit = nil

    if now >= jumpGraceUntil then
        hit = cast(char, pos, -up * reach)
        if jumping and hit then
            if jumpVel <= 0 and hit.Distance <= hover + 0.9 then
                jumping = false
                jumpVel = 0
            else
                hit = nil
            end
        end
    end

    -- at high speeds we cover several studs per tick, so look further ahead or we
    -- would skip straight past walls and edges
    local lead = (curVel + extraVel).Magnitude * dt * 1.5

    if moving then
        -- 1. Wall, ceiling or slope ahead (anything turned more than ~30 degrees
        --    from the current surface). Only switch when we're nearly touching it,
        --    so we climb smoothly instead of being pulled onto it from a distance.
        local front = cast(char, pos, dir * (hover + 2.0 + lead))
        if front and front.Distance <= hover + 0.75 + lead
            and front.Normal:Dot(up) < 0.85 and surfaceAllowed(front.Normal) then
            up = front.Normal
            jumping = false
            jumpVel = 0
            hit = cast(char, pos, -up * reach) or front
        else
            -- 2. Ceiling or slanted roof just above while climbing
            local diagDir = (dir + up * 0.65).Unit
            local diagHit = cast(char, pos, diagDir * (hover + 2.2 + lead))
            if diagHit and diagHit.Distance <= hover + 1.0 + lead
                and diagHit.Normal:Dot(up) < 0.85 and surfaceAllowed(diagHit.Normal) then
                up = diagHit.Normal
                jumping = false
                jumpVel = 0
                hit = cast(char, pos, -up * reach) or diagHit
            elseif not jumping and attached and cfg.wrap then
                -- 3. Edge wrap. Start as soon as the ground ahead runs out,
                --    not only after the centre of the body has passed the edge.
                local needWrap = hit == nil
                if hit then
                    needWrap = cast(char, pos + dir * (1.6 + lead), -up * reach) == nil
                end
                if needWrap then
                    local wrap = findWrap(char, pos, dir, up, lead)
                    if wrap and surfaceAllowed(wrap.Normal) then
                        up = wrap.Normal
                        hit = wrap
                        anchorHit = wrap
                        anchorUntil = now + 0.4
                    end
                end
            end
        end
    end

    -- Right after climbing over an edge the body is still outside the lip, so the
    -- ray straight down finds nothing (or the ground far below). Keep using the
    -- surface we just found for a moment and pull the body onto it.
    local usingAnchor = false
    if anchorHit and now < anchorUntil and attached and not jumping then
        if hit == anchorHit then
            usingAnchor = true
        elseif not hit then
            hit = anchorHit
            usingAnchor = true
        elseif (anchorHit.Position - hit.Position):Dot(anchorHit.Normal) > 1.0 then
            hit = anchorHit -- the ray found ground far below the ledge, ignore it
            usingAnchor = true
        elseif hit.Normal:Dot(anchorHit.Normal) > 0.8 then
            anchorUntil = 0 -- we are on the new surface for real now
        end
    end

    local shiftLocked = isShiftLocked()
    local wantOffset = shiftLocked and cfg.extraOffset

    -- Case 1: mid-jump, relative to the surface we left
    if jumping then
        if now - lastAssert > 0.2 then
            lastAssert = now
            pcall(function()
                hum.PlatformStand = true
                hum.AutoRotate = false
            end)
        end
        syncShiftLockOffset(hum, wantOffset)

        if now >= jumpGraceUntil then
            local farCheck = cast(char, pos, -up * (hover + 16))
            if not farCheck then
                detach(root, hum, char, false)
                return
            end
        end

        -- in the air momentum is kept; steering pulls toward the input direction
        local kAir = (1 - math.exp(-15 * dt / cfg.smooth)) * cfg.airControl
        curVel = project(curVel, up)
        if moving then
            curVel = curVel:Lerp(dir * moveSpeed, kAir)
        end
        extraVel = project(extraVel, up) * math.exp(-5 * dt)
        if extraVel.Magnitude < 0.5 then extraVel = Vector3.zero end
        jumpVel = jumpVel - g * dt
        smoothUp = up

        local baseGoal = computeFacing(cam, shiftLocked, moving, dir, f, up)
        local lean = updateLean(baseGoal, curVel, true, jumpVel, dt)
        steerRotation(root, baseGoal * lean, shiftLocked, dt)

        root.AssemblyLinearVelocity = curVel + extraVel + up * jumpVel + gComp
        setAnim("jump", 0.08)
        return
    end

    -- Case 2: no surface found, hand control back to Roblox to fall
    if not hit then
        if not attached then
            restoreCollide()
            return
        end
        missSince = missSince or now
        if now - missSince < 0.16 then
            root.AssemblyLinearVelocity = curVel + extraVel + gComp
            root.AssemblyAngularVelocity = Vector3.zero
            return
        end
        detach(root, hum, char, false)
        return
    end

    -- Case 3: attached to a surface (floor, wall, slanted roof or ceiling)
    missSince = nil
    noCollide(char)

    -- PlatformStand is set the moment we attach, and re-asserted every 0.2 s
    -- because the game or shift lock can flip it back
    if not attached or now - lastAssert > 0.2 then
        lastAssert = now
        pcall(function()
            hum.PlatformStand = true
            hum.AutoRotate = false
        end)
        -- the game can turn collision back on for some parts; sweep again
        isNoColliding = false
        noCollide(char)
    end
    syncShiftLockOffset(hum, wantOffset)

    -- averaged normal over a few rays, then rebuild the movement basis on it
    if usingAnchor then
        up = hit.Normal
    else
        local bf, br = getSurfaceBasis(cam, hit.Normal)
        up = sampleNormal(char, pos, hit, hit.Normal, bf, br, reach)
    end
    f, r = getSurfaceBasis(cam, up)
    move = f * fwd + r * side
    moving = move.Magnitude > 0.01
    dir = moving and move.Unit or Vector3.zero

    -- glide the surface normal so edges become curves instead of snaps
    local normRate = shiftLocked and 24 or 16
    local kNorm = 1 - math.exp(-normRate * dt / cfg.smooth)
    if not attached then smoothUp = up end
    attached = true
    smoothUp = smoothUp:Lerp(up, kNorm)
    if smoothUp.Magnitude < 0.01 then smoothUp = up end
    smoothUp = smoothUp.Unit

    -- speed up and slow down smoothly
    local kVel = 1 - math.exp(-(moving and 24 or 18) * dt / cfg.smooth)
    local targetVel = moving and (dir * moveSpeed) or Vector3.zero
    curVel = project(curVel, up):Lerp(targetVel, kVel)
    if not moving and curVel.Magnitude < 0.2 then
        curVel = Vector3.zero
    end

    -- the dash burst fades out on its own and always stays on the surface
    extraVel = project(extraVel, up) * math.exp(-5 * dt)
    if extraVel.Magnitude < 0.5 then extraVel = Vector3.zero end

    -- Orientation: steer with angular velocity, no CFrame writes.
    local baseGoal = computeFacing(cam, shiftLocked, moving, dir, f, smoothUp)
    local lean = updateLean(baseGoal, curVel + extraVel, false, 0, dt)
    steerRotation(root, baseGoal * lean, shiftLocked, dt)

    -- Height: a spring along the surface normal, again through velocity, so the
    -- character is never teleported.
    local currentDist = (pos - hit.Position):Dot(up)
    local heightError = hover - currentDist
    local gain = math.min(22, 0.8 / dt)
    local correction = math.clamp(heightError * gain, -45, 45)

    -- while mantling an edge, also glide sideways over the new surface
    local lateralPull = Vector3.zero
    if usingAnchor then
        local toAnchor = project(hit.Position - pos, up)
        local dist = toAnchor.Magnitude
        if dist > 0.3 then
            lateralPull = toAnchor.Unit * math.min(dist * 10, 28)
        end
    end

    root.AssemblyLinearVelocity = curVel + extraVel + lateralPull + up * correction + gComp

    -- animation follows the real speed, with a dead zone so it doesn't flicker
    local currentSpeed = (curVel + extraVel).Magnitude
    local walking = moving or currentSpeed > (currentAnim == "walk" and 0.6 or 1.5)
    setAnim(walking and "walk" or "idle", 0.16)
    if tracks.walk and walking then
        local animSpeed = math.clamp(currentSpeed / 16, 0.35, 6)
        if math.abs(animSpeed - lastWalkSpeed) > 0.05 then
            lastWalkSpeed = animSpeed
            tracks.walk:AdjustSpeed(animSpeed)
        end
    end
end

-- A bug in the code above must never freeze the character on a wall. Errors are
-- reported, and if the script keeps failing it switches itself off cleanly.
local errorStreak = 0

RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(step, dt)
    if ok then
        errorStreak = 0
    else
        errorStreak = errorStreak + 1
        if errorStreak == 1 then
            warn("wallwalk error:", err)
        end
        if errorStreak >= 30 then
            errorStreak = 0
            pcall(setEnabled, false)
            lw.log("Wall walk turned itself off after repeated errors, see the console", "error")
        end
    end
    pcall(updateHud)
end)

----------------------------------------------------------------------
-- Settings loop. Runs every tick: widgets must be declared every time.
----------------------------------------------------------------------

while true do
    readSettings()

    if enabled then
        local char, _, hum = parts()
        if char and hum and hum ~= loadedFor then
            local ok, err = pcall(loadAnims, char, hum)
            if not ok then
                warn("wallwalk: could not load animations:", err)
            end
        end
    end

    if cfg.toggleKey and lw.keyPressed(cfg.toggleKey) then
        setEnabled(not enabled)
    end

    task.wait()
end
