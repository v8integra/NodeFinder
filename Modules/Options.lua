local ADDON_NAME, NF = ...

local ROW_HEIGHT = 22
local HEADER_HEIGHT = 24
local CONTENT_WIDTH = 300

local options = CreateFrame("Frame", "NodeFinderOptions", UIParent, "BasicFrameTemplateWithInset")
options:SetSize(360, 640)
options:SetPoint("CENTER")
options:SetMovable(true)
options:EnableMouse(true)
options:SetClampedToScreen(true)
options:RegisterForDrag("LeftButton")
options:SetScript("OnDragStart", options.StartMoving)
options:SetScript("OnDragStop", options.StopMovingOrSizing)
options:SetFrameStrata("DIALOG")
options:Hide()

local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", options, "TOP", 0, -6)
title:SetText("NodeFinder")

local enabledCheck = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
enabledCheck:SetSize(24, 24)
-- BasicFrameTemplateWithInset has an InsetBg texture but no Inset frame
-- (options.Inset is nil), and an explicitly nil anchor target means the
-- screen, which is how the whole window's contents ended up at the screen's
-- top-left. Anchor to the window itself, offset past its title bar.
enabledCheck:SetPoint("TOPLEFT", options, "TOPLEFT", 12, -30)
local enabledLabel = enabledCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
enabledLabel:SetPoint("LEFT", enabledCheck, "RIGHT", 2, 0)
enabledLabel:SetText("Show the arrow and scan for nodes")
enabledCheck:SetScript("OnClick", function(self)
    NF:SetEnabled(self:GetChecked())
end)

local trackingCheck = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
trackingCheck:SetSize(24, 24)
trackingCheck:SetPoint("TOPLEFT", enabledCheck, "BOTTOMLEFT", 0, -2)
local trackingLabel = trackingCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
trackingLabel:SetPoint("LEFT", trackingCheck, "RIGHT", 2, 0)
trackingLabel:SetText("Switch Find Minerals/Herbs to match")
trackingCheck:SetScript("OnClick", function(self)
    NF.db.settings.manageTracking = self:GetChecked() and true or false
    NF.trackingGaveUp = false
    NF:ScheduleTrackingCheck()
end)
trackingCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Manage tracking", 1, 1, 1)
    GameTooltip:AddLine("Turns Find Minerals on while any ore is ticked and off when none is, likewise for Find Herbs, and turns them back on after you die. Untick this to control tracking yourself.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
trackingCheck:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local function MakeCheck(anchor, text, tooltip, onClick)
    local check = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    label:SetText(text)
    check.label = label
    check:SetScript("OnClick", function(self)
        onClick(self:GetChecked() and true or false)
    end)
    check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return check
end

local highlightCheck = MakeCheck(trackingCheck, "Light beam on the node you reach",
    "Within about 15 yards the game picks the nearest thing you can interact with. When that is a node you ticked, a beam of light marks it. Nodes you didn't tick get nothing. Farther away than that, follow the arrow.",
    function(on) NF:SetHighlightOption("enabled", on) end)

local iconCheck = MakeCheck(highlightCheck, "Show the game's interact icon too",
    "The game's own icon above the node. The same setting also puts it above other things you can interact with.",
    function(on) NF:SetHighlightOption("icon", on) end)

local takeOverCheck = MakeCheck(iconCheck, "Take over ore and herbs from ForeverLootSparkles",
    "With ForeverLootSparkles installed, NodeFinder's beam handles ore and herbs and that addon's ore/herb sparkles stay off for the session. Its quest, corpse and loot sparkles are untouched, and its saved settings are put back when you log out.",
    function(on) NF:SetHighlightOption("takeOver", on) end)

-- Beam colours: a row of presets per node type.
local TINTS = {
    { 0.45, 0.8, 1 }, { 0.5, 1, 0.4 }, { 1, 0.85, 0.4 }, { 1, 1, 1 },
    { 1, 0.6, 0.25 }, { 1, 0.35, 0.35 }, { 0.75, 0.5, 1 }, { 1, 0.5, 0.85 },
}
local swatches = {}

local function SameColor(a, b)
    return math.abs(a[1] - b[1]) < 0.01 and math.abs(a[2] - b[2]) < 0.01 and math.abs(a[3] - b[3]) < 0.01
end

local function MakeSwatchRow(anchor, text, key)
    local label = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -8)
    label:SetText(text)

    for i, tint in ipairs(TINTS) do
        local button = CreateFrame("Button", nil, options)
        button:SetSize(18, 18)
        button:SetPoint("LEFT", label, "LEFT", 118 + (i - 1) * 22, 0)
        local border = button:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints()
        local fill = button:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 2, -2)
        fill:SetPoint("BOTTOMRIGHT", -2, 2)
        fill:SetColorTexture(tint[1], tint[2], tint[3], 1)
        button:SetScript("OnClick", function()
            NF.db.settings.highlight[key] = { tint[1], tint[2], tint[3] }
            for _, other in ipairs(swatches) do
                other.refresh()
            end
        end)
        swatches[#swatches + 1] = {
            refresh = function()
                local selected = SameColor(NF.db.settings.highlight[key], tint)
                if selected then
                    border:SetColorTexture(1, 1, 1, 1)
                else
                    border:SetColorTexture(0, 0, 0, 1)
                end
            end,
        }
    end
    return label
end

local oreTintRow = MakeSwatchRow(takeOverCheck, "Ore beam colour", "tintOre")
local herbTintRow = MakeSwatchRow(oreTintRow, "Herb beam colour", "tintHerb")

local checks = {}

local function RefreshChecks()
    enabledCheck:SetChecked(NF.db.settings.enabled)
    trackingCheck:SetChecked(NF.db.settings.manageTracking)
    local highlight = NF.db.settings.highlight
    highlightCheck:SetChecked(highlight.enabled)
    iconCheck:SetChecked(highlight.icon)
    takeOverCheck:SetChecked(highlight.takeOver)
    if NF:IsOtherLoaded() then
        takeOverCheck:Enable()
        takeOverCheck.label:SetTextColor(1, 1, 1)
    else
        takeOverCheck:Disable()
        takeOverCheck.label:SetTextColor(0.5, 0.5, 0.5)
    end
    for _, swatch in ipairs(swatches) do
        swatch.refresh()
    end
    for name, check in pairs(checks) do
        check:SetChecked(NF:IsNodeEnabled(name))
    end
end

local function MakeButton(text, list, enabled)
    local button = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    button:SetSize(80, 20)
    button:SetText(text)
    button:SetScript("OnClick", function()
        NF:SetAllEnabled(list, enabled)
        RefreshChecks()
    end)
    return button
end

local oreAll = MakeButton("All ore", NF.ORES, true)
oreAll:SetPoint("TOPLEFT", herbTintRow, "BOTTOMLEFT", -4, -10)

local oreNone = MakeButton("No ore", NF.ORES, false)
oreNone:SetPoint("LEFT", oreAll, "RIGHT", 4, 0)

local herbAll = MakeButton("All herbs", NF.HERBS, true)
herbAll:SetPoint("LEFT", oreNone, "RIGHT", 12, 0)

local herbNone = MakeButton("No herbs", NF.HERBS, false)
herbNone:SetPoint("LEFT", herbAll, "RIGHT", 4, 0)

local scrollFrame = CreateFrame("ScrollFrame", "NodeFinderOptionsScroll", options, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", oreAll, "BOTTOMLEFT", 0, -8)
scrollFrame:SetPoint("BOTTOMRIGHT", options, "BOTTOMRIGHT", -32, 8)

-- Sized before it is attached, like TrailBeacon's scrolling list.
local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(CONTENT_WIDTH, 1)
scrollFrame:SetScrollChild(content)

local function BuildList()
    local y = 0

    local function AddHeader(text)
        local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y - 4)
        header:SetText(text)
        y = y + HEADER_HEIGHT
    end

    local function AddCheck(name)
        local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)

        local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText(name)

        check:SetScript("OnClick", function(self)
            NF:SetNodeEnabled(name, self:GetChecked())
        end)

        checks[name] = check
        y = y + ROW_HEIGHT
    end

    AddHeader("Ore")
    for _, name in ipairs(NF.ORES) do
        AddCheck(name)
    end

    AddHeader("Herbs")
    for _, name in ipairs(NF.HERBS) do
        AddCheck(name)
    end

    content:SetSize(CONTENT_WIDTH, y)
    scrollFrame:UpdateScrollChildRect()
end

local built = false

function NF:ToggleOptions()
    if options:IsShown() then
        options:Hide()
        return
    end

    if not built then
        built = true
        BuildList()
    end
    RefreshChecks()
    options:Show()
end

-- Slash commands ------------------------------------------------------------

local function Say(fmt, ...)
    print("|cff55ccffNodeFinder:|r " .. string.format(fmt, ...))
end

local function PrintStatus()
    local scanInfo = NF.lastScan
    if scanInfo then
        Say("last scan: %d node(s) in range, %d probes, %.2fs, %.0fs ago",
            scanInfo.nodes, scanInfo.probes, scanInfo.seconds, GetTime() - scanInfo.time)
    else
        Say("no scan has finished yet.")
    end
    if NF.scanError then
        Say("last scan error: %s", NF.scanError)
    end
    Say("tracking: Find Minerals %s, Find Herbs %s",
        NF.oreTracking and "on" or "off", NF.herbTracking and "on" or "off")

    local node, _, _, distance = NF:GetNearestNode()
    if node then
        Say("nearest selected node: %s, %.0f yd", node.name, distance)
    else
        Say("no selected node in range.")
    end

    local shown = 0
    for _, found in ipairs(NF.nodes) do
        if shown < 12 then
            shown = shown + 1
            Say("  %s%s", found.name, NF:IsNodeEnabled(found.name) and "" or " (not selected)")
        end
    end
end

local function PrintUnknown()
    local names = {}
    for name in pairs(NF.lastUnknown) do
        names[#names + 1] = name
    end
    table.sort(names)
    if #names == 0 then
        Say("the last scan saw no minimap names that aren't in the node lists.")
        return
    end
    Say("names the last scan saw that aren't in the node lists (a missing node variant would show up here):")
    for _, name in ipairs(names) do
        Say("  %s", name)
    end
end

local function RunTest()
    local results, err = NF:RunTest()
    if not results then
        Say("%s", err)
        return
    end
    Say("test, standing within minimap range of a tracked node:")
    for _, r in ipairs(results) do
        Say("  %s tooltip: %d probe(s) returned text, %d matched a known node", r.name, r.anyText, r.knownNodes)
    end
    Say("If 'private' finds nothing but 'shared' does, run /nf tooltip shared.")
end

local MAX_PROBE_LINES = 20

local function RunProbe(step)
    local clusters, probes, usedStep, yardsPerUnit = NF:ProbeAll(step)
    if not clusters then
        Say("%s", probes)
        return
    end

    Say("probe: %d probes, step %.1f. Every distinct minimap text, nearest to the center first:", probes, usedStep)
    if #clusters == 0 then
        Say("  nothing came back at all.")
        return
    end

    for i = 1, math.min(#clusters, MAX_PROBE_LINES) do
        local c = clusters[i]
        -- Doubled so inline markup (color codes, icons) shows up literally.
        local text = c.text:gsub("|", "||")
        local where = yardsPerUnit
            and string.format("%.0f yd right, %.0f yd up", c.x * yardsPerUnit, c.y * yardsPerUnit)
            or string.format("%.0f right, %.0f up", c.x, c.y)
        Say("  [%s] %s: %d hit(s), hit area %.0f x %.0f, %s",
            c.known and "node" or "other", text, c.hits, c.width, c.height, where)
    end
    if #clusters > MAX_PROBE_LINES then
        Say("  ... and %d more", #clusters - MAX_PROBE_LINES)
    end
end

local function OnOff(value)
    return value and "on" or "off"
end

local function HighlightCommand(arg)
    local settings = NF.db.settings.highlight
    local sub, value = arg:match("^(%S*)%s*(.-)$")
    local flag = nil
    if value == "on" then
        flag = true
    elseif value == "off" then
        flag = false
    end

    if sub == "" or sub == "status" then
        Say("beam %s, game icon %s, taking over ForeverLootSparkles' ore/herbs %s%s, size %.2f, height offset %d.",
            OnOff(settings.enabled), OnOff(settings.icon), OnOff(settings.takeOver),
            NF:IsOtherLoaded() and "" or " (not installed)", settings.scale, settings.offsetY)
        Say("/nf highlight on | off | icon on|off | takeover on|off | size <0.5-2.5> | offset <pixels> | test | debug")
    elseif sub == "on" or sub == "off" then
        NF:SetHighlightOption("enabled", sub == "on")
        Say("beam %s", sub)
    elseif sub == "icon" and flag ~= nil then
        NF:SetHighlightOption("icon", flag)
        Say("game icon %s", value)
    elseif sub == "takeover" and flag ~= nil then
        NF:SetHighlightOption("takeOver", flag)
        Say("taking over ForeverLootSparkles' ore and herbs: %s", value)
    elseif sub == "size" and tonumber(value) then
        NF:SetHighlightOption("scale", math.max(0.5, math.min(2.5, tonumber(value))))
        Say("beam size %.2f", settings.scale)
    elseif sub == "offset" and tonumber(value) then
        NF:SetHighlightOption("offsetY", math.max(-300, math.min(300, tonumber(value))))
        Say("beam height offset %.0f (lower puts the beam's base lower on the node)", settings.offsetY)
    elseif sub == "test" then
        local on = value ~= "off"
        NF:SetHighlightTest(on)
        if on then
            Say("test mode on: any object you soft-target gets the beam, to check its placement. /nf highlight test off to end.")
        else
            Say("test mode off: ticked nodes only.")
        end
    elseif sub == "debug" then
        NF:HighlightDebug()
    else
        Say("/nf highlight on | off | icon on|off | takeover on|off | size <0.5-2.5> | offset <pixels> | test | debug")
    end
end

SLASH_NODEFINDER1 = "/nodefinder"
SLASH_NODEFINDER2 = "/nf"
SlashCmdList["NODEFINDER"] = function(msg)
    local command, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()
    arg = arg:lower()

    if command == "" or command == "options" then
        NF:ToggleOptions()
    elseif command == "on" then
        NF:SetEnabled(true)
        Say("on")
    elseif command == "off" then
        NF:SetEnabled(false)
        Say("off")
    elseif command == "status" or command == "debug" then
        PrintStatus()
    elseif command == "unknown" then
        PrintUnknown()
    elseif command == "test" then
        RunTest()
    elseif command == "probe" then
        RunProbe(tonumber(arg))
    elseif command == "tracking" then
        if arg == "on" or arg == "off" then
            NF.db.settings.manageTracking = (arg == "on")
            NF.trackingGaveUp = false
            NF:ScheduleTrackingCheck()
            Say("tracking management %s", arg)
        else
            Say("tracking management is %s%s. /nf tracking on | off",
                NF.db.settings.manageTracking and "on" or "off",
                NF.trackingGaveUp and " (stopped after a conflict)" or "")
        end
    elseif command == "highlight" then
        HighlightCommand(arg)
    elseif command == "tooltip" then
        if arg == "shared" or arg == "private" then
            NF.db.settings.sharedTooltip = (arg == "shared")
            Say("scanning with the %s tooltip", arg)
        else
            Say("scanning with the %s tooltip. /nf tooltip shared | private",
                NF.db.settings.sharedTooltip and "shared" or "private")
        end
    else
        Say("/nf (options) | on | off | status | unknown | test | probe [step] | tracking on|off | highlight | tooltip shared|private")
    end
end

NF.options = options
