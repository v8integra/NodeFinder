local ADDON_NAME, NF = ...

local ROW_HEIGHT = 22
local HEADER_HEIGHT = 24
local CONTENT_WIDTH = 300

local options = CreateFrame("Frame", "NodeFinderOptions", UIParent, "BasicFrameTemplateWithInset")
options:SetSize(360, 480)
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

local checks = {}

local function RefreshChecks()
    enabledCheck:SetChecked(NF.db.settings.enabled)
    trackingCheck:SetChecked(NF.db.settings.manageTracking)
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
oreAll:SetPoint("TOPLEFT", trackingCheck, "BOTTOMLEFT", 0, -4)

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
    elseif command == "tooltip" then
        if arg == "shared" or arg == "private" then
            NF.db.settings.sharedTooltip = (arg == "shared")
            Say("scanning with the %s tooltip", arg)
        else
            Say("scanning with the %s tooltip. /nf tooltip shared | private",
                NF.db.settings.sharedTooltip and "shared" or "private")
        end
    else
        Say("/nf (options) | on | off | status | unknown | test | probe [step] | tracking on|off | tooltip shared|private")
    end
end

NF.options = options
