--[[
    RUNAWAYS AutoFarm — Modo Teleporte Direto
    Teleporta até o portão final, ativa, espera 2 min com kill aura,
    atravessa e repete. Sem UI. Sem dirigir.

    ⚙️  EDITE SCRIPT_URL com o link raw deste script.
    ⚙️  Requer: queue_on_teleport, fireproximityprompt, HttpGet, debug.getupvalues
]]

local SCRIPT_URL = "https://raw.githubusercontent.com/Foxy-Ghost/Runaway.main/refs/heads/main/RUNAWAYS_tp.lua"

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end
while not Players.LocalPlayer do task.wait() end

local player = Players.LocalPlayer
local env = getgenv and getgenv() or _G

if env.RunawaysTPRunning and not env.RunawaysTPReloading then return end
env.RunawaysTPRunning = true

-- ═══════════════════ CONFIG ═══════════════════
local LOBBY_PLACE = 118418618261207
local GAME_PLACE  = 117311404196294
local LOBBY_DELAY = 3      -- segundos entre runs no lobby
local GATE_TIMEOUT = 165   -- timeout total esperando o portão
local RETRY_DELAY = 10
local AUTO_REPLAY = true
local KILL_RADIUS = 500    -- raio da kill aura

local STATE_KEY      = "RUNAWAYS_TP_STATE"
local ENABLED_KEY    = "RUNAWAYS_TP_ENABLED"
local TRANSITION_KEY = "RUNAWAYS_TP_TRANSITION"
local STATE_PATH     = "MyScriptHub/RUNAWAYS/tp_state.json"
local VERSION = 1

local function log(msg) print("[RUNAWAYS-TP] " .. tostring(msg)) end

-- ═══════════════════ MÓDULOS DO JOGO ═══════════════════
local dataModule = ReplicatedStorage:WaitForChild("Data")
local flow = require(ReplicatedStorage:WaitForChild("FlowClient"))
local data = require(dataModule)

-- ═══════════════════ HELPERS ═══════════════════
local function getHumanoid()
    local c = player.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- ═══════════════════ GOD MODE ═══════════════════
local originalTakeDamage = flow.PlayerDamage and flow.PlayerDamage.TakeDamage
local originalAbandon = flow.Passout and flow.Passout.Abandon
local blockedRemote = function() end
local godStates = setmetatable({}, { __mode = "k" })

local function applyGodMode(h)
    if not h then return end
    if not godStates[h] then
        godStates[h] = {
            BreakJointsOnDeath = h.BreakJointsOnDeath,
            RequiresNeck = h.RequiresNeck,
            DeadEnabled = h:GetStateEnabled(Enum.HumanoidStateType.Dead),
        }
    end
    if flow.PlayerDamage and type(originalTakeDamage) == "function" then
        flow.PlayerDamage.TakeDamage = blockedRemote
    end
    if flow.Passout and type(originalAbandon) == "function" then
        flow.Passout.Abandon = blockedRemote
    end
    h.BreakJointsOnDeath = false
    h.RequiresNeck = false
    h:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
    h.Health = h.MaxHealth
    if h:GetAttribute("Downed") == true then
        h:SetAttribute("Downed", false)
        h:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

-- ═══════════════════ KILL AURA ═══════════════════
local function killAllNPCs(radius)
    local folder = workspace:FindFirstChild("NPCs")
    if not folder or not flow.NPCs or type(flow.NPCs.Damage) ~= "function" then return 0 end
    local root = getRoot()
    local killed = 0
    for _, humanoid in folder:QueryDescendants("Humanoid") do
        local npc = humanoid:FindFirstAncestorWhichIsA("Model")
        local npcRoot = npc and npc:FindFirstChild("HumanoidRootPart")
        local inRange = not radius or (root and npcRoot and (npcRoot.Position - root.Position).Magnitude <= radius)
        if humanoid.Health > 0 and inRange then
            local ok = pcall(flow.NPCs.Damage, humanoid, humanoid.Health + 1)
            if ok then killed += 1 end
        end
    end
    return killed
end

-- ═══════════════════ TELEPORT (PivotTo) ═══════════════════
local LastPosition = nil

local function teleportTo(destination, saveLast)
    if typeof(destination) ~= "CFrame" then return false end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or not root or humanoid.Health <= 0 then return false end

    local oldLast = LastPosition
    if saveLast ~= false then LastPosition = root.CFrame end

    local camera = workspace.CurrentCamera
    local camCF = camera and camera.CFrame
    local camSubj = camera and camera.CameraSubject
    local camType = camera and camera.CameraType

    if camera then
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = camCF
    end

    local ok = pcall(function()
        if humanoid.SeatPart then
            humanoid.Sit = false
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            RunService.Heartbeat:Wait()
        end
        character:PivotTo(destination)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        RunService.Heartbeat:Wait()
    end)

    if camera and camera.Parent then
        camera.CameraSubject = camSubj
        camera.CameraType = camType
        camera.CFrame = camCF
    end

    if not ok then
        LastPosition = oldLast
        return false
    end
    return true
end

local function streamAround(pos)
    pcall(function() player:RequestStreamAroundAsync(pos, 5) end)
end

-- ═══════════════════ END GATE (localizar) ═══════════════════
local function getEndZ()
    local flowModule = ReplicatedStorage:FindFirstChild("FlowClient")
    local gui = flowModule and flowModule:FindFirstChild("Gui")
    local distModule = gui and gui:FindFirstChild("DistanceToBorderClient")
    if distModule then
        local ok, module = pcall(require, distModule)
        if ok and type(module) == "table" then
            local cb = module.SetEndPos_event or module.SetEndPos
            if type(cb) == "function" and debug and type(debug.getupvalues) == "function" then
                local read, upvalues = pcall(debug.getupvalues, cb)
                if read and type(upvalues) == "table" then
                    if type(upvalues[1]) == "number" then return upvalues[1] end
                    for _, v in upvalues do
                        if type(v) == "number" and math.abs(v) > 1000 then return v end
                    end
                end
            end
        end
    end
    local pg = player:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, label in pg:GetDescendants() do
            if label:IsA("TextLabel") and label.Text:find("Mexico", 1, true) then
                local cur = label.Parent
                while cur and cur ~= pg do
                    local v = tonumber(cur.Name:match("^Border_(-?[%d%.]+)$"))
                    if v then return v end
                    cur = cur.Parent
                end
            end
        end
    end
end

local function getStartCFrame()
    local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
    if not spawn or not spawn.Enabled then return end
    local excludes = { spawn }
    if player.Character then excludes[#excludes + 1] = player.Character end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excludes
    params.RespectCanCollide = true
    local result = workspace:Raycast(spawn.Position + Vector3.yAxis * 6, -Vector3.yAxis * 20, params)
    local y = result and result.Position.Y + 3.5 or spawn.Position.Y + 3
    return CFrame.new(spawn.Position.X, y, spawn.Position.Z) * spawn.CFrame.Rotation
end

local function getEndPrompt()
    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")
    local customs = buildings and buildings:FindFirstChild("CustomsFinal")
    if not customs then return end
    local cb = customs:FindFirstChild("CustomsBuilding")
    local fd = cb and cb:FindFirstChild("FinalDoor")
    local cmd = fd and fd:FindFirstChild("Command")
    local btn = cmd and cmd:FindFirstChild("CommandButton")
    local holder = btn and btn:FindFirstChild("Prompt")
    local prompt = holder and (holder:IsA("ProximityPrompt") and holder or holder:FindFirstChildOfClass("ProximityPrompt"))
    if prompt then return prompt end
    local ok, candidates = pcall(customs.QueryDescendants, customs, "ProximityPrompt")
    if ok then
        for _, c in candidates do
            if c.ActionText == "Activate" and c:FindFirstAncestor("FinalDoor") then return c end
        end
    end
end

local function getEndPromptDestination(prompt, direction)
    local holder = prompt and prompt.Parent
    local holderCF
    if holder and holder:IsA("Attachment") then holderCF = holder.WorldCFrame
    elseif holder and holder:IsA("BasePart") then holderCF = holder.CFrame end
    if not holderCF then return end
    local outward = holderCF.LookVector
    if outward.Z * direction > 0 then outward = -outward end
    if math.abs(outward.Z) < 0.25 then outward = Vector3.new(0, 0, -direction) end
    local pos = holderCF.Position + outward * 4
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = player.Character and { player.Character } or {}
    local result = workspace:Raycast(pos + Vector3.yAxis * 20, Vector3.new(0, -60, 0), params)
    if result then pos = Vector3.new(pos.X, result.Position.Y + 3.25, pos.Z) end
    return CFrame.lookAt(pos, Vector3.new(holderCF.Position.X, pos.Y, holderCF.Position.Z), Vector3.yAxis)
end

-- ═══════════════════ FINAL DOOR (atravessar) ═══════════════════
local function getFinalDoor(prompt)
    local fd = prompt and prompt:FindFirstAncestor("FinalDoor")
    if fd then return fd end
    local map = workspace:FindFirstChild("Map")
    local b = map and map:FindFirstChild("Buildings")
    local c = b and b:FindFirstChild("CustomsFinal")
    return c and c:FindFirstChild("FinalDoor", true)
end

local function getGateTimer(prompt)
    local fd = getFinalDoor(prompt)
    if not fd then return end
    local ok, labels = pcall(fd.QueryDescendants, fd, "TextLabel")
    if not ok then
        labels = {}
        for _, i in fd:GetDescendants() do
            if i:IsA("TextLabel") then labels[#labels + 1] = i end
        end
    end
    for _, label in labels do
        local text = label.Text
        local m, s = text:match("(%d+)%s*m%s*(%d+)%s*s")
        if not m then m, s = text:match("(%d+)%s*:%s*(%d+)") end
        if m and s then return tonumber(m) * 60 + tonumber(s), text end
    end
end

local function getGatePassage(prompt, direction, endZ)
    local fd = getFinalDoor(prompt)
    local cmd = fd and fd:FindFirstChild("Command", true)
    local lh = fd and fd:FindFirstChild("DoorL")
    local rh = fd and fd:FindFirstChild("DoorR")
    local ld = lh and lh:FindFirstChild("Door", true)
    local rd = rh and rh:FindFirstChild("Door", true)
    local position
    if ld and ld:IsA("BasePart") and rd and rd:IsA("BasePart") then
        position = (ld.Position + rd.Position) * 0.5
    end
    if not position and fd then
        local ok, parts = pcall(fd.QueryDescendants, fd, "BasePart")
        if ok then
            for _, part in parts do
                if part.CanCollide and part.Transparency < 0.95 and part.Size.Y >= 4
                    and (not cmd or not part:IsDescendantOf(cmd))
                then
                    position = position or part.Position
                end
            end
        end
    end
    if not position then
        local holder = prompt and prompt.Parent
        if holder and holder:IsA("Attachment") then position = holder.WorldPosition
        elseif holder and holder:IsA("BasePart") then position = holder.Position end
    end
    if not position then return end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excl = {}
    if player.Character then excl[#excl + 1] = player.Character end
    if fd then excl[#excl + 1] = fd end
    params.FilterDescendantsInstances = excl
    params.RespectCanCollide = true
    local hit = workspace:Raycast(position + Vector3.yAxis * 30, -Vector3.yAxis * 80, params)
    if hit then position = Vector3.new(position.X, hit.Position.Y + 3.5, position.Z) end
    return { Position = position, Direction = direction, FinalDoor = fd, DoorL = ld, DoorR = rd }
end

local function isGatePassageOpen(passage)
    if not passage or typeof(passage.Position) ~= "Vector3" then return false end
    local fd = passage.FinalDoor
    if not fd or not fd.Parent then
        fd = getFinalDoor()
        passage.FinalDoor = fd
    end
    if fd then
        local lh = fd:FindFirstChild("DoorL")
        local rh = fd:FindFirstChild("DoorR")
        local cl = lh and lh:FindFirstChild("Door", true)
        local cr = rh and rh:FindFirstChild("Door", true)
        if cl and cl:IsA("BasePart") then passage.DoorL = cl end
        if cr and cr:IsA("BasePart") then passage.DoorR = cr end
    end
    local ld, rd = passage.DoorL, passage.DoorR
    if ld and ld.Parent and ld:IsA("BasePart") and rd and rd.Parent and rd:IsA("BasePart") then
        local diff = ld.Position - rd.Position
        if diff.Magnitude > 0.1 then
            local axis = diff.Unit
            local lh = math.abs(ld.CFrame.RightVector:Dot(axis)) * ld.Size.X * 0.5
                + math.abs(ld.CFrame.UpVector:Dot(axis)) * ld.Size.Y * 0.5
                + math.abs(ld.CFrame.LookVector:Dot(axis)) * ld.Size.Z * 0.5
            local rh2 = math.abs(rd.CFrame.RightVector:Dot(axis)) * rd.Size.X * 0.5
                + math.abs(rd.CFrame.UpVector:Dot(axis)) * rd.Size.Y * 0.5
                + math.abs(rd.CFrame.LookVector:Dot(axis)) * rd.Size.Z * 0.5
            local mid = (ld.Position + rd.Position) * 0.5
            passage.Position = Vector3.new(mid.X, passage.Position.Y, mid.Z)
            return diff.Magnitude - lh - rh2 >= 12
        end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = player.Character and { player.Character } or {}
    params.RespectCanCollide = true
    local dir = Vector3.new(0, 0, passage.Direction)
    return workspace:Raycast(passage.Position - dir * 10, dir * 20, params) == nil
end

local function isGateWindowOpen()
    if flow.CrimesGui and type(flow.CrimesGui.StartEndTimer_event) == "function"
        and debug and type(debug.getupvalues) == "function"
    then
        local ok, vals = pcall(debug.getupvalues, flow.CrimesGui.StartEndTimer_event)
        if ok and type(vals) == "table" then
            local o, c = tonumber(vals[2]), tonumber(vals[3])
            local now = workspace:GetServerTimeNow()
            if o and c and now >= o and now < c then return true end
        end
    end
    local pg = player:FindFirstChildOfClass("PlayerGui")
    local hud = pg and pg:FindFirstChild("HudGui")
    local ev = hud and hud:FindFirstChild("Events")
    local cl = ev and ev:FindFirstChild("Closing")
    if not cl or not cl.Visible then return false end
    local timer = cl:FindFirstChild("Timer")
    local text = timer and timer.Text or ""
    local m, s = text:match("(%d+)%s*:%s*(%d+)")
    return not m or tonumber(m) * 60 + tonumber(s) > 0
end

-- ═══════════════════ SAFE ZONE (ficar parado enquanto espera) ═══════════════════
local safeState = { CFrame = nil, Character = nil, Anchored = nil }

local function getSafeCFrame(passage)
    if not passage or typeof(passage.Position) ~= "Vector3" then return end
    local fd = passage.FinalDoor
    local cb = fd and fd:FindFirstAncestor("CustomsBuilding")
    local prompt = getEndPrompt()
    local holder = prompt and prompt.Parent
    local promptPos = (holder and holder:IsA("Attachment") and holder.WorldPosition)
        or (holder and holder:IsA("BasePart") and holder.Position)
        or passage.Position
    local bestFloor, bestDist = nil, math.huge
    if cb then
        for _, office in cb:GetChildren() do
            if office.Name == "CustomsOffice" then
                local floor = office:FindFirstChild("Floor", true)
                if floor and floor:IsA("BasePart") then
                    local d = (floor.Position - promptPos).Magnitude
                    if d < bestDist then bestFloor, bestDist = floor, d end
                end
            end
        end
    end
    if bestFloor then
        local pos = bestFloor.CFrame:PointToWorldSpace(Vector3.new(5, bestFloor.Size.Y * 0.5 + 3.25, 8))
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.FilterDescendantsInstances = player.Character and { player.Character } or {}
        rp.RespectCanCollide = true
        local fh = workspace:Raycast(pos, -Vector3.yAxis * 6, rp)
        local rh = workspace:Raycast(pos, Vector3.yAxis * 30, rp)
        if fh and rh then
            return CFrame.lookAt(pos, Vector3.new(promptPos.X, pos.Y, promptPos.Z), Vector3.yAxis)
        end
    end
end

local function releaseSafeZone()
    local c = safeState.Character
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if r and safeState.Anchored ~= nil then
        r.Anchored = safeState.Anchored
        r.AssemblyLinearVelocity = Vector3.zero
        r.AssemblyAngularVelocity = Vector3.zero
    end
    safeState.CFrame, safeState.Character, safeState.Anchored = nil, nil, nil
end

local function enterSafeZone(passage)
    local dest = getSafeCFrame(passage)
    local c = player.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if not dest or not h or not r or h.Health <= 0 then return false end
    releaseSafeZone()
    safeState.Character = c
    safeState.Anchored = r.Anchored
    safeState.CFrame = dest
    teleportTo(dest, false)
    r = c:FindFirstChild("HumanoidRootPart")
    if not r then releaseSafeZone(); return false end
    r.CFrame = dest
    r.AssemblyLinearVelocity = Vector3.zero
    r.AssemblyAngularVelocity = Vector3.zero
    r.Anchored = true
    if flow.PoliceHeli and type(flow.PoliceHeli.Despawn) == "function" then
        pcall(flow.PoliceHeli.Despawn)
    end
    return true
end

-- ═══════════════════ END SCREEN ═══════════════════
local lastEndScan = 0

local function isVisible(inst)
    local pg = player:FindFirstChildOfClass("PlayerGui")
    local cur = inst
    while cur and cur ~= pg do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("LayerCollector") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return cur == pg
end

local function getEndScreen()
    local pg = player:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local ef = pg:FindFirstChild("EndFrame", true)
    if ef then
        if not isVisible(ef) then return end
        local esc = ef:FindFirstChild("Escaped", true)
        local cap = ef:FindFirstChild("Captured", true)
        if esc and isVisible(esc) then return ef, "Escaped" end
        if cap and isVisible(cap) then return ef, "Captured" end
        for _, inst in ef:GetDescendants() do
            if inst:IsA("GuiObject") and isVisible(inst) then
                local text = (inst:IsA("TextLabel") or inst:IsA("TextButton")) and inst.Text:lower() or ""
                if text:find("escaped", 1, true) then return ef, "Escaped" end
                if text:find("captured", 1, true) then return ef, "Captured" end
            end
        end
        return ef, "Ended"
    end
    if os.clock() - lastEndScan < 1 then return end
    lastEndScan = os.clock()
  for _, inst in pg:GetDescendants() do
        if inst:IsA("GuiObject") and isVisible(inst) then
            local text = (inst:IsA("TextLabel") or inst:IsA("TextButton")) and inst.Text:lower() or ""
            if text:find("escaped", 1, true) then return nil, "Escaped" end
            if text:find("captured", 1, true) then return nil, "Captured" end
        end
    end
end

local function getReplayButton(ef)
    if not ef then return end
    local function matches(btn)
        if not btn:IsA("GuiButton") or not isVisible(btn) then return false end
        local n = btn.Name:lower()
        local t = btn:IsA("TextButton") and tostring(btn.Text or ""):lower() or ""
        if t == "" then
            local l = btn:FindFirstChildWhichIsA("TextLabel", true)
            t = l and tostring(l.Text or ""):lower() or ""
        end
        return n:find("replay", 1, true) ~= nil or t:find("replay", 1, true) ~= nil
    end
    local d = ef:FindFirstChild("Replay", true)
    if d then
        if matches(d) then return d end
        local n = d:FindFirstChildWhichIsA("GuiButton", true)
        if n and matches(n) then return n end
    end
    for _, b in ef:GetDescendants() do
        if matches(b) then return b end
    end
end

local function requestReplay(btn)
    if flow.GameManager and type(flow.GameManager.Replay) == "function" then
        local ok, r = pcall(flow.GameManager.Replay)
        if ok and r ~= false then return true end
    end
    if btn then
        if type(firesignal) == "function" then
            local ok = pcall(firesignal, btn.MouseButton1Click)
            if ok then return true end
        else
            local ok = pcall(btn.Activate, btn)
            if ok then return true end
        end
    end
    return false
end

-- ═══════════════════ QUEUE ON TELEPORT (auto-relançamento) ═══════════════════
local function getQueueFunction()
    if type(queue_on_teleport) == "function" then return queue_on_teleport end
    if type(queueonteleport) == "function" then return queueonteleport end
    if type(syn) == "table" and type(syn.queue_on_teleport) == "function" then return syn.queue_on_teleport end
    if type(fluxus) == "table" and type(fluxus.queue_on_teleport) == "function" then return fluxus.queue_on_teleport end
end

local TransitionToken = ""
local QueueJob = nil

local function queueTeleport(reason, expectedPlaceId)
    local qf = getQueueFunction()
    if not qf then return false, "queue_on_teleport unavailable" end
    local token = table.concat({
        tostring(player.UserId), game.JobId, tostring(expectedPlaceId),
        tostring(os.time()), tostring(math.random(100000, 999999)),
    }, ":")
    TransitionToken = token
    QueueJob = game.JobId
    pcall(TeleportService.SetTeleportSetting, TeleportService, ENABLED_KEY, true)
    pcall(TeleportService.SetTeleportSetting, TeleportService, TRANSITION_KEY, token)
    local payload = string.format(
        "if not game:IsLoaded() then game.Loaded:Wait() end\n"
        .. "if game.PlaceId == %d or game.PlaceId == %d then\n"
        .. "local t = game:GetService(%q)\n"
        .. "local v = nil\n"
        .. "pcall(function() v = t:GetTeleportSetting(%q) end)\n"
        .. "if t:GetTeleportSetting(%q) ~= false and tostring(v or '') == %q then\n"
        .. "local e = getgenv and getgenv() or _G\n"
        .. "e.RunawaysTPReloading = true\n"
        .. "loadstring(game:HttpGet(%q .. '?cb=' .. tostring(os.time())))()\n"
        .. "end\nend",
        LOBBY_PLACE, GAME_PLACE, "TeleportService",
        TRANSITION_KEY, ENABLED_KEY, token,
        SCRIPT_URL
    )
    local ok, err = pcall(qf, payload)
    if not ok then
        TransitionToken = ""
        QueueJob = nil
        return false, tostring(err)
    end
    log("Teleport armado: " .. reason)
    return true
end

-- ═══════════════════ FLUXO PRINCIPAL ═══════════════════
local running = true
local token = {}
local teleporting = false
local finished = false

local function getContext()
    if game.PlaceId == LOBBY_PLACE then return "Lobby" end
    if game.PlaceId == GAME_PLACE then return "Game" end
    if flow.LobbyServer and type(flow.LobbyServer.create) == "function" then return "Lobby" end
    if workspace:FindFirstChild("Map") and flow.NPCs then return "Game" end
    return "Unknown"
end

-- ============ FASE 1: LOBBY ============
local function getOwnedCar()
    if not flow.PlayerDataClient or type(flow.PlayerDataClient.getObserver) ~= "function" then return end
    local ok, obs = pcall(flow.PlayerDataClient.getObserver, "cars")
    if not ok or not obs or type(obs.get) ~= "function" then return end
    local r, cars = pcall(obs.get, obs)
    if not r or type(cars) ~= "table" then return end
    local names = {}
    for n in cars do names[#names + 1] = tostring(n) end
    table.sort(names)
    return names[1]
end

local function runLobby()
    if not flow.LobbyServer
        or type(flow.LobbyServer.play) ~= "function"
        or type(flow.LobbyServer.create) ~= "function"
        or type(flow.LobbyServer.exit) ~= "function"
    then
        return false, "Lobby API indisponível"
    end
    log("Lobby: aguardando " .. LOBBY_DELAY .. "s")
    local exp = os.clock() + LOBBY_DELAY
    repeat task.wait(0.1) until os.clock() >= exp or not running
    if not running then return true end

    local car = getOwnedCar()
    if not car then return false, "Nenhum carro disponível" end

    local pg = player:FindFirstChildOfClass("PlayerGui")
    local cgui = pg and (pg:FindFirstChild("CreateLobbyGui") or pg:WaitForChild("CreateLobbyGui", 10))
    if not cgui then return false, "CreateLobbyGui indisponível" end

    local queued, qerr = queueTeleport("game", GAME_PLACE)
    if not queued then return false, qerr end

    for attempt = 1, 2 do
        if not running then return true end
        local cf = cgui:FindFirstChild("Frame")
        local ef = cgui:FindFirstChild("Exit")
        if ef and ef.Visible then
            pcall(flow.LobbyServer.exit)
            local exp2 = os.clock() + 5
            repeat task.wait(0.1) until not ef.Visible or os.clock() >= exp2
        end
        if not cf or not cf.Visible then
            pcall(flow.LobbyServer.play)
            local exp3 = os.clock() + 10
            repeat
                if teleporting then return true end
                task.wait(0.2)
            until (cf and cf.Visible) or (ef and ef.Visible) or os.clock() >= exp3
        end
        cf = cgui:FindFirstChild("Frame")
        ef = cgui:FindFirstChild("Exit")
        if ef and ef.Visible then
            pcall(flow.LobbyServer.exit)
            task.wait(attempt * 1.5)
            continue
        end
        if not cf or not cf.Visible then
            task.wait(attempt)
            continue
        end
        log("Criando partida com carro: " .. car)
        cf.Visible = false
        pcall(flow.LobbyServer.create, {
            maxPlayers = 1,
            permissions = "Friends",
            car = car,
        })
        local exp4 = os.clock() + 20
        repeat task.wait(0.2) until teleporting or os.clock() >= exp4
        if teleporting then return true end
        task.wait(attempt * 2)
    end
    return false, "Criação de partida falhou"
end

-- ============ FASE 2: GAME (teleporta, ativa, espera, atravessa) ============
local function runGame()
    if getEndScreen() then
        -- já está no end screen, pula direto pro handler
    end

    log("Game: aguardando mapa carregar")
    local exp = os.clock() + 30
    repeat
        local h = getHumanoid()
        local r = getRoot()
        if h and r and h.Health > 0 and workspace:FindFirstChild("Map") then break end
        task.wait(0.25)
    until not running or os.clock() >= exp
    if not running then return true end

    -- ═══ STEP 1: Descobrir endZ e teleportar até o portão ═══
    local endZ
    exp = os.clock() + 20
    repeat
        endZ = getEndZ()
        if not endZ then task.wait(0.25) end
    until endZ or not running or os.clock() >= exp
    if not endZ then return false, "endZ indisponível" end

    local start = getStartCFrame()
    local direction = (not start or endZ >= start.Position.Z) and 1 or -1

    log("Teleportando para o portão (endZ=" .. tostring(endZ) .. ")")
    -- Tenta primeiro o prompt já carregado
    local prompt = getEndPrompt()
    if not prompt then
        -- Teleporta para perto do portão para forçar streaming
        local nearPos = Vector3.new(500, 2000, endZ - direction * 30)
        streamAround(nearPos)
        teleportTo(CFrame.new(nearPos), false)
        task.wait(0.5)
        exp = os.clock() + 15
        repeat
            prompt = getEndPrompt()
            if not prompt then task.wait(0.3) end
        until prompt or os.clock() >= exp
    end
    if not prompt then return false, "Prompt do portão não encontrado" end

    -- Teleporta exatamente ao lado do botão
    local dest = getEndPromptDestination(prompt, direction)
    if not dest then return false, "Destino do botão indisponível" end
    streamAround(dest.Position)
    teleportTo(dest, false)
    task.wait(0.4)

    -- ═══ STEP 2: Ativar o botão ═══
    log("Ativando botão do portão")
    local activated = false
    local before = getGateTimer(prompt)
    for attempt = 1, 3 do
        if not running then return true end
        if type(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, prompt)
        end
        local exp2 = os.clock() + 4
        repeat
            local secs = getGateTimer(prompt)
            if not prompt.Enabled or (secs and before and secs < before) or (secs and secs < 120) then
                activated = true
                break
            end
            task.wait(0.25)
        until os.clock() >= exp2
        if activated then break end
        task.wait(attempt)
    end
    if not activated then return false, "Ativação do botão não confirmada" end
    log("Portão ativado — 2 minutos de espera")

    -- ═══ STEP 3: Ir para safe zone e esperar 2 minutos ═══
    local passage = getGatePassage(prompt, direction, endZ)
    enterSafeZone(passage)

    local gateStart = os.time()
    exp = os.clock() + GATE_TIMEOUT
    while running and os.clock() < exp do
        -- Kill aura + god mode
        local h = getHumanoid()
        if h then applyGodMode(h) end
        killAllNPCs(KILL_RADIUS)

        -- Verifica end screen (alguém capturou, etc)
        local ef, outcome = getEndScreen()
        if ef or outcome then
            releaseSafeZone()
            return "end_screen", outcome
        end

        -- Verifica se portão abriu
        local elapsed = os.time() - gateStart
        if isGatePassageOpen(passage) or isGateWindowOpen() or elapsed >= 120 then
            break
        end

        -- Mantém parado na safe zone
        local c = safeState.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if r and safeState.CFrame then
            r.CFrame = safeState.CFrame
            r.AssemblyLinearVelocity = Vector3.zero
            r.AssemblyAngularVelocity = Vector3.zero
            r.Anchored = true
        elseif not enterSafeZone(passage) then
            -- Safe zone indisponível, continua tentando
        end

        task.wait(0.3)
    end
    releaseSafeZone()
    if not running then return true end
    log("Portão aberto — atravessando")

    -- ═══ STEP 4: Atravessar (com noclip temporário) ═══
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return false, "Personagem indisponível" end

    -- Arma reload antes de atravessar
    local nextPlace = AUTO_REPLAY and GAME_PLACE or LOBBY_PLACE
    queueTeleport(AUTO_REPLAY and "replay" or "lobby", nextPlace)

    -- Noclip
    local savedCollisions = {}
    for _, part in character:GetDescendants() do
        if part:IsA("BasePart") then
            savedCollisions[part] = part.CanCollide
            part.CanCollide = false
        end
    end

    local finishOffset = math.max(12, (endZ - passage.Position.Z) * direction + 12)
    for _, offset in { -10, 6, finishOffset, finishOffset + 40, finishOffset + 90 } do
        local pos = passage.Position + Vector3.new(0, 0, direction * offset)
        teleportTo(CFrame.lookAt(pos, pos + Vector3.new(0, 0, direction), Vector3.yAxis), false)
        task.wait(0.4)
        if teleporting then break end
        local ef = getEndScreen()
        if ef then break end
    end

    -- Restaura colisão
    for part, cc in savedCollisions do
        if part.Parent then part.CanCollide = cc end
    end

    -- ═══ STEP 5: Espera fim (replay automático) ═══
    log("Aguardando fim da partida")
    exp = os.clock() + 35
    repeat
        if teleporting then return true end
        local ef, outcome = getEndScreen()
        if ef or outcome then
            if AUTO_REPLAY then
                -- Tenta replay (o próximo servidor vai re-carregar via queue)
                local btn = ef and getReplayButton(ef)
                requestReplay(btn)
                log("Replay solicitado")
            end
            task.wait(2)
            return true
        end
        task.wait(0.3)
    until os.clock() >= exp

    return false, "Fim não apareceu"
end

-- ============ LOOP PRINCIPAL ============
local function mainLoop()
    task.spawn(function()
        while running do
            local ctx = getContext()
            if ctx == "Lobby" then
                local ok, err = runLobby()
                if not ok and running then
                    log("Erro lobby: " .. tostring(err))
                    task.wait(RETRY_DELAY)
                end
            elseif ctx == "Game" then
                local ok, err = runGame()
                if not ok and running then
                    log("Erro game: " .. tostring(err))
                    task.wait(RETRY_DELAY)
                end
            else
                log("Place desconhecido: " .. tostring(game.PlaceId))
                task.wait(5)
            end
            task.wait(0.5)
        end
    end)
end

-- ============ EVENTOS ============
player.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then
        teleporting = true
        log("Teleport iniciado")
    end
end)

TeleportService.TeleportInitFailed:Connect(function(failedPlayer, result, message)
    if failedPlayer ~= player then return end
    teleporting = false
    log("Teleport falhou: " .. tostring(message) .. " — retry em 10s")
    task.wait(10)
    local ctx = getContext()
    local target = ctx == "Lobby" and GAME_PLACE or GAME_PLACE
    queueTeleport("retry", target)
    pcall(TeleportService.Teleport, TeleportService, target, player)
end)

-- ============ INICIAR ============
env.RunawaysTPReloading = nil
log("Script carregado | Contexto: " .. getContext() .. " | Place: " .. tostring(game.PlaceId))
mainLoop()
