local ADDON_NAME, NF = ...

-- Finds the herb/ore nodes the minimap is drawing right now.
--
-- Minimap:UpdateMouseoverAtPoint(x, y) moves the minimap's "mouseover" to a
-- point, and GameTooltip:SetMinimapMouseover() fills a tooltip with whatever is
-- under it (that is how Blizzard builds the minimap blip tooltip). Probing a
-- grid of points over the minimap and reading the tooltip each time tells us
-- which tracked nodes are within minimap range. Verified in-game with the
-- NodeProbe experiment: the point is in raw screen pixels (minimap frame units
-- times its effective scale), and the answer is ready the same frame.
--
-- Each probe that hits a node is converted to world coordinates right away
-- (using the player's position and facing from that same frame) so the arrow
-- stays correct while the player keeps moving between scans.

local PROBE_STEP = 5            -- minimap frame units between probes
local PROBES_PER_FRAME = 100    -- spread a scan over a few frames
local SCAN_INTERVAL = 1.0       -- seconds of rest between scans
-- Hits of the same name within this many probe steps of each other belong to
-- one node (a node answers to every probe that lands on its blip, so one node
-- is a small patch of hits; 1.5 steps links a probe to all eight neighbors).
local LINK_STEPS = 1.5
local MAX_LINES = 4
local MAX_STALLED_FRAMES = 30   -- give up on a scan if we can't get a position
local MAX_UNKNOWN_NAMES = 40

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- Splits a tooltip line into the plain text and the inline icon in front of it,
-- if any. The minimap puts a picture escape before the name of a node that is
-- above or below the player, e.g.
--   |TInterface\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|tCopper Vein
-- (found with /nf probe). The text is what we match against node names; the
-- icon is kept so the arrow can show Blizzard's own up/down marker.
local function ParseLine(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")

    local marker = text:match("^%s*(|T[^|]*|t)") or text:match("^%s*(|A[^|]*|a)")

    text = text:gsub("|T[^|]*|t", "")
    text = text:gsub("|A[^|]*|a", "")
    return strtrim(text), marker
end

-- A private hidden tooltip, so scanning never overwrites a tooltip the player
-- is looking at.
local scanTooltip = CreateFrame("GameTooltip", "NodeFinderScanTooltip", UIParent, "GameTooltipTemplate")
scanTooltip:SetAlpha(0)
scanTooltip:Hide()

local function GetTooltip()
    if NF.db and NF.db.settings.sharedTooltip then
        return GameTooltip
    end
    return scanTooltip
end

-- Returns a list of { text, marker } per tooltip line. raw = keep the text
-- exactly as the tooltip has it (color codes, inline icons), for diagnostics;
-- otherwise it's split into plain text and icon (see ParseLine).
local function ReadLines(tooltip, raw)
    local numLines = tooltip:NumLines()
    if not numLines or numLines == 0 then
        return nil
    end

    local prefix = tooltip:GetName() .. "TextLeft"
    local lines
    for i = 1, math.min(numLines, MAX_LINES) do
        local fontString = _G[prefix .. i]
        local text = fontString and fontString:GetText()
        if text and not IsSecret(text) then
            local marker
            if not raw then
                text, marker = ParseLine(text)
            end
            if text ~= "" then
                lines = lines or {}
                lines[#lines + 1] = { text = text, marker = marker }
            end
        end
    end
    return lines
end

local function Probe(tooltip, px, py, raw)
    Minimap:UpdateMouseoverAtPoint(px, py)
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:SetMinimapMouseover()
    return ReadLines(tooltip, raw)
end

-- Probe grid, cached per minimap size. Parallel arrays: one table per probe
-- would be a lot of garbage every second.
local grid

local function GetGrid()
    local width = Minimap:GetWidth()
    if grid and grid.width == width then
        return grid
    end

    local radius = (width / 2) * 0.95
    local n = math.floor(radius / PROBE_STEP)
    local xs, ys, count = {}, {}, 0
    for ix = -n, n do
        for iy = -n, n do
            local ox, oy = ix * PROBE_STEP, iy * PROBE_STEP
            if ox * ox + oy * oy <= radius * radius then
                count = count + 1
                xs[count], ys[count] = ox, oy
            end
        end
    end

    grid = { width = width, xs = xs, ys = ys, count = count }
    return grid
end

-- The player's position/facing and the minimap's scale for this frame.
local function GetFrameContext(rotate)
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
    local radiusYards = C_Minimap.GetViewRadius()
    if not radiusYards or IsSecret(radiusYards) then
        return nil
    end

    return {
        continent = continent,
        wx = world.x,
        wy = world.y,
        facing = GetPlayerFacing() or 0,
        rotate = rotate,
        yardsPerUnit = radiusYards / (Minimap:GetWidth() / 2),
    }
end

-- Minimap offset (frame units from the center, +x right, +y up) to world
-- coordinates. World x is north and world y is west (the convention
-- TrackingArrow-style bearing math relies on: bearing = atan2(dy, dx), measured
-- counter-clockwise from north like GetPlayerFacing()).
local function ToWorld(ctx, ox, oy)
    local right = ox * ctx.yardsPerUnit
    local up = oy * ctx.yardsPerUnit
    local north, west
    if ctx.rotate then
        -- Minimap up is the direction the player faces.
        local c, s = math.cos(ctx.facing), math.sin(ctx.facing)
        north = up * c + right * s
        west = up * s - right * c
    else
        north = up
        west = -right
    end
    return ctx.wx + north, ctx.wy + west
end

-- Nodes at different heights stay separate even when they share a name and
-- sit at the same spot on the minimap, so the marker is part of the key.
local function AddHit(hitsByName, name, marker, wx, wy)
    local nameKey = name:lower()
    local key = (marker or "") .. nameKey
    local entry = hitsByName[key]
    if not entry then
        entry = { name = name, marker = marker, kind = NF.NODE_KIND[nameKey] }
        hitsByName[key] = entry
    end
    entry[#entry + 1] = { x = wx, y = wy }
end

-- Merge hits that touch (single linkage) into one node at their centroid. Done
-- once the scan is complete rather than as hits arrive: merging on the fly
-- split one node into several when its hits arrived from the edge inward.
local function MergeHits(entry, linkYards)
    local count = #entry
    local parent = {}
    for i = 1, count do
        parent[i] = i
    end

    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end

    local linkSq = linkYards * linkYards
    for i = 1, count do
        for j = i + 1, count do
            local dx, dy = entry[i].x - entry[j].x, entry[i].y - entry[j].y
            if dx * dx + dy * dy <= linkSq then
                local a, b = find(i), find(j)
                if a ~= b then
                    parent[a] = b
                end
            end
        end
    end

    local groups = {}
    for i = 1, count do
        local root = find(i)
        local group = groups[root]
        local x, y = entry[i].x, entry[i].y
        if not group then
            group = { sumX = 0, sumY = 0, hits = 0, minX = x, maxX = x, minY = y, maxY = y }
            groups[root] = group
        end
        group.sumX = group.sumX + x
        group.sumY = group.sumY + y
        group.hits = group.hits + 1
        group.minX, group.maxX = math.min(group.minX, x), math.max(group.maxX, x)
        group.minY, group.maxY = math.min(group.minY, y), math.max(group.maxY, y)
    end

    return groups
end

NF.nodes = {}
NF.lastScan = nil
NF.lastUnknown = {}
NF.scanError = nil

local scan
local scanIdle = 0
local driver = CreateFrame("Frame")

local function SetSoftCursor(enabled)
    pcall(Minimap.SetUsingSoftCursor, Minimap, enabled)
end

local function EndScan()
    SetSoftCursor(InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() or false)
    GetTooltip():Hide()
    scan = nil
end

local function FinishScan()
    local s = scan
    local nodes = {}
    local linkYards = LINK_STEPS * PROBE_STEP * s.yardsPerUnit
    for _, entry in pairs(s.hitsByName) do
        for _, group in pairs(MergeHits(entry, linkYards)) do
            nodes[#nodes + 1] = {
                name = entry.name,
                marker = entry.marker,
                kind = entry.kind,
                x = group.sumX / group.hits,
                y = group.sumY / group.hits,
                hits = group.hits,
                continent = s.continent,
            }
        end
    end

    NF.nodes = nodes
    NF.lastUnknown = s.unknown
    NF.lastScan = {
        time = GetTime(),
        probes = s.count,
        nodes = #nodes,
        continent = s.continent,
        seconds = GetTime() - s.startTime,
    }
    NF.scanError = nil
    EndScan()
end

local function StepScan()
    local s = scan
    local ctx = GetFrameContext(s.rotate)
    if not ctx then
        s.stalled = s.stalled + 1
        if s.stalled >= MAX_STALLED_FRAMES then
            EndScan()
        end
        return
    end
    s.stalled = 0
    s.continent = ctx.continent
    s.yardsPerUnit = ctx.yardsPerUnit

    local cx, cy = Minimap:GetCenter()
    if not cx then
        EndScan()
        return
    end

    local factor = Minimap:GetEffectiveScale()
    local tooltip = GetTooltip()
    local last = math.min(s.index + PROBES_PER_FRAME - 1, s.count)

    for i = s.index, last do
        local ox, oy = s.xs[i], s.ys[i]
        local lines = Probe(tooltip, (cx + ox) * factor, (cy + oy) * factor)
        if lines then
            for _, line in ipairs(lines) do
                local text = line.text
                if NF.NODE_KIND[text:lower()] then
                    local wx, wy = ToWorld(ctx, ox, oy)
                    AddHit(s.hitsByName, text, line.marker, wx, wy)
                elseif s.unknownCount < MAX_UNKNOWN_NAMES and not s.unknown[text] then
                    s.unknown[text] = true
                    s.unknownCount = s.unknownCount + 1
                end
            end
        end
    end

    s.index = last + 1
    if s.index > s.count then
        FinishScan()
    end
end

local function StartScan()
    local g = GetGrid()
    scan = {
        xs = g.xs,
        ys = g.ys,
        count = g.count,
        index = 1,
        stalled = 0,
        hitsByName = {},
        yardsPerUnit = 1,
        unknown = {},
        unknownCount = 0,
        rotate = GetCVar("rotateMinimap") == "1",
        startTime = GetTime(),
    }
    SetSoftCursor(true)
end

local function ShouldScan()
    if not NF.db.settings.enabled or not NF:AnyNodeEnabled() then
        return false
    end
    if not Minimap or not Minimap:IsVisible() or type(Minimap.UpdateMouseoverAtPoint) ~= "function" then
        return false
    end
    -- Probing moves the minimap's mouseover; don't fight a real hover.
    if Minimap:IsMouseOver() then
        return false
    end
    if UnitOnTaxi("player") then
        return false
    end
    return true
end

driver:SetScript("OnUpdate", function(_, elapsed)
    if not NF.db then
        return
    end

    if scan then
        local ok, err = pcall(StepScan)
        if not ok then
            NF.scanError = tostring(err)
            EndScan()
        end
        return
    end

    scanIdle = scanIdle + elapsed
    if scanIdle < SCAN_INTERVAL then
        return
    end
    scanIdle = 0

    if ShouldScan() then
        StartScan()
    end
end)

-- Which tracking spells are on, so the arrow can say why nothing shows up.
function NF:UpdateTrackingState()
    local ore, herb = false, false
    local count = C_Minimap.GetNumTrackingTypes and C_Minimap.GetNumTrackingTypes() or 0
    for i = 1, count do
        local info = C_Minimap.GetTrackingInfo(i)
        if info and info.active then
            if info.spellID == NF.TRACKING_SPELL_ORE then
                ore = true
            elseif info.spellID == NF.TRACKING_SPELL_HERB then
                herb = true
            end
        end
    end
    NF.oreTracking, NF.herbTracking = ore, herb
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("MINIMAP_UPDATE_TRACKING")
events:RegisterEvent("SPELLS_CHANGED")
events:SetScript("OnEvent", function()
    NF:UpdateTrackingState()
end)

-- /nodefinder test: one synchronous pass with each tooltip, to check the
-- private scanning tooltip returns the same results as the shared one.
function NF:RunTest()
    if not Minimap or type(Minimap.UpdateMouseoverAtPoint) ~= "function" then
        return nil, "Minimap:UpdateMouseoverAtPoint is not available."
    end
    local cx, cy = Minimap:GetCenter()
    if not cx then
        return nil, "The minimap has no position yet."
    end

    local g = GetGrid()
    local factor = Minimap:GetEffectiveScale()
    local results = {}

    SetSoftCursor(true)
    for _, entry in ipairs({ { "private", scanTooltip }, { "shared", GameTooltip } }) do
        local anyText, knownNodes = 0, 0
        for i = 1, g.count do
            local lines = Probe(entry[2], (cx + g.xs[i]) * factor, (cy + g.ys[i]) * factor)
            if lines then
                anyText = anyText + 1
                for _, line in ipairs(lines) do
                    if NF.NODE_KIND[line.text:lower()] then
                        knownNodes = knownNodes + 1
                    end
                end
            end
        end
        results[#results + 1] = { name = entry[1], anyText = anyText, knownNodes = knownNodes }
    end
    EndScan()

    return results
end

-- /nodefinder probe [step]: one synchronous, finer pass that reports every
-- distinct tooltip text on the minimap (nodes or not), how many probes hit it
-- and how big the patch of hits is. For working out why a blip isn't being
-- picked up: a name that's decorated differently, or a hit area smaller than
-- the scan's grid.
function NF:ProbeAll(step)
    if not Minimap or type(Minimap.UpdateMouseoverAtPoint) ~= "function" then
        return nil, "Minimap:UpdateMouseoverAtPoint is not available."
    end
    local cx, cy = Minimap:GetCenter()
    if not cx then
        return nil, "The minimap has no position yet."
    end

    step = math.max(1.5, step or 2)
    local radius = (Minimap:GetWidth() / 2) * 0.95
    local n = math.floor(radius / step)
    local factor = Minimap:GetEffectiveScale()
    local tooltip = GetTooltip()
    local hitsByText = {}
    local probes = 0

    SetSoftCursor(true)
    for ix = -n, n do
        for iy = -n, n do
            local ox, oy = ix * step, iy * step
            if ox * ox + oy * oy <= radius * radius then
                probes = probes + 1
                local lines = Probe(tooltip, (cx + ox) * factor, (cy + oy) * factor, true)
                if lines then
                    local parts, known = {}, false
                    for _, line in ipairs(lines) do
                        parts[#parts + 1] = line.text
                        if NF.NODE_KIND[(ParseLine(line.text)):lower()] then
                            known = true
                        end
                    end
                    local text = table.concat(parts, " / ")
                    local entry = hitsByText[text]
                    if not entry then
                        entry = { known = known }
                        hitsByText[text] = entry
                    end
                    entry[#entry + 1] = { x = ox, y = oy }
                end
            end
        end
    end
    EndScan()

    local clusters = {}
    for text, entry in pairs(hitsByText) do
        for _, group in pairs(MergeHits(entry, step * LINK_STEPS)) do
            clusters[#clusters + 1] = {
                text = text,
                known = entry.known,
                hits = group.hits,
                x = group.sumX / group.hits,
                y = group.sumY / group.hits,
                width = group.maxX - group.minX + step,
                height = group.maxY - group.minY + step,
            }
        end
    end
    table.sort(clusters, function(a, b)
        return a.x * a.x + a.y * a.y < b.x * b.x + b.y * b.y
    end)

    local radiusYards = C_Minimap.GetViewRadius()
    local yardsPerUnit = (radiusYards and not IsSecret(radiusYards)) and radiusYards / (Minimap:GetWidth() / 2) or nil
    return clusters, probes, step, yardsPerUnit
end
