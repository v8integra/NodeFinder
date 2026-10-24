local ADDON_NAME, NF = ...

-- Living alongside ForeverLootSparkles.
--
-- Both addons hang an effect on the game's soft-target nameplate, so for ore
-- and herb nodes only one of them should. NodeFinder takes those two
-- categories; ForeverLootSparkles keeps everything else (quest items, quest
-- objects, corpses with loot).
--
-- The only handle on another addon is its saved-variables table, which it reads
-- every time it decides what to sparkle. So for the session we set its
-- "Ore veins" and "Herbs" switches to off, and put them back at logout, before
-- the game writes saved variables. Nothing is changed on disk. If the player
-- switches one of them back on in ForeverLootSparkles' own options, that is
-- taken as a choice: NodeFinder stops taking over and says so.

local OTHER_ADDON = "ForeverLootSparkles"
local OTHER_DB = "ForeverLootSparklesDB"
local OTHER_KEYS = { "sparkleOre", "sparkleHerbs" }
local CHECK_SECONDS = 3

local originals = {}   -- key -> the value it had before we switched it off
local taken = {}       -- key -> true while we are the one holding it off
local told = false

local function Say(fmt, ...)
    print("|cff55ccffNodeFinder:|r " .. string.format(fmt, ...))
end

local function OtherDB()
    local db = _G[OTHER_DB]
    if type(db) == "table" then
        return db
    end
end

function NF:IsOtherLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(OTHER_ADDON) and true or false
    end
    return IsAddOnLoaded and IsAddOnLoaded(OTHER_ADDON) and true or false
end

-- The value ForeverLootSparkles saved for a console variable before it changed
-- it, if it has. That is the real original, which ours can't be once the other
-- addon has already moved the setting.
function NF:OtherSavedCVar(name)
    local db = OtherDB()
    local saved = db and db.savedCVars
    if type(saved) == "table" then
        local value = saved[name]
        if value ~= nil and value ~= false then
            return value
        end
    end
end

function NF:ReleaseOther()
    local db = OtherDB()
    if db then
        for key, value in pairs(originals) do
            if taken[key] then
                db[key] = value
            end
        end
    end
    wipe(originals)
    wipe(taken)
end

function NF:TakeOverOther()
    local db = OtherDB()
    if not db or not NF.db then
        return
    end

    local settings = NF.db.settings.highlight
    if not (settings.enabled and settings.takeOver) then
        NF:ReleaseOther()
        return
    end

    for _, key in ipairs(OTHER_KEYS) do
        if taken[key] and db[key] ~= false then
            -- It was switched back on by hand in the other addon's options.
            settings.takeOver = false
            NF:ReleaseOther()
            Say("ForeverLootSparkles' ore/herb sparkles were switched back on, so NodeFinder will leave them to it. /nf highlight takeover on to take them over again.")
            return
        end
    end

    for _, key in ipairs(OTHER_KEYS) do
        if not taken[key] and db[key] ~= false then
            originals[key] = db[key]
            db[key] = false
            taken[key] = true
            if not told then
                told = true
                Say("ForeverLootSparkles is installed: NodeFinder now handles ore and herbs (its quest, corpse and loot sparkles are untouched). /nf highlight takeover off undoes this.")
            end
        end
    end
end

NF:OnDBReady(function()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            NF:TakeOverOther()
        else
            NF:ReleaseOther() -- before saved variables are written
        end
    end)
    C_Timer.NewTicker(CHECK_SECONDS, function()
        NF:TakeOverOther()
    end)
end)
