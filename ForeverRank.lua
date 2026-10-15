local addonName = ...

-- Only spellbook scans populate these learned-rank caches. Tooltip evaluation is pure.
local rankCache, spellIDMap = {}, {}
local cacheDirty, scanPending = true, false
local badgePending = false
local requestedSpellData, familyNames = {}, {}
local snapshotCrit = 0

local ACTION_BUTTON_PREFIXES = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}

-- Resolve family names from client IDs so eligibility also covers other ranks.
-- Forever uses the SoD IDs for Wild Growth, Riptide and Penance.
local PERIODIC_CRIT_FAMILIES = {
    139, 774, 740, 408120, 408521, 2944, 1949, 689, 1120, 5143,
}
local CHANNEL_FAMILIES = {
    5143, 689, 1120, 15407, 740, 402174, 10797, 5740, 16914, 1949,
}

local function IsReadable(value)
    return not (issecretvalue and issecretvalue(value))
end

local function InitDB()
    if type(ForeverRankDB) ~= "table" then ForeverRankDB = {} end
    if type(ForeverRankDB.showBadges) ~= "boolean" then ForeverRankDB.showBadges = true end
    if type(ForeverRankDB.includeCrit) ~= "boolean" then ForeverRankDB.includeCrit = true end
end

local function GetCritChance()
    -- Forever 70374 has a unified, argument-free spell-crit API.
    local chance = GetSpellCritChance and GetSpellCritChance()
    if not IsReadable(chance) or type(chance) ~= "number" then return 0 end
    return math.max(0, math.min(1, chance / 100))
end

local function GetManaCost(spellID)
    local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(spellID)
        or (GetSpellPowerCost and GetSpellPowerCost(spellID))
    if not costs then return nil end
    for _, info in ipairs(costs) do
        if IsReadable(info.type) and info.type == 0 and IsReadable(info.requiredAuraID)
                and (not info.requiredAuraID or info.requiredAuraID == 0
                    or (IsReadable(info.hasRequiredAura) and info.hasRequiredAura == true)) then
            -- An upfront cost alone does not describe a spell with ongoing mana consumption.
            if not IsReadable(info.costPerSec) or (info.costPerSec and info.costPerSec > 0) then return nil end
            if IsReadable(info.cost) and type(info.cost) == "number" and info.cost > 0 then return info.cost end
        end
    end
end

local function GetSpellMeta(spellID)
    local name, castSec, rankText = nil, 1.5, ""
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            name = info.name
            if IsReadable(info.castTime) and type(info.castTime) == "number" and info.castTime > 0 then
                castSec = info.castTime / 1000
            end
        end
    elseif GetSpellInfo then
        local sName, sRank, _, castMS = GetSpellInfo(spellID)
        name, rankText = sName, sRank or ""
        if castMS and castMS > 0 then castSec = castMS / 1000 end
    end
    if not IsReadable(name) or type(name) ~= "string" then return nil end
    if rankText == "" then
        rankText = (C_Spell and C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID))
            or (GetSpellSubtext and GetSpellSubtext(spellID)) or ""
    end
    if not IsReadable(rankText) or type(rankText) ~= "string" then rankText = "" end
    return name, castSec, rankText, tonumber(rankText:match("(%d+)"))
end

local function MatchesFamily(spellID, spellName, families)
    for _, id in ipairs(families) do
        if id == spellID then return true end
        if not familyNames[id] then
            local name = GetSpellMeta(id)
            if name then familyNames[id] = name end
        end
        if familyNames[id] == spellName then return true end
    end
    return false
end

local NUMBER = "(%d+%.?%d*)"
local function ParseAmount(text)
    -- Percent-of-weapon/power values are not flat output. Keep slow percentages
    -- from interfering with otherwise readable damage amounts.
    text = text:gsub("%d+%.?%d*%%", "PERCENT")
    local first, last = text:match(NUMBER .. " to " .. NUMBER)
    if first then return (tonumber(first) + tonumber(last)) / 2 end
    -- Remove timing clauses before looking for a flat amount introduced by 'for'.
    local amountText = text:gsub("for %d+%.?%d* sec", ""):gsub("for %d+%.?%d* min", "")
    local amount = amountText:match("for " .. NUMBER)
        or amountText:match("causing " .. NUMBER)
        or amountText:match("causes? " .. NUMBER)
        or amountText:match("dealing " .. NUMBER)
        or amountText:match("deals? " .. NUMBER)
        or amountText:match("restores? " .. NUMBER)
        or amountText:match("regenerates? " .. NUMBER)
        or amountText:match("^%s*" .. NUMBER)
        or amountText:match(NUMBER .. "%s+[%a%s]-damage")
        or amountText:match(NUMBER .. "%s+health")
    return amount and tonumber(amount) or nil
end

local function ParsePeriodic(text)
    local start, finish, duration = text:find("over " .. NUMBER .. " sec")
    if start then
        local total = ParseAmount(text:sub(1, start - 1))
        if total then return total, tonumber(duration), false end
    end
    local interval
    start, finish, interval, duration = text:find("every " .. NUMBER .. " sec[^%.]-for " .. NUMBER .. " sec")
    if not start then
        start, finish, duration = text:find("each second for " .. NUMBER .. " sec")
        interval = "1"
    end
    if start then
        local tick = ParseAmount(text:sub(1, start - 1))
        interval, duration = tonumber(interval), tonumber(duration)
        if tick and interval and interval > 0 and duration and duration > 0 then
            return tick * math.floor(duration / interval + 0.00001), duration, true
        end
    end
end

local function ParseSpellValues(text)
    if not IsReadable(text) or type(text) ~= "string" or text == "" then return nil end
    local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    repeat
        local changed
        clean, changed = clean:gsub("(%d),(%d)", "%1%2")
        if changed == 0 then break end
    until false
    local lower = clean:lower()
    local healAt = lower:find("heal") or lower:find("restor") or lower:find("regenerat")
    local damageAt = lower:find("damage")
    if not healAt and not damageAt then return nil end
    if lower:find("mana") and not lower:find("health") and not damageAt then return nil end
    if lower:find("restores? %d+%.?%d* mana") then return nil end
    -- Multi-mode Penance and self/enemy Hellfire need dedicated effect handling.
    if lower:find("instantly") and lower:find("every") then return nil end
    if lower:find("damage to himself", 1, true) or lower:find("damage to herself", 1, true)
            or lower:find("damage to the caster", 1, true) then return nil end

    local kind = (damageAt and (not healAt or damageAt < healAt)) and "DAMAGE" or "HEAL"
    local isAoE = lower:find("party members") or lower:find("nearby") or lower:find("all enemies")
        or lower:find("enemies within") or lower:find("targets within") or lower:find("cone in front")
        or lower:find("jumps to") or lower:find("up to %d+ targets")
    local function result(mode, direct, periodic, duration)
        return {kind=kind, mode=mode, directAvg=direct or 0, dotAvg=periodic or 0,
            duration=duration or 0, isChanneled=lower:find("channel") ~= nil,
            isAoE=isAoE ~= nil, aoeTargets=1, lowerText=lower}
    end

    local absorbText = lower:gsub("%d+%.?%d*%%", "PERCENT")
    local absorb = absorbText:match("absorbs? " .. NUMBER .. ".-damage")
        or absorbText:match("absorbing " .. NUMBER .. ".-damage")
        or absorbText:match("absorbs? up to " .. NUMBER .. ".-damage")
    if absorb then
        -- Mana Shield consumes mana per point absorbed in addition to its cast
        -- cost. That total is not available from a flat power-cost entry.
        if lower:find("mana") then return nil end
        local parsed = result("ABSORB", tonumber(absorb))
        parsed.kind = "HEAL"
        return parsed
    end

    -- Split the direct clause before interpreting the periodic amount, including
    -- Fireball's 'and an additional' and Riptide's ', an additional'.
    for _, separator in ipairs({"and another ", "and an additional ", "and additional ",
            ", an additional ", "and "}) do
        local start, finish = lower:find(separator, 1, true)
        if start then
            local direct = ParseAmount(lower:sub(1, start - 1))
            local periodic, duration = ParsePeriodic(lower:sub(finish + 1))
            if direct and periodic then return result("HYBRID", direct, periodic, duration) end
        end
    end

    local periodic, duration = ParsePeriodic(lower)
    if periodic then return result("PERIODIC", 0, periodic, duration) end
    -- A tick value with an unrecognized schedule must not become a full cast.
    if lower:find("every %d") or lower:find("each second") or lower:find("over %d") then return nil end
    local direct = ParseAmount(lower)
    if direct then return result("DIRECT", direct) end
end

local function EvaluateSpell(spellID, descText, critChance)
    if not IsReadable(spellID) then return nil end
    local manaCost = GetManaCost(spellID)
    if not manaCost then return nil end
    local spellName, castTime, rankText, rankNum = GetSpellMeta(spellID)
    if not spellName then return nil end
    local parsed = ParseSpellValues(descText)
    if not parsed then return nil end
    if MatchesFamily(spellID, spellName, CHANNEL_FAMILIES) then parsed.isChanneled = true end

    -- Live Forever descriptions already include gear, talents and rank scaling.
    local liveTotal = parsed.directAvg + parsed.dotAvg
    local critMult = 1
    if parsed.mode ~= "ABSORB" and ForeverRankDB and ForeverRankDB.includeCrit then
        critMult = 1 + (critChance or GetCritChance()) * 0.5
    end
    local periodicMult = MatchesFamily(spellID, spellName, PERIODIC_CRIT_FAMILIES) and critMult or 1
    local effectiveSingle = parsed.directAvg * critMult + parsed.dotAvg * periodicMult
    local execTime = parsed.isChanneled and math.max(1.5, parsed.duration) or math.max(1.5, castTime)
    local perCastSec = effectiveSingle / execTime
    return {spellName=spellName, rankText=rankText, rankNum=rankNum, kind=parsed.kind, mode=parsed.mode,
        manaCost=manaCost, baseTotal=liveTotal, effectiveSingle=effectiveSingle,
        basePerMana=liveTotal/manaCost, effPerMana=effectiveSingle/manaCost,
        perCastSec=perCastSec,
        perTickSec=parsed.duration > 0 and effectiveSingle/parsed.duration or perCastSec,
        isAoE=parsed.isAoE, aoeTargets=1}
end

local function GetSpellRankLeaders(spellName)
    local ranks = rankCache[spellName]
    if not ranks then return nil, 0, nil, 0, 0 end
    local bestRank, bestEff, bestRankNum, maxRank, maxRankNum, count = nil, 0, 0, nil, 0, 0
    for name, data in pairs(ranks) do
        count = count + 1
        if data.eff > bestEff or (data.eff == bestEff and data.rankNum > bestRankNum) then
            bestRank, bestEff, bestRankNum = name, data.eff, data.rankNum
        end
        if data.rankNum > maxRankNum then maxRank, maxRankNum = name, data.rankNum end
    end
    return bestRank, bestEff, maxRank, maxRankNum, count
end

local function UpdateActionBarBadges()
    if InCombatLockdown() then return end
    local showBadges = ForeverRankDB and ForeverRankDB.showBadges and not cacheDirty
    for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
        for i = 1, 12 do
            local button = _G[prefix .. i]
            if button then
                if not button.foreverRankBadge then
                    local badge = button:CreateFontString(nil, "OVERLAY")
                    badge:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
                    badge:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
                    badge:SetJustifyH("LEFT")
                    button.foreverRankBadge = badge
                end
                local badge, shown = button.foreverRankBadge, false
                if showBadges and button.action and HasAction(button.action) then
                    local actionType, id = GetActionInfo(button.action)
                    if IsReadable(actionType) and IsReadable(id) and actionType == "spell" and spellIDMap[id] then
                        local meta = spellIDMap[id]
                        local best, _, highest, _, count = GetSpellRankLeaders(meta.spellName)
                        if count > 1 and meta.rankNum > 0 then
                            local color = meta.rankText == best and "00ff00"
                                or (meta.rankText == highest and "ffd100" or "aaaaaa")
                            badge:SetText(string.format("|cff%sR%d|r", color, meta.rankNum))
                            badge:Show()
                            shown = true
                        end
                    end
                end
                if not shown then badge:Hide() end
            end
        end
    end
end

local function QueueBadgeUpdate()
    if InCombatLockdown() or badgePending then return end
    badgePending = true
    local function refresh()
        badgePending = false
        UpdateActionBarBadges()
    end
    -- Native secure page reassignment may finish after the event handler runs.
    if C_Timer and C_Timer.After then C_Timer.After(0, refresh) else refresh() end
end

local function GetDescriptionFromLines(lines)
    for _, line in ipairs(lines or {}) do
        if ParseSpellValues(line.leftText) then return line.leftText end
    end
end

local function GetHeadlessSpellDescription(spellID)
    if C_Spell and C_Spell.GetSpellDescription then
        local description = C_Spell.GetSpellDescription(spellID)
        if IsReadable(description) and type(description) == "string" and description ~= "" then return description end
    end
    if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
        local data = C_TooltipInfo.GetSpellByID(spellID)
        if data then return GetDescriptionFromLines(data.lines) end
    end
end

local function CacheLearnedSpell(spellID)
    if not IsReadable(spellID) or type(spellID) ~= "number" then return end
    local name = GetSpellMeta(spellID)
    local description = GetHeadlessSpellDescription(spellID)
    local result = description and EvaluateSpell(spellID, description, snapshotCrit)
    if result and result.rankText ~= "" and result.rankNum then
        rankCache[result.spellName] = rankCache[result.spellName] or {}
        rankCache[result.spellName][result.rankText] = {
            eff=result.effPerMana, avg=result.effectiveSingle, cost=result.manaCost,
            id=spellID, rankNum=result.rankNum, kind=result.kind,
        }
        spellIDMap[spellID] = {spellName=result.spellName, rankText=result.rankText, rankNum=result.rankNum}
    elseif (not description or description == "" or not name)
            and C_Spell and C_Spell.RequestLoadSpellData and not requestedSpellData[spellID] then
        requestedSpellData[spellID] = "pending"
        C_Spell.RequestLoadSpellData(spellID)
    end
end

local function ScanSpellbook()
    if InCombatLockdown() then
        cacheDirty = true
        return
    end
    InitDB()
    table.wipe(rankCache)
    table.wipe(spellIDMap)
    snapshotCrit = GetCritChance()
    cacheDirty = false
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        for i = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local skill = C_SpellBook.GetSpellBookSkillLineInfo(i)
            if skill and skill.itemIndexOffset and skill.numSpellBookItems then
                for slot = skill.itemIndexOffset + 1, skill.itemIndexOffset + skill.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player)
                    if item and item.itemType == Enum.SpellBookItemType.Spell
                            and not item.isPassive and not item.isOffSpec then
                        CacheLearnedSpell(item.spellID)
                    end
                end
            end
        end
    elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, slots = GetSpellTabInfo(tab)
            for slot = offset + 1, offset + slots do
                local kind, id = GetSpellBookItemInfo(slot, "spell")
                if kind == "SPELL" then CacheLearnedSpell(id) end
            end
        end
    end
    UpdateActionBarBadges()
end

local function QueueSpellbookScan()
    local wasDirty = cacheDirty
    cacheDirty = true
    if InCombatLockdown() then return end
    if not wasDirty then UpdateActionBarBadges() end
    if scanPending then return end
    scanPending = true
    local function refresh()
        scanPending = false
        if cacheDirty then ScanSpellbook() end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.5, refresh) else refresh() end
end

local function OnSpellTooltip(tooltip, data)
    if InCombatLockdown() or not data or not IsReadable(data.id) or not data.id then return end
    if cacheDirty then ScanSpellbook() end
    local description = GetHeadlessSpellDescription(data.id) or GetDescriptionFromLines(data.lines)
    local result = EvaluateSpell(data.id, description, snapshotCrit)
    if not result then return end
    local metric = result.kind == "HEAL" and "HPM" or "DPM"
    local throughput = result.kind == "HEAL" and "HPCT" or "DPCT"
    local tag = result.mode == "HYBRID" and " |cff88ccff[Direct+Periodic]|r"
        or (result.mode == "ABSORB" and " |cff88ccff[Shield]|r" or "")
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(string.format("|cff00ccffForeverRank|r (%s)%s:", metric, tag),
        string.format("|cffffffff%.2f|r |cffaaaaaa(Tooltip: %.2f)|r", result.effPerMana, result.basePerMana))
    if result.mode == "PERIODIC" or result.mode == "HYBRID" then
        tooltip:AddDoubleLine("Est. Output & " .. throughput .. ":",
            string.format("|cff00ff00%.0f|r |cffaaaaaa(%.1f/cast sec; %.1f/duration sec)|r",
                result.effectiveSingle, result.perCastSec, result.perTickSec))
    else
        tooltip:AddDoubleLine("Est. Output & " .. throughput .. ":",
            string.format("|cff00ff00%.0f|r |cffaaaaaa(%.1f/cast sec)|r", result.effectiveSingle, result.perCastSec))
    end
    if result.isAoE then tooltip:AddLine("|cffaaaaaaOutput shown per target.|r") end
    local known = spellIDMap[data.id]
    local best, bestEff, _, _, count = GetSpellRankLeaders(result.spellName)
    if known and best and count > 1 then
        if best == result.rankText then
            tooltip:AddDoubleLine("Downrank Status:", "|cff00ff00Peak Mana Efficiency|r")
        else
            tooltip:AddDoubleLine("Best Rank Known:", string.format("|cffffd100%s|r (%.2f %s)", best, bestEff, metric))
        end
    end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpellTooltip)
end

local eventFrame = CreateFrame("Frame")
for _, event in ipairs({"ADDON_LOADED", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED",
        "PLAYER_EQUIPMENT_CHANGED", "SPELL_TEXT_UPDATE", "SPELL_DATA_LOAD_RESULT",
        "TRAIT_CONFIG_UPDATED", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
        "UPDATE_BONUS_ACTIONBAR", "UPDATE_SHAPESHIFT_FORM", "PLAYER_REGEN_ENABLED"}) do
    eventFrame:RegisterEvent(event)
end
eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
eventFrame:RegisterUnitEvent("UNIT_STATS", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELL_HASTE", "player")
eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then InitDB() end
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR" then
        QueueBadgeUpdate()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat auras, crit and temporary mana costs may have changed without a
        -- readable intermediate snapshot. Always rebuild after combat.
        QueueSpellbookScan()
    elseif event == "UNIT_AURA" or event == "UNIT_STATS" or event == "UNIT_SPELL_HASTE" then
        if arg1 == "player" then QueueSpellbookScan() end
    elseif event == "SPELL_DATA_LOAD_RESULT" then
        if requestedSpellData[arg1] == "pending" then
            -- Request each spell once per session: a successful load may still
            -- have no description. SPELL_TEXT_UPDATE will refresh it later.
            requestedSpellData[arg1] = "complete"
            if arg2 then QueueSpellbookScan() end
        end
    else
        QueueSpellbookScan()
    end
end)

SLASH_FOREVERRANK1, SLASH_FOREVERRANK2 = "/frank", "/foreverrank"
SlashCmdList["FOREVERRANK"] = function(msg)
    InitDB()
    local cmd = (msg or ""):lower():match("^%s*(%S+)") or ""
    if cmd == "badges" or cmd == "bars" then
        ForeverRankDB.showBadges = not ForeverRankDB.showBadges
        QueueBadgeUpdate()
        print("|cff00ccff[ForeverRank]|r Action Bar Rank Badges: " .. (ForeverRankDB.showBadges and "ON" or "OFF"))
        return
    elseif cmd == "crit" then
        ForeverRankDB.includeCrit = not ForeverRankDB.includeCrit
        QueueSpellbookScan()
        print("|cff00ccff[ForeverRank]|r Estimated Crit Scaling: " .. (ForeverRankDB.includeCrit and "ON" or "OFF"))
        return
    end
    if InCombatLockdown() then
        QueueSpellbookScan()
        print("|cff00ccff[ForeverRank]|r Rank comparisons refresh after combat. Run /frank out of combat for the current summary.")
        return
    end
    ScanSpellbook()
    print("|cff00ccff[ForeverRank]|r Peak Mana Efficiency Summary (/frank badges, /frank crit):")
    local names = {}
    for name in pairs(rankCache) do names[#names + 1] = name end
    table.sort(names)
    local count = 0
    for _, name in ipairs(names) do
        local best, eff, highest, _, ranks = GetSpellRankLeaders(name)
        if best and ranks > 1 then
            count = count + 1
            local data = rankCache[name][best]
            print(string.format("  |cffffffff%s|r: |cff00ff00%s|r (%.2f %s, %.0f avg, %d mana) | Highest: |cffffd100%s|r",
                name, best, eff, data.kind == "HEAL" and "HPM" or "DPM", data.avg, data.cost, highest or best))
        end
    end
    if count == 0 then print("  No supported multi-rank healing or damage spells detected yet.") end
end
