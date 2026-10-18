local ADDON_NAME, NF = ...

-- Keeps Find Minerals / Find Herbs matching what's ticked: on while any node of
-- that kind is selected, off when none is. The client switches tracking off when
-- the player dies, so this also puts it back after a resurrection.
--
-- C_Minimap.SetTracking(index, on) is the same call GatherLite uses. It is only
-- attempted out of combat and while alive, and re-tried from the events that
-- fire when those change, plus a slow ticker for anything missed.
--
-- The two spells might be mutually exclusive in some clients (turning one on
-- turns the other off). To avoid flipping between them forever, repeated
-- corrections in a short window make the addon stop managing and say so.

local CHECK_INTERVAL = 5          -- seconds between safety checks
local CORRECTION_WINDOW = 15      -- seconds
local MAX_CORRECTIONS = 6         -- corrections inside the window before giving up

local KINDS = {
    { kind = "ore", spellID = NF.TRACKING_SPELL_ORE, label = "Find Minerals" },
    { kind = "herb", spellID = NF.TRACKING_SPELL_HERB, label = "Find Herbs" },
}

NF.trackingGaveUp = false

local corrections = {}

local function RecordCorrection()
    local now = GetTime()
    corrections[#corrections + 1] = now
    while corrections[1] and now - corrections[1] > CORRECTION_WINDOW do
        table.remove(corrections, 1)
    end
    return #corrections
end

local function GiveUp()
    NF.trackingGaveUp = true
    print("|cff55ccffNodeFinder:|r Find Minerals and Find Herbs keep switching each other off, so I've stopped managing tracking. "
        .. "Turn on the ones you want yourself, or use /nf tracking on to try again.")
end

function NF:ApplyTracking()
    local settings = NF.db and NF.db.settings
    if not settings or not settings.manageTracking or not settings.enabled or NF.trackingGaveUp then
        return
    end
    if InCombatLockdown() or UnitIsDeadOrGhost("player") then
        return
    end
    if not C_Minimap or not C_Minimap.GetNumTrackingTypes or not C_Minimap.SetTracking then
        return
    end

    local entries = {}
    for index = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(index)
        if info and info.spellID then
            entries[info.spellID] = { index = index, active = info.active }
        end
    end

    for _, entry in ipairs(KINDS) do
        local tracking = entries[entry.spellID]
        -- Not offered to this character (profession not learned): nothing to do.
        if tracking then
            local wanted = NF:IsKindEnabled(entry.kind)
            if tracking.active ~= wanted then
                if RecordCorrection() > MAX_CORRECTIONS then
                    GiveUp()
                    return
                end
                C_Minimap.SetTracking(tracking.index, wanted)
            end
        end
    end
end

local pending = false

-- Coalesces bursts of events into one check a moment later.
function NF:ScheduleTrackingCheck()
    if pending then
        return
    end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        NF:ApplyTracking()
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "MINIMAP_UPDATE_TRACKING",
    "SPELLS_CHANGED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function()
    NF:ScheduleTrackingCheck()
end)

NF:OnDBReady(function()
    C_Timer.NewTicker(CHECK_INTERVAL, function()
        NF:ScheduleTrackingCheck()
    end)
    NF:ScheduleTrackingCheck()
end)
