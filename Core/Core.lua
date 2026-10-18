local ADDON_NAME, NF = ...

NF.DEFAULTS = {
    settings = {
        enabled = true,
        -- Turn Find Minerals / Find Herbs on and off to match what's ticked,
        -- and back on after death (see Modules/Tracking.lua).
        manageTracking = true,
        -- [lowercased node name] = false when unchecked. Missing means on.
        nodes = {},
        -- Scanning uses a private hidden tooltip so the player's own tooltips
        -- aren't disturbed; this switches to the shared GameTooltip instead if
        -- the private one turns out not to return minimap results.
        sharedTooltip = false,
        arrow = {
            point = "CENTER",
            x = 0,
            y = 150,
            size = 48,
        },
    },
}

local function ApplyDefaults(defaults, target)
    target = target or {}
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = ApplyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

NF.readyCallbacks = {}

function NF:OnDBReady(callback)
    if NF.db then
        callback()
    else
        table.insert(NF.readyCallbacks, callback)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")

    NodeFinderDB = ApplyDefaults(NF.DEFAULTS, NodeFinderDB)
    NF.db = NodeFinderDB

    for _, callback in ipairs(NF.readyCallbacks) do
        callback()
    end
    NF.readyCallbacks = {}
end)

_G[ADDON_NAME] = NF
