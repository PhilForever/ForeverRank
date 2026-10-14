local addonName, addon = ...

-- Session cache: rankCache[spellName][rankText] = { eff, avg, cost, id, rankNum, isAoE, aoeTargets, kind }
local rankCache = {}
-- Fast lookup by spellID for Action Bar badges: spellIDMap[spellID] = { spellName, rankText, rankNum }
local spellIDMap = {}

local scanPending = false
local scanQueuedAfterCombat = false

local SCHOOL_IDS = {
    physical = 1,
    holy     = 2,
    fire     = 3,
    nature   = 4,
    frost    = 5,
    shadow   = 6,
    arcane   = 7,
}

local ACTION_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
}

local function InitDB()
    if type(ForeverRankDB) ~= "table" then
        ForeverRankDB = {}
    end
    if ForeverRankDB.showBadges == nil then
        ForeverRankDB.showBadges = true
    end
    if ForeverRankDB.includeCrit == nil then
        ForeverRankDB.includeCrit = true
    end
end

local function GetDownrankPenalty(spellLevel)
    if not spellLevel or spellLevel >= 20 or spellLevel <= 0 then
        return 1.0
    end
    return math.max(0, 1 - ((20 - spellLevel) * 0.0375))
end

local function GetManaCost(spellID)
    local costTable = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(spellID)
        or (GetSpellPowerCost and GetSpellPowerCost(spellID))
    if not costTable then return nil end

    for _, costInfo in ipairs(costTable) do
        if costInfo.type == 0 or costInfo.name == "MANA" then
            if costInfo.cost and costInfo.cost > 0 then
                return costInfo.cost
            end
        end
    end
    return nil
end

local function GetSpellMeta(spellID)
    local name, castSec, rankText = nil, 1.5, ""

    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            name = info.name
            castSec = (info.castTime and info.castTime > 0) and (info.castTime / 1000) or 1.5
        end
    elseif GetSpellInfo then
        local sName, sRank, _, castTime = GetSpellInfo(spellID)
        name = sName
        rankText = sRank or ""
        castSec = (castTime and castTime > 0) and (castTime / 1000) or 1.5
    end

    if rankText == "" then
        rankText = (C_Spell and C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID))
            or (GetSpellSubtext and GetSpellSubtext(spellID))
            or ""
    end

    local rankNum = tonumber(rankText:match("(%d+)"))
    return name, castSec, rankText, rankNum
end

local function GetSpellSchoolStats(lowerText)
    local bestDamage = 0
    local matchedSchool = 2 -- Default Holy

    for schoolName, schoolID in pairs(SCHOOL_IDS) do
        if schoolID > 1 and lowerText:find(schoolName) then
            matchedSchool = schoolID
            if GetSpellBonusDamage then
                bestDamage = GetSpellBonusDamage(schoolID) or 0
            end
            break
        end
    end

    if bestDamage == 0 and GetSpellBonusDamage then
        for i = 2, 7 do
            local val = GetSpellBonusDamage(i) or 0
            if val > bestDamage then
                bestDamage = val
                matchedSchool = i
            end
        end
    end

    local critChance = 0
    if GetSpellCritChance then
        critChance = (GetSpellCritChance(matchedSchool) or 0) / 100
    end

    return bestDamage, math.max(0, critChance)
end

local function ParseSpellValues(text)
    if not text or text == "" then return nil end

    -- Strip thousands separators and scrub duration phrases ("for 15 sec") so they never match flat value regexes
    local clean = text:gsub("(%d),(%d)", "%1%2")
    local lower = clean:lower()
    local scrubbed = lower:gsub("for %d+ sec", ""):gsub("for %d+ min", "")

    -- 0. Check for Absorb Shields first (e.g. Power Word: Shield, Ice Barrier)
    local absorbVal = scrubbed:match("absorbs? (%d+)[^%.]-damage") or scrubbed:match("absorbing (%d+)[^%.]-damage")
    if absorbVal then
        return {
            kind = "HEAL",
            mode = "ABSORB",
            directAvg = tonumber(absorbVal),
            dotAvg = 0,
            duration = 0,
            isChanneled = false,
            isAoE = false,
            aoeTargets = 1,
            lowerText = lower,
        }
    end

    local isHeal = scrubbed:find("heal") or scrubbed:find("restor")
    local isDamage = scrubbed:find("damage") or scrubbed:find("causes") or scrubbed:find("burns") or scrubbed:find("smites") or scrubbed:find("blasts") or scrubbed:find("afflicts")
    if not isHeal and not isDamage then return nil end

    if isHeal and not scrubbed:find("health") and not scrubbed:find("friendly") and not scrubbed:find("target") and not scrubbed:find("party") and scrubbed:find("mana") then
        return nil
    end

    local kind = isHeal and "HEAL" or "DAMAGE"
    local isChanneled = scrubbed:find("channel") ~= nil

    local isAoE = false
    local aoeTargets = 1
    local explicitTargets = scrubbed:match("up to (%d+) targets") or scrubbed:match("jumps to (%d+)")
    if explicitTargets then
        isAoE = true
        aoeTargets = tonumber(explicitTargets) or 5
    elseif scrubbed:find("party members") or scrubbed:find("nearby") or scrubbed:find("all enemies") or scrubbed:find("enemies within") or scrubbed:find("targets within") or scrubbed:find("cone in front") then
        isAoE = true
        aoeTargets = 5
    end

    -- 1. Hybrid Range + Periodic
    local dMin, dMax, hotVal, hotDur = scrubbed:match("for (%d+) to (%d+).-and another (%d+)[^%.]-over (%d+) sec")
    if not dMin then
        dMin, dMax, hotVal, hotDur = scrubbed:match("for (%d+) to (%d+).-additional (%d+)[^%.]-over (%d+) sec")
    end
    if not dMin then
        dMin, dMax, hotVal, hotDur = scrubbed:match("(%d+) to (%d+) [^%.]-damage and (%d+)[^%.]-over (%d+) sec")
    end
    if dMin and dMax and hotVal and hotDur then
        return {
            kind = kind,
            mode = "HYBRID",
            directAvg = (tonumber(dMin) + tonumber(dMax)) / 2,
            dotAvg = tonumber(hotVal),
            duration = tonumber(hotDur),
            isChanneled = isChanneled,
            isAoE = isAoE,
            aoeTargets = aoeTargets,
            lowerText = lower,
        }
    end

    -- 2. Hybrid Flat + Periodic
    local flatDir, flatHot, flatDur = scrubbed:match("for (%d+)[^%.]-and another (%d+)[^%.]-over (%d+) sec")
    if flatDir and flatHot and flatDur then
        return {
            kind = kind,
            mode = "HYBRID",
            directAvg = tonumber(flatDir),
            dotAvg = tonumber(flatHot),
            duration = tonumber(flatDur),
            isChanneled = isChanneled,
            isAoE = isAoE,
            aoeTargets = aoeTargets,
            lowerText = lower,
        }
    end

    -- 3. Pure Direct Range
    local minVal, maxVal = scrubbed:match("for (%d+) to (%d+)")
    if not minVal then
        minVal, maxVal = scrubbed:match("causes (%d+) to (%d+)")
    end
    if minVal and maxVal then
        return {
            kind = kind,
            mode = "DIRECT",
            directAvg = (tonumber(minVal) + tonumber(maxVal)) / 2,
            dotAvg = 0,
            duration = 0,
            isChanneled = isChanneled,
            isAoE = isAoE,
            aoeTargets = aoeTargets,
            lowerText = lower,
        }
    end

    -- 4. Pure Periodic / Channeled
    local dotOnly, durOnly = scrubbed:match("(%d+)[^%.]-over (%d+) sec")
    if dotOnly and durOnly then
        return {
            kind = kind,
            mode = "PERIODIC",
            directAvg = 0,
            dotAvg = tonumber(dotOnly),
            duration = tonumber(durOnly),
            isChanneled = isChanneled,
            isAoE = isAoE,
            aoeTargets = aoeTargets,
            lowerText = lower,
        }
    end

    -- 5. Pure Flat Direct (safe now that "for X sec" is scrubbed)
    local flatVal = scrubbed:match("for (%d+)")
    if flatVal then
        return {
            kind = kind,
            mode = "DIRECT",
            directAvg = tonumber(flatVal),
            dotAvg = 0,
            duration = 0,
            isChanneled = isChanneled,
            isAoE = isAoE,
            aoeTargets = aoeTargets,
            lowerText = lower,
        }
    end

    return nil
end

local function EvaluateSpell(spellID, descText)
    local manaCost = GetManaCost(spellID)
    if not manaCost or manaCost <= 0 then return nil end

    local spellName, castTime, rankText, rankNum = GetSpellMeta(spellID)
    if not spellName then return nil end

    local parsed = ParseSpellValues(descText)
    if not parsed then return nil end

    local spellDmg, critChance = GetSpellSchoolStats(parsed.lowerText)
    local bonusStat = (parsed.kind == "HEAL") and (GetSpellBonusHealing and GetSpellBonusHealing() or 0) or spellDmg

    local spellLevel = C_Spell and C_Spell.GetSpellLevelLearned and C_Spell.GetSpellLevelLearned(spellID) or 60
    local penalty = GetDownrankPenalty(spellLevel)
    local aoePenalty = parsed.isAoE and (1 / 3) or 1.0

    local clampedCast = math.max(1.5, math.min(3.5, castTime))
    local clampedDur = math.min(15, math.max(1, parsed.duration or 0))

    local baseTotal = parsed.directAvg + parsed.dotAvg
    local directBonus, dotBonus = 0, 0

    if parsed.mode == "ABSORB" then
        -- Standard Classic/Forever shield coefficient (~10% base +healing)
        directBonus = bonusStat * 0.10 * penalty
    elseif parsed.mode == "DIRECT" then
        local coeff = (clampedCast / 3.5) * aoePenalty * penalty
        directBonus = bonusStat * coeff
    elseif parsed.mode == "PERIODIC" then
        local coeff = (clampedDur / 15) * aoePenalty * penalty
        dotBonus = bonusStat * coeff
    elseif parsed.mode == "HYBRID" then
        local cFactor = clampedCast / 3.5
        local dFactor = clampedDur / 15
        local sumFactor = cFactor + dFactor
        local directCoeff = (cFactor * (cFactor / sumFactor)) * penalty
        local dotCoeff = (dFactor * (dFactor / sumFactor)) * penalty
        directBonus = bonusStat * directCoeff
        dotBonus = bonusStat * dotCoeff
    end

    local effectiveDirect = parsed.directAvg + directBonus
    local effectiveDot = parsed.dotAvg + dotBonus

    -- Shields do not crit; direct heals/nukes scale with optional crit toggle
    local canCrit = (parsed.mode ~= "ABSORB") and (ForeverRankDB and ForeverRankDB.includeCrit)
    local critMult = canCrit and (1 + (critChance * 0.5)) or 1.0
    local effectiveSingle = (effectiveDirect * critMult) + effectiveDot

    local basePerMana = baseTotal / manaCost
    local effPerMana = effectiveSingle / manaCost

    local execTime = parsed.isChanneled and math.max(1.5, parsed.duration) or math.max(1.5, castTime)
    local perCastSec = effectiveSingle / execTime
    local perTickSec = (parsed.duration and parsed.duration > 0) and (effectiveSingle / parsed.duration) or perCastSec

    if rankText ~= "" then
        rankCache[spellName] = rankCache[spellName] or {}
        rankCache[spellName][rankText] = {
            eff = effPerMana,
            avg = effectiveSingle,
            cost = manaCost,
            id = spellID,
            rankNum = rankNum or 0,
            isAoE = parsed.isAoE,
            aoeTargets = parsed.aoeTargets,
            kind = parsed.kind,
        }
        spellIDMap[spellID] = {
            spellName = spellName,
            rankText = rankText,
            rankNum = rankNum or 0,
        }
    end

    return {
        spellName = spellName,
        rankText = rankText,
        rankNum = rankNum,
        kind = parsed.kind,
        mode = parsed.mode,
        manaCost = manaCost,
        baseTotal = baseTotal,
        effectiveSingle = effectiveSingle,
        basePerMana = basePerMana,
        effPerMana = effPerMana,
        perCastSec = perCastSec,
        perTickSec = perTickSec,
        isAoE = parsed.isAoE,
        aoeTargets = parsed.aoeTargets,
    }
end

local function GetSpellRankLeaders(spellName)
    local ranks = rankCache[spellName]
    if not ranks then return nil, 0, nil, 0, 0 end

    local bestRank, bestEff = nil, 0
    local maxRank, maxRankNum = nil, 0
    local count = 0

    for rName, rData in pairs(ranks) do
        count = count + 1
        if rData.eff > bestEff then
            bestEff = rData.eff
            bestRank = rName
        end
        if rData.rankNum and rData.rankNum > maxRankNum then
            maxRankNum = rData.rankNum
            maxRank = rName
        end
    end

    return bestRank, bestEff, maxRank, maxRankNum, count
end

local function UpdateActionBarBadges()
    if InCombatLockdown() then return end

    local showBadges = ForeverRankDB and ForeverRankDB.showBadges

    for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn then
                if not btn.foreverRankBadge then
                    local fs = btn:CreateFontString(nil, "OVERLAY")
                    fs:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
                    fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
                    fs:SetJustifyH("LEFT")
                    btn.foreverRankBadge = fs
                end

                local badge = btn.foreverRankBadge
                local shown = false

                if showBadges and btn.action and HasAction(btn.action) then
                    local actionType, id = GetActionInfo(btn.action)
                    if actionType == "spell" and id and spellIDMap[id] then
                        local meta = spellIDMap[id]
                        local bestRank, _, maxRank, _, totalRanks = GetSpellRankLeaders(meta.spellName)
                        if totalRanks > 1 and meta.rankNum and meta.rankNum > 0 then
                            if meta.rankText == bestRank then
                                badge:SetText(string.format("|cff00ff00R%d|r", meta.rankNum))
                            elseif meta.rankText == maxRank then
                                badge:SetText(string.format("|cffffd100R%d|r", meta.rankNum))
                            else
                                badge:SetText(string.format("|cffaaaaaaR%d|r", meta.rankNum))
                            end
                            badge:Show()
                            shown = true
                        end
                    end
                end

                if not shown then
                    badge:Hide()
                end
            end
        end
    end
end

local function GetHeadlessSpellDescription(spellID)
    if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
        local data = C_TooltipInfo.GetSpellByID(spellID)
        if data and data.lines and #data.lines > 0 then
            local lastLine = data.lines[#data.lines]
            if lastLine and lastLine.leftText and not (issecretvalue and issecretvalue(lastLine.leftText)) then
                return lastLine.leftText
            end
        end
    end
    if C_Spell and C_Spell.GetSpellDescription then
        return C_Spell.GetSpellDescription(spellID)
    end
    return nil
end

local function ScanSpellbook()
    scanPending = false
    if InCombatLockdown() then
        scanQueuedAfterCombat = true
        return
    end

    table.wipe(rankCache)
    table.wipe(spellIDMap)

    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
        for i = 1, numSkillLines do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
            if skillLineInfo and skillLineInfo.itemIndexOffset and skillLineInfo.numSpellBookItems then
                local startSlot = skillLineInfo.itemIndexOffset + 1
                local endSlot = skillLineInfo.itemIndexOffset + skillLineInfo.numSpellBookItems
                for slot = startSlot, endSlot do
                    local itemInfo = C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player)
                    if itemInfo and not itemInfo.isPassive and itemInfo.spellID then
                        local desc = GetHeadlessSpellDescription(itemInfo.spellID)
                        if desc then
                            EvaluateSpell(itemInfo.spellID, desc)
                        end
                    end
                end
            end
        end
        UpdateActionBarBadges()
        return
    end

    if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSlots = GetSpellTabInfo(tab)
            for slot = offset + 1, offset + numSlots do
                local spellType, spellID = GetSpellBookItemInfo(slot, "spell")
                if spellType == "SPELL" and spellID then
                    local desc = GetHeadlessSpellDescription(spellID)
                    if desc then
                        EvaluateSpell(spellID, desc)
                    end
                end
            end
        end
    end

    UpdateActionBarBadges()
end

local function QueueSpellbookScan()
    if scanPending then return end
    scanPending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, ScanSpellbook)
    else
        ScanSpellbook()
    end
end

local function OnSpellTooltip(tooltip, data)
    if InCombatLockdown() then return end
    if not data or not data.id then return end
    if issecretvalue and issecretvalue(data.id) then return end

    local descText = nil
    if data.lines and #data.lines > 0 then
        local lastLine = data.lines[#data.lines]
        if lastLine and lastLine.leftText and not (issecretvalue and issecretvalue(lastLine.leftText)) then
            descText = lastLine.leftText
        end
    end
    if not descText then return end

    local result = EvaluateSpell(data.id, descText)
    if not result then return end

    local metricLabel = (result.kind == "HEAL") and "HPM" or "DPM"
    local throughputLabel = (result.kind == "HEAL") and "HPCT" or "DPCT"
    local modeTag = ""
    if result.mode == "HYBRID" then
        modeTag = " |cff88ccff[Direct+HoT]|r"
    elseif result.mode == "ABSORB" then
        modeTag = " |cff88ccff[Shield]|r"
    end

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(
        string.format("|cff00ccffForeverRank|r (%s)%s:", metricLabel, modeTag),
        string.format("|cffffffff%.2f|r |cffaaaaaa(Base: %.2f)|r", result.effPerMana, result.basePerMana)
    )

    if result.mode == "PERIODIC" then
        tooltip:AddDoubleLine(
            string.format("Est. Output (%s / Tick):", throughputLabel),
            string.format("|cff00ff00%.0f|r |cffaaaaaa(%.1f/cast • %.1f/s)|r", result.effectiveSingle, result.perCastSec, result.perTickSec)
        )
    else
        tooltip:AddDoubleLine(
            string.format("Est. Output & %s:", (result.kind == "HEAL") and "HPS" or "DPS"),
            string.format("|cff00ff00%.0f|r |cffaaaaaa(%.1f/s)|r", result.effectiveSingle, result.perCastSec)
        )
    end

    if result.isAoE and result.aoeTargets > 1 then
        local multiOutput = result.effectiveSingle * result.aoeTargets
        local multiEff = result.effPerMana * result.aoeTargets
        tooltip:AddDoubleLine(
            string.format("AoE (%d Targets):", result.aoeTargets),
            string.format("|cff00ff88%.2f %s|r |cffaaaaaa(%.0f total)|r", multiEff, metricLabel, multiOutput)
        )
    end

    local bestRank, bestEff = GetSpellRankLeaders(result.spellName)
    if bestRank and result.rankText ~= "" then
        if bestRank == result.rankText then
            tooltip:AddDoubleLine("Downrank Status:", "|cff00ff00Peak Mana Efficiency|r")
        else
            local diffPct = ((result.effPerMana - bestEff) / bestEff) * 100
            tooltip:AddDoubleLine(
                "Best Rank Known:",
                string.format("|cffffd100%s|r (%.2f %s, %.0f%%)", bestRank, bestEff, metricLabel, diffPct)
            )
        end
    end

    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpellTooltip)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        InitDB()
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        UpdateActionBarBadges()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if scanQueuedAfterCombat then
            scanQueuedAfterCombat = false
            QueueSpellbookScan()
        else
            UpdateActionBarBadges()
        end
    else
        QueueSpellbookScan()
    end
end)

SLASH_FOREVERRANK1 = "/frank"
SLASH_FOREVERRANK2 = "/foreverrank"
SlashCmdList["FOREVERRANK"] = function(msg)
    InitDB()
    local cmd = (msg or ""):lower():match("^%s*(%S+)") or ""

    if cmd == "badges" or cmd == "bars" then
        ForeverRankDB.showBadges = not ForeverRankDB.showBadges
        UpdateActionBarBadges()
        print(string.format("|cff00ccff[ForeverRank]|r Action Bar Rank Badges: %s", ForeverRankDB.showBadges and "|cff00ff00ON|r" or "|cffff5555OFF|r"))
        return
    elseif cmd == "crit" then
        ForeverRankDB.includeCrit = not ForeverRankDB.includeCrit
        ScanSpellbook()
        print(string.format("|cff00ccff[ForeverRank]|r Spell Crit Scaling: %s", ForeverRankDB.includeCrit and "|cff00ff00ON|r" or "|cffff5555OFF|r"))
        return
    end

    ScanSpellbook()
    print("|cff00ccff[ForeverRank]|r Peak Mana Efficiency Summary (Commands: |cffffd100/frank badges|r, |cffffd100/frank crit|r):")
    local count = 0
    for spellName, _ in pairs(rankCache) do
        local bestRank, bestEff, maxRank, _, numRanks = GetSpellRankLeaders(spellName)
        if bestRank and numRanks > 1 then
            count = count + 1
            local rData = rankCache[spellName][bestRank]
            local label = (rData.kind == "HEAL") and "HPM" or "DPM"
            print(string.format("  • |cffffffff%s|r: |cff00ff00%s|r (%.2f %s, %.0f avg, %d mana) | Max: |cffffd100%s|r",
                spellName, bestRank, bestEff, label, rData.avg, rData.cost, maxRank or bestRank))
        end
    end
    if count == 0 then
        print("  No multi-rank healing or damage spells detected yet.")
    end
end