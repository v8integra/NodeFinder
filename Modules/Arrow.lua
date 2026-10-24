local ADDON_NAME, NF = ...

-- An arrow to the nearest node you've ticked, using the nodes the scanner found
-- the last time it looked. Bearing math is the same as TrailBeacon's arrow,
-- which was confirmed in-game: world x is north and y is west, so
-- atan2(dy, dx) is measured counter-clockwise from north, like
-- GetPlayerFacing() and Texture:SetRotation().

local ARROW_TEXTURE = "Interface\\AddOns\\NodeFinder\\Media\\BasicArrow.tga"
local BEZEL_TEXTURE = "Interface\\AddOns\\NodeFinder\\Media\\Bezel.tga"
local BEZEL_SCALE = 1.4 -- bezel size as a multiple of the arrow size
local UPDATE_INTERVAL = 0.05

local arrow = CreateFrame("Button", "NodeFinderArrow", UIParent)
arrow:SetMovable(true)
arrow:EnableMouse(true)
arrow:SetClampedToScreen(true)
arrow:RegisterForDrag("LeftButton")
arrow:RegisterForClicks("RightButtonUp")
arrow:Hide()

local bezel = arrow:CreateTexture(nil, "BACKGROUND")
bezel:SetAllPoints()
bezel:SetTexture(BEZEL_TEXTURE)

local texture = arrow:CreateTexture(nil, "ARTWORK")
texture:SetPoint("CENTER")
texture:SetTexture(ARROW_TEXTURE)

local nameText = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
nameText:SetPoint("BOTTOM", arrow, "TOP", 0, 2)

local distanceText = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
distanceText:SetPoint("TOP", arrow, "BOTTOM", 0, -2)

arrow:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)

arrow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    local s = NF.db.settings.arrow
    s.point, s.x, s.y = point, x, y
end)

arrow:SetScript("OnClick", function()
    NF:ToggleOptions()
end)

arrow:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("NodeFinder", 1, 1, 1)
    GameTooltip:AddLine("Drag to move", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Right-click to choose nodes", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)

arrow:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local function ApplySize()
    local size = NF.db.settings.arrow.size
    texture:SetSize(size, size)
    arrow:SetSize(size * BEZEL_SCALE, size * BEZEL_SCALE)
end

local function ShowIdle(text)
    texture:Hide()
    nameText:SetText("")
    distanceText:SetText(text)
end

-- Why nothing is showing, when the answer is a missing tracking spell.
local function IdleReason()
    if NF:IsKindEnabled("ore") and not NF.oreTracking and not (NF:IsKindEnabled("herb") and NF.herbTracking) then
        return "Turn on Find Minerals"
    end
    if NF:IsKindEnabled("herb") and not NF.herbTracking and not (NF:IsKindEnabled("ore") and NF.oreTracking) then
        return "Turn on Find Herbs"
    end
    return "No nodes in range"
end

local function PlayerWorldPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then
        return nil
    end
    local mapPos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not mapPos then
        return nil
    end
    local continent, world = C_Map.GetWorldPosFromMapPos(mapID, mapPos)
    if not world then
        return nil
    end
    return continent, world.x, world.y
end

NF.PlayerWorldPosition = PlayerWorldPosition

-- The nearest enabled node, and its offset from the player.
function NF:GetNearestNode()
    local continent, px, py = PlayerWorldPosition()
    if not continent then
        return nil
    end

    local best, bestDx, bestDy, bestDistSq
    for _, node in ipairs(NF.nodes) do
        if node.continent == continent and NF:IsNodeEnabled(node.name) then
            local dx, dy = node.x - px, node.y - py
            local distSq = dx * dx + dy * dy
            if not bestDistSq or distSq < bestDistSq then
                best, bestDx, bestDy, bestDistSq = node, dx, dy, distSq
            end
        end
    end

    if not best then
        return nil
    end
    return best, bestDx, bestDy, math.sqrt(bestDistSq)
end

local function Update()
    local settings = NF.db.settings
    if not settings.enabled then
        arrow:Hide()
        return
    end
    arrow:Show()

    local continent = PlayerWorldPosition()
    if not continent then
        ShowIdle("No position here")
        return
    end

    local node, dx, dy, distance = NF:GetNearestNode()
    if not node then
        ShowIdle(IdleReason())
        return
    end

    texture:Show()
    texture:SetRotation(math.atan2(dy, dx) - (GetPlayerFacing() or 0))
    -- The marker is the minimap's own up/down arrow icon for a node above or
    -- below the player; font strings render it inline like the tooltip does.
    nameText:SetText((node.marker or "") .. node.name)
    distanceText:SetFormattedText("%.0f yd", distance)
end

local elapsedAcc = 0
local driver = CreateFrame("Frame")

NF:OnDBReady(function()
    local s = NF.db.settings.arrow
    arrow:ClearAllPoints()
    arrow:SetPoint(s.point, UIParent, s.point, s.x, s.y)
    ApplySize()
    NF:UpdateTrackingState()

    driver:SetScript("OnUpdate", function(_, elapsed)
        elapsedAcc = elapsedAcc + elapsed
        if elapsedAcc < UPDATE_INTERVAL then
            return
        end
        elapsedAcc = 0
        Update()
    end)
end)

function NF:SetEnabled(enabled)
    NF.db.settings.enabled = enabled and true or false
    Update()
    NF:ScheduleTrackingCheck()
end

NF.arrow = arrow
