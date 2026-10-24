local ADDON_NAME, NF = ...

-- A light beam over the node you are about to reach, for the nodes you ticked.
--
-- Addons can't draw in the 3D world and the client has no world-to-screen
-- call, so the only thing that follows an object on screen is a nameplate. The
-- game's "soft interact" system always picks the nearest thing you could
-- interact with (the unit token "softinteract", out to about 15 yards) and can
-- give it a nameplate. This module
--   * turns that system on, and the nameplate only while the target is a node
--     you ticked,
--   * decides whether the target is such a node (its name, or failing that its
--     cursor icon: Mine / Gather Herbs),
--   * hangs a beam on the nameplate: dim until you are in reach, bright with a
--     ring pulse once you can gather it, grey if you can't (skill too low).
-- It cannot mark nodes farther away than the game soft-targets; that is the
-- arrow's job.

local SOFT = "softinteract"
local MEDIA = "Interface\\AddOns\\NodeFinder\\Media\\Highlight\\"

local POLL_SECONDS = 0.1
local REAPPLY_SECONDS = 10      -- settings can be reset by other addons or presets
local FADE_IN = 0.35
local BLEND_SECONDS = 0.3
local STATE_DELAY = 0.15        -- a state must hold this long before it shows (no flicker at the range edge)
local LOCK_DELAY = 0.6
local BEAM_WIDTH = 40
local BEAM_HEIGHT = 190
local GLOW_SIZE = 96
local RING_SIZE = 120
local RING_PERIOD = 1.6
local GREY = { 0.62, 0.62, 0.62 }

-- What the soft-target system needs, as console variables.
local CORE_CVARS = {
    { "SoftTargetInteract", 3 },             -- interaction soft target always on
    { "SoftTargetInteractRange", 60 },       -- ask for the largest range; the game stops at about 15 yards
    { "SoftTargetInteractArc", 2 },          -- all around, not just in front
    { "SoftTargetInteractOnlyInRange", 0 },  -- also pick objects you can't reach yet
}
-- The game's own icon above the target.
local ICON_CVARS = {
    { "SoftTargetIconInteract", 1 },
    { "SoftTargetIconGameObject", 1 },
    { "SoftTargetLowPriorityIcons", 1 },
}
local GATE_CVAR = "SoftTargetNameplateInteract"

local sin, min, max = math.sin, math.min, math.max

local gateOpen              -- what we last wrote to the nameplate switch; nil = unknown
local applied = false       -- the soft-target settings have been put in place
local pendingCVars = false  -- "apply" or "restore" once combat ends
local activeUnits = {}      -- nameplateN -> true
local cursorIDs = {}        -- fileID -> { kind, blocked }
local forceAll = false      -- /nf highlight test: any object counts as a node
local stats = { count = 0, max = 0, last = nil }
local beam = {}

local function Settings()
    return NF.db.settings.highlight
end

local function Say(fmt, ...)
    print("|cff55ccffNodeFinder:|r " .. string.format(fmt, ...))
end

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- Calls about other units can fail or hand back secret values; both mean "unknown".
local function SafeCall(func, ...)
    if not func then
        return nil
    end
    local ok, result = pcall(func, ...)
    if not ok or IsSecret(result) then
        return nil
    end
    return result
end

local function Lerp(a, b, t)
    return a + (b - a) * t
end

local function Approach(value, target, step)
    if value < target then
        return min(value + step, target)
    end
    return max(value - step, target)
end

local function Enabled()
    local settings = NF.db and NF.db.settings
    return settings ~= nil and settings.enabled and settings.highlight.enabled and NF:AnyNodeEnabled()
end

-- Console variables ---------------------------------------------------------

local function GetCVarValue(name)
    local ok, value = pcall(C_CVar.GetCVar, name)
    if ok then
        return value
    end
end

-- Only writes when the value differs: every write runs the game's own
-- handlers under this addon's name.
local function SetCVarValue(name, value)
    local current = GetCVarValue(name)
    value = tostring(value)
    if current == nil or current == value then
        return
    end
    pcall(C_CVar.SetCVar, name, value)
end

local function EachManagedCVar(callback)
    for _, entry in ipairs(CORE_CVARS) do callback(entry[1], entry[2], false) end
    for _, entry in ipairs(ICON_CVARS) do callback(entry[1], entry[2], true) end
    callback(GATE_CVAR, nil, false)
end

local function SaveOriginals()
    local saved = NF.db.highlightSaved or {}
    NF.db.highlightSaved = saved
    EachManagedCVar(function(name)
        if saved[name] == nil then
            -- ForeverLootSparkles saves the true original before it moves a
            -- setting; ours would be its changed value if it got there first.
            saved[name] = NF:OtherSavedCVar(name) or GetCVarValue(name) or false
        end
    end)
    return saved
end

local Evaluate

local function ApplyCVars()
    if InCombatLockdown() then
        pendingCVars = "apply"
        return
    end
    local saved = SaveOriginals()
    for _, entry in ipairs(CORE_CVARS) do
        SetCVarValue(entry[1], entry[2])
    end
    -- ForeverLootSparkles wants the icons on, so never turn them off under it.
    local iconsOn = Settings().icon or NF:IsOtherLoaded()
    for _, entry in ipairs(ICON_CVARS) do
        if iconsOn then
            SetCVarValue(entry[1], entry[2])
        elseif saved[entry[1]] and saved[entry[1]] ~= false then
            SetCVarValue(entry[1], saved[entry[1]])
        end
    end
    gateOpen = nil
    applied = true
end

local function RestoreCVars()
    if InCombatLockdown() then
        pendingCVars = "restore"
        return
    end
    local saved = NF.db.highlightSaved
    NF.db.highlightSaved = nil
    applied = false
    -- With ForeverLootSparkles installed these settings are its to manage.
    if not saved or NF:IsOtherLoaded() then
        return
    end
    for name, value in pairs(saved) do
        if value ~= false then
            SetCVarValue(name, value)
        end
    end
    gateOpen = nil
end

-- The game's nameplate on the interaction target, which the beam hangs on. Open
-- only while the target is one of our nodes, so NPCs and mailboxes you walk up
-- to don't grow nameplates.
local function SetGate(open)
    if open == gateOpen or InCombatLockdown() then
        return
    end
    gateOpen = open
    SetCVarValue(GATE_CVAR, open and 1 or 0)
end

-- ForeverLootSparkles uses the same switch for quest objects and corpses with
-- loot, so under it we only close the nameplate when the target is clearly
-- neither: nothing, or a living unit.
local function MayCloseGate(unit)
    if not NF:IsOtherLoaded() or not unit then
        return true
    end
    if SafeCall(UnitIsGameObject, unit) ~= false then
        return false
    end
    return SafeCall(UnitIsDead, unit) == false
end

-- Telling nodes apart -------------------------------------------------------

local probe = UIParent:CreateTexture(nil, "BACKGROUND") -- hidden; reads the cursor icon
probe:Hide()

if GetFileIDFromPath then
    for _, spec in ipairs({ { "Mine", "ore" }, { "GatherHerbs", "herb" } }) do
        for _, prefix in ipairs({ "", "Unable" }) do
            local path = "Interface\\Cursor\\" .. prefix .. spec[1]
            local id = SafeCall(GetFileIDFromPath, path) or SafeCall(GetFileIDFromPath, path .. ".blp")
            if id then
                cursorIDs[id] = { spec[2], prefix ~= "" }
            end
        end
    end
end

-- The client may give a file ID, a path (Interface\Cursor\Mine) or an atlas
-- name (Cursor_Crosshair_UnableMine_64), so look for keywords in strings.
local function ReadCursorText(text)
    if type(text) ~= "string" then
        return nil, false
    end
    text = text:lower()
    local blocked = text:find("unable", 1, true) ~= nil
    if text:find("gather", 1, true) or text:find("herb", 1, true) then
        return "herb", blocked
    end
    if text:find("mine", 1, true) then
        return "ore", blocked
    end
    return nil, blocked
end

-- "ore" / "herb" / nil from the target's cursor icon, and whether it is the
-- greyed "can't do that" version.
local function ReadCursor(unit)
    if not SafeCall(SetUnitCursorTexture, probe, unit, nil, true) then
        return nil, false
    end
    local texture = probe:GetTexture()
    local atlas = probe.GetAtlas and probe:GetAtlas()
    if IsSecret(texture) then texture = nil end
    if IsSecret(atlas) then atlas = nil end

    local known = type(texture) == "number" and cursorIDs[texture]
    if known then
        return known[1], known[2]
    end
    local kind, blocked = ReadCursorText(texture)
    if not kind then
        local atlasKind, atlasBlocked = ReadCursorText(atlas)
        kind, blocked = atlasKind, blocked or atlasBlocked
    end
    return kind, blocked
end

-- Is the soft target a node we should mark? Returns its kind ("ore"/"herb"),
-- whether the game greys out its cursor, and its name. Nodes you didn't tick
-- return nothing.
local function Classify(unit)
    if SafeCall(UnitIsGameObject, unit) ~= true then
        return nil
    end
    local name = SafeCall(UnitName, unit)
    if type(name) ~= "string" then
        name = nil
    end
    local cursorKind, blocked = ReadCursor(unit)
    local listed = name and NF.NODE_KIND[name:lower()]
    local kind = listed or cursorKind

    if not kind then
        if forceAll then
            return "ore", blocked, name
        end
        return nil
    end
    local ticked
    if listed then
        ticked = NF:IsNodeEnabled(name)
    else
        ticked = NF:IsKindEnabled(kind) -- a node variant we don't have by name
    end
    if not ticked and not forceAll then
        return nil
    end
    return kind, blocked, name
end

-- "ready": you can gather it now; "far": not yet in reach; "locked": in reach
-- but the game refuses (skill too low and the like).
local function ReadState(unit, blocked)
    local inRange = SafeCall(UnitIsInInteractRange, unit)
    if inRange == false then
        return "far"
    end
    if blocked then
        return inRange == true and "locked" or "far"
    end
    return "ready"
end

-- Target and nameplate -------------------------------------------------------

local function PlateFor(unit)
    return C_NamePlate and SafeCall(C_NamePlate.GetNamePlateForUnit, unit)
end

-- True, false, or nil when the client won't say. A world object doesn't "exist"
-- as far as UnitExists is concerned.
local function SoftTargetExists()
    local isUnit, isObject = SafeCall(UnitExists, SOFT), SafeCall(UnitIsGameObject, SOFT)
    if isUnit == true or isObject == true then
        return true
    end
    if isUnit == false and isObject == false then
        return false
    end
    return nil
end

-- The unit token to ask about, and its nameplate (nil if the game hasn't made
-- it yet).
local function ResolveTarget()
    local exists = SoftTargetExists()
    if exists == false then
        return nil
    end
    local plate = PlateFor(SOFT)
    if not plate then
        for unit in pairs(activeUnits) do
            if SafeCall(UnitIsUnit, unit, SOFT) == true then
                plate = PlateFor(unit)
                if plate then
                    break
                end
            end
        end
    end
    if plate or exists then
        return SOFT, plate
    end
    return nil
end

-- The beam -----------------------------------------------------------------

local function TintFor(kind)
    local c = kind == "herb" and Settings().tintHerb or Settings().tintOre
    return c[1], c[2], c[3]
end

local function Animate(self, elapsed)
    if elapsed > 0.1 then
        elapsed = 0.1 -- no jump after a frame freeze
    end
    local scale = Settings().scale
    beam.time = beam.time + elapsed
    beam.appear = Approach(beam.appear, 1, elapsed / FADE_IN)
    beam.ready = Approach(beam.ready, beam.state == "ready" and 1 or 0, elapsed / BLEND_SECONDS)
    beam.locked = Approach(beam.locked, beam.state == "locked" and 1 or 0, elapsed / BLEND_SECONDS)
    local ready, locked = beam.ready, beam.locked

    local level = beam.appear * Lerp(0.45, 1, ready) * (1 - 0.5 * locked)
    local tr, tg, tb = TintFor(beam.kind)
    local r, g, b = Lerp(tr, GREY[1], locked), Lerp(tg, GREY[2], locked), Lerp(tb, GREY[3], locked)
    local pulse = 0.88 + 0.12 * sin(beam.time * 2.4)

    beam.shaft:SetSize(BEAM_WIDTH * scale * (0.92 + 0.08 * sin(beam.time * 3.3 + 1)),
        BEAM_HEIGHT * scale * (0.85 + 0.15 * ready))
    beam.shaft:SetVertexColor(r, g, b, min(level * pulse, 1))

    local glowSize = GLOW_SIZE * scale * (0.9 + 0.1 * pulse)
    beam.glow:SetSize(glowSize, glowSize)
    beam.glow:SetVertexColor(r, g, b, min(level * pulse * 0.9, 1))

    -- A ring spreads out from the base while the node is in reach.
    local phase = ((beam.time - beam.ringStart) % RING_PERIOD) / RING_PERIOD
    local ringSize = RING_SIZE * scale * (0.35 + 0.65 * phase)
    beam.ring:SetSize(ringSize, ringSize)
    beam.ring:SetVertexColor(r, g, b, ready * (1 - phase) * 0.8 * beam.appear)
end

local function CreateBeam()
    local frame = CreateFrame("Frame")
    frame:SetSize(1, 1)
    frame:Hide()

    local function Layer(file, width, height)
        local texture = frame:CreateTexture(nil, "OVERLAY")
        texture:SetTexture(MEDIA .. file)
        texture:SetBlendMode("ADD")
        texture:SetVertexColor(1, 1, 1, 0)
        texture:SetSize(width, height)
        return texture
    end

    beam.glow = Layer("Glow", GLOW_SIZE, GLOW_SIZE)
    beam.glow:SetPoint("CENTER", frame, "CENTER")
    beam.ring = Layer("Ring", RING_SIZE, RING_SIZE)
    beam.ring:SetPoint("CENTER", frame, "CENTER")
    beam.shaft = Layer("Beam", BEAM_WIDTH, BEAM_HEIGHT)
    beam.shaft:SetPoint("BOTTOM", frame, "CENTER")

    frame:SetScript("OnUpdate", Animate)
    beam.frame = frame
    return frame
end

local function Release()
    if not beam.plate then
        return
    end
    beam.frame:Hide()
    beam.frame:ClearAllPoints()
    beam.frame:SetParent(nil)
    beam.plate, beam.retarget, beam.offset = nil, nil, nil
end

local function PlaceBeam()
    beam.frame:ClearAllPoints()
    beam.frame:SetPoint("CENTER", beam.plate, "CENTER", 0, Settings().offsetY)
    beam.offset = Settings().offsetY
end

local function Attach(plate, kind, state)
    local frame = beam.frame or CreateBeam()
    frame:SetParent(plate)
    -- under the nameplate's own content so its text stays readable
    local ok, level = pcall(plate.GetFrameLevel, plate)
    if ok and level and not IsSecret(level) then
        frame:SetFrameLevel(max(level - 1, 0))
    end
    frame:SetIgnoreParentAlpha(true)

    beam.plate, beam.kind, beam.state, beam.pending = plate, kind, state, nil
    beam.time, beam.ringStart = 0, 0
    beam.appear = 0
    beam.ready = state == "ready" and 1 or 0
    beam.locked = state == "locked" and 1 or 0
    PlaceBeam()
    frame:Show()
end

-- A new state only shows once it has held for a moment.
local function ProposeState(state)
    if state == beam.state then
        beam.pending = nil
        return
    end
    local now = GetTime()
    if beam.pending ~= state then
        beam.pending, beam.pendingSince = state, now
    elseif now - beam.pendingSince >= (state == "locked" and LOCK_DELAY or STATE_DELAY) then
        beam.pending = nil
        beam.state = state
        if state == "ready" then
            beam.ringStart = beam.time -- the ring starts from the base right now
        end
    end
end

-- How far, by the minimap scan, was the node when the game picked it? Tells how
-- close the game really gets before it soft-targets something.
local function RecordAcquire(name)
    if not name or not NF.PlayerWorldPosition then
        return
    end
    local continent, px, py = NF.PlayerWorldPosition()
    if not continent then
        return
    end
    local wanted, best = name:lower(), nil
    for _, node in ipairs(NF.nodes) do
        if node.continent == continent and node.name:lower() == wanted then
            local d = math.sqrt((node.x - px) ^ 2 + (node.y - py) ^ 2)
            if not best or d < best then
                best = d
            end
        end
    end
    if best then
        stats.count = stats.count + 1
        stats.last = best
        stats.max = max(stats.max, best)
    end
end

-- Finds the interaction target, then brings the game's nameplate and the beam
-- in line with it.
function Evaluate()
    if not Enabled() then
        Release()
        return
    end
    if not applied and not InCombatLockdown() then
        ApplyCVars() -- the first node was just ticked, or the addon just started
    end

    local unit, plate = ResolveTarget()
    local kind, blocked, name
    if unit then
        kind, blocked, name = Classify(unit)
    end

    if not kind then
        Release()
        if MayCloseGate(unit) then
            SetGate(false)
        end
        return
    end

    SetGate(true)
    if not plate then
        Release() -- just asked for; the beam follows when the nameplate arrives
        return
    end

    local state = ReadState(unit, blocked)
    if beam.plate ~= plate or beam.retarget then
        Release()
        Attach(plate, kind, state)
        RecordAcquire(name)
    else
        beam.kind = kind
        ProposeState(state)
        if beam.offset ~= Settings().offsetY then
            PlaceBeam()
        end
    end
end

-- Switching it on and off ----------------------------------------------------

local failures = 0
local stopped = false

-- Everything that runs on a timer or event goes through here, so an
-- unexpected error can't repeat ten times a second in the player's error
-- window: after a few in a row the highlight stops itself and says why.
local function SafeEvaluate()
    if stopped then
        return
    end
    local ok, err = pcall(Evaluate)
    if ok then
        failures = 0
        return
    end
    failures = failures + 1
    NF.highlightError = tostring(err)
    if failures >= 3 then
        stopped = true
        pcall(Release)
        Say("the beam stopped after repeated errors: %s", NF.highlightError)
        Say("/nf highlight debug shows the details; /reload tries again.")
    end
end

local poller = CreateFrame("Frame")
local sinceCheck = 0
poller:SetScript("OnUpdate", function(_, elapsed)
    sinceCheck = sinceCheck + elapsed
    if sinceCheck >= POLL_SECONDS then
        sinceCheck = 0
        SafeEvaluate()
    end
end)

-- Brings everything in line with the settings. Safe to call at any time.
function NF:RefreshHighlight()
    if not NF.db then
        return
    end
    if Enabled() then
        ApplyCVars()
        SafeEvaluate()
    else
        Release()
        if NF.db.highlightSaved and not NF.db.settings.highlight.enabled then
            RestoreCVars()
        end
    end
    NF:TakeOverOther()
end

function NF:SetHighlightOption(key, value)
    Settings()[key] = value
    NF:RefreshHighlight()
end

function NF:SetHighlightTest(on)
    forceAll = on and true or false
end

function NF:HighlightDebug()
    local function Raw(value)
        if IsSecret(value) then
            return "<secret>"
        end
        return tostring(value)
    end

    Say("highlight: %s%s%s", Enabled() and "on" or "off", forceAll and " (test mode: any object counts)" or "",
        stopped and " (stopped after errors)" or "")
    if NF.highlightError then
        Say("  last error: %s", NF.highlightError)
    end
    local unit, plate = ResolveTarget()
    if not unit then
        Say("  soft target: none (stand near a node)")
    else
        local isObject = SafeCall(UnitIsGameObject, unit)
        local name = SafeCall(UnitName, unit)
        local cursorKind, blocked = ReadCursor(unit)
        local texture
        if SafeCall(SetUnitCursorTexture, probe, unit, nil, true) then
            texture = probe:GetTexture()
        end
        local kind = Classify(unit)
        Say("  soft target: object=%s name=%s cursor=%s%s (raw %s)", Raw(isObject), Raw(name), Raw(cursorKind),
            blocked and " [greyed]" or "", Raw(texture))
        Say("  counts as one of your nodes: %s; nameplate: %s; in reach: %s", kind and kind or "no",
            plate and "yes" or "no", Raw(SafeCall(UnitIsInInteractRange, unit)))
    end

    local wrong = {}
    for _, entry in ipairs(CORE_CVARS) do
        local current = GetCVarValue(entry[1])
        if current ~= tostring(entry[2]) then
            wrong[#wrong + 1] = string.format("%s=%s (want %s)", entry[1], tostring(current), tostring(entry[2]))
        end
    end
    Say("  soft-target settings: %s; nameplate switch %s", #wrong == 0 and "as wanted" or table.concat(wrong, ", "),
        tostring(GetCVarValue(GATE_CVAR)))

    if NF:IsOtherLoaded() then
        local theirs = _G.ForeverLootSparklesDB
        Say("  ForeverLootSparkles: loaded; its ore sparkle = %s, herb sparkle = %s; taking over: %s",
            theirs and tostring(theirs.sparkleOre) or "?", theirs and tostring(theirs.sparkleHerbs) or "?",
            Settings().takeOver and "yes" or "no")
    else
        Say("  ForeverLootSparkles: not loaded")
    end
    if stats.count > 0 then
        Say("  the game picked a node when the scan put it %.0f yd away at most (last %.0f yd, %d samples)",
            stats.max, stats.last, stats.count)
    else
        Say("  no node pickups measured yet")
    end
end

-- Events ----------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_LOGIN()
    if Enabled() then
        ApplyCVars()
    end
end
handlers.VARIABLES_LOADED = handlers.PLAYER_LOGIN
handlers.PLAYER_ENTERING_WORLD = handlers.PLAYER_LOGIN

-- Console variables can't change in combat: close the nameplate just before, or
-- every lootable corpse would keep a 0% health nameplate until the fight ends.
function handlers.PLAYER_REGEN_DISABLED()
    if Enabled() and MayCloseGate(nil) then
        SetGate(false)
    end
end

function handlers.PLAYER_REGEN_ENABLED()
    local pending = pendingCVars
    pendingCVars = false
    if pending == "apply" and Enabled() then
        ApplyCVars()
    elseif pending == "restore" then
        RestoreCVars()
    end
    SafeEvaluate()
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
    activeUnits[unit] = true
    SafeEvaluate()
end

function handlers.NAME_PLATE_UNIT_REMOVED(unit)
    activeUnits[unit] = nil
    local plate = PlateFor(unit)
    if plate and plate == beam.plate then
        Release()
    end
end

function handlers.PLAYER_SOFT_INTERACT_CHANGED()
    -- a recycled nameplate doesn't show a change of target by itself
    beam.retarget = beam.plate ~= nil
    SafeEvaluate()
end

NF:OnDBReady(function()
    local events = CreateFrame("Frame")
    events:SetScript("OnEvent", function(_, event, ...)
        handlers[event](...)
    end)
    for event in pairs(handlers) do
        pcall(events.RegisterEvent, events, event)
    end

    C_Timer.NewTicker(REAPPLY_SECONDS, function()
        if Enabled() and not InCombatLockdown() then
            ApplyCVars()
        end
    end)

    if not NF.db.settings.highlight.enabled and NF.db.highlightSaved then
        RestoreCVars() -- it was switched off while the addon wasn't running
    end
    poller:Show() -- cheap while nothing is enabled
end)
