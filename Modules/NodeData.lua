local ADDON_NAME, NF = ...

-- Node names as the minimap tooltip shows them (enUS). The list comes from
-- GatherLite's WoW Forever data (MIT licensed, github.com/Wuild/GatherLite).
-- Other locales won't match until their names are added here.
NF.ORES = {
    "Copper Vein",
    "Weak Copper Vein",
    "Poor Copper Vein",
    "Tin Vein",
    "Silver Vein",
    "Iron Deposit",
    "Gold Vein",
    "Mithril Deposit",
    "Truesilver Deposit",
    "Dark Iron Deposit",
    "Small Thorium Vein",
    "Rich Thorium Vein",
    "Cold Iron Deposit",
    "Fool's Gold Vein",
    "Starsilver Vein",
    "Greater Moonstone Formation",
    "Incendicite Mineral Vein",
    "Lesser Bloodstone Deposit",
    "Indurium Mineral Vein",
    "Hakkari Thorium Vein",
    "Small Obsidian Chunk",
    "Large Obsidian Chunk",
}

NF.HERBS = {
    "Silverleaf",
    "Peacebloom",
    "Wilted Peacebloom",
    "Earthroot",
    "Mageroyal",
    "Briarthorn",
    "Stranglekelp",
    "Bruiseweed",
    "Wild Steelbloom",
    "Grave Moss",
    "Kingsblood",
    "Liferoot",
    "Fadeleaf",
    "Goldthorn",
    "Khadgar's Whisker",
    "Wintersbite",
    "Firebloom",
    "Purple Lotus",
    "Arthas' Tears",
    "Sungrass",
    "Blindweed",
    "Ghost Mushroom",
    "Gromsblood",
    "Golden Sansam",
    "Dreamfoil",
    "Mountain Silversage",
    "Plaguebloom",
    "Icecap",
    "Black Lotus",
    "Nightmare Moss",
    "Dreamroot",
    "Moonroot",
    "Star Lotus",
}

-- Minimap tracking spells: Find Minerals / Find Herbs.
NF.TRACKING_SPELL_ORE = 2580
NF.TRACKING_SPELL_HERB = 2383

NF.NODE_KIND = {}

local function Register(list, kind)
    for _, name in ipairs(list) do
        NF.NODE_KIND[name:lower()] = kind
    end
end

Register(NF.ORES, "ore")
Register(NF.HERBS, "herb")

function NF:IsNodeEnabled(name)
    return NF.db.settings.nodes[name:lower()] ~= false
end

function NF:SetNodeEnabled(name, enabled)
    NF.db.settings.nodes[name:lower()] = enabled and true or false
    if NF.ScheduleTrackingCheck then
        NF:ScheduleTrackingCheck()
    end
end

function NF:SetAllEnabled(list, enabled)
    for _, name in ipairs(list) do
        NF:SetNodeEnabled(name, enabled)
    end
end

function NF:AnyNodeEnabled()
    for name in pairs(NF.NODE_KIND) do
        if NF.db.settings.nodes[name] ~= false then
            return true
        end
    end
    return false
end

-- Whether any enabled node of this kind ("ore" or "herb") is selected.
function NF:IsKindEnabled(kind)
    for name, nodeKind in pairs(NF.NODE_KIND) do
        if nodeKind == kind and NF.db.settings.nodes[name] ~= false then
            return true
        end
    end
    return false
end
