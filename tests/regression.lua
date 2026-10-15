-- Run from the addon directory with: lua5.1 tests/regression.lua
-- Alternatively: python tests/run.py (requires Lupa's Lua 5.1 module).
-- These fixtures model readable out-of-combat APIs, not WoW's secret-value VM.
-- Production source is loaded unchanged. Private helpers are reached through
-- registered callbacks' debug upvalues, without adding test exports to the addon.

assert(_VERSION == "Lua 5.1", "Use Lua 5.1 to match the addon runtime")
local source = FOREVERRANK_TEST_SOURCE
if not source then
    local file = assert(io.open((arg and arg[1]) or "ForeverRank.lua", "rb"))
    source = file:read("*a")
    file:close()
    source = source:gsub("^\239\187\191", "")
end
assert(loadstring(source, "@ForeverRank.lua"))

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s",
        label or "value", tostring(expected), tostring(actual)))
end

local function near(actual, expected, label)
    assert(type(actual) == "number" and math.abs(actual - expected) < 0.00001,
        string.format("%s: expected %.5f, got %s", label or "value", expected, tostring(actual)))
end

local function newWorld(initialSpells)
    local state = {
        spells = initialSpells or {}, book = {}, frames = {}, timers = {}, combat = false,
        healing = 0, damage = {}, critChance = 0, critReads = 0,
        actions = {}, prints = {}, bonusReads = 0,
        descReads = {}, hooks = {}, known = {}, secret = {}, tooltipLines = {}, loadRequests = {},
    }
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.SlashCmdList = {}
    env.Enum = {
        TooltipDataType = {Spell = 1}, SpellBookSpellBank = {Player = 0},
        SpellBookItemType = {Spell = 1, FutureSpell = 2, Flyout = 3},
    }
    env.STANDARD_TEXT_FONT = "mock-font"
    env.table = setmetatable({wipe = function(t)
        for key in pairs(t) do t[key] = nil end
    end}, {__index = table})
    env.wipe = env.table.wipe
    env.InCombatLockdown = function() return state.combat end
    env.issecretvalue = function(value) return state.secret[value] == true end
    env.GetSpellBonusHealing = function()
        state.bonusReads = state.bonusReads + 1
        return state.healing
    end
    env.GetSpellBonusDamage = function(school)
        state.bonusReads = state.bonusReads + 1
        return state.damage[school] or 0
    end
    -- Forever build 70374 exposes unified spell crit with no school argument.
    env.GetSpellCritChance = function()
        state.critReads = state.critReads + 1
        if state.critValues then
            return state.critValues[state.critReads] or state.critChance
        end
        return state.critChance
    end
    env.UnitExists = function(unit) return unit == "player" end
    env.GetTime = function() return 1 end
    env.print = function(...) state.prints[#state.prints + 1] = {...} end
    env.C_Timer = {After = function(delay, fn)
        state.timers[#state.timers + 1] = {delay = delay, fn = fn}
    end}
    env.C_Spell = {
        GetSpellInfo = function(id)
            local spell = state.spells[id]
            return spell and {name = spell.name, castTime = spell.castMS or 1500, spellID = id}
        end,
        GetSpellSubtext = function(id) return state.spells[id] and state.spells[id].rank end,
        GetSpellLevelLearned = function(id) return state.spells[id].level or 30 end,
        GetSpellPowerCost = function(id)
            local spell = state.spells[id]
            if not spell then return nil end
            return spell.costs or {{type = 0, name = "MANA", cost = spell.cost,
                minCost = spell.cost, costPercent = 0, costPerSec = spell.costPerSec or 0,
                requiredAuraID = spell.requiredAuraID or 0, hasRequiredAura = spell.hasRequiredAura == true}}
        end,
        GetSpellDescription = function(id)
            state.descReads[id] = (state.descReads[id] or 0) + 1
            local spell = state.spells[id]
            if not spell then return nil end
            return type(spell.desc) == "function" and spell.desc(state) or spell.desc
        end,
        RequestLoadSpellData = function(id)
            state.loadRequests[id] = (state.loadRequests[id] or 0) + 1
        end,
    }
    local function isKnown(id)
        if state.known[id] ~= nil then return state.known[id] end
        for _, item in ipairs(state.book) do
            if item.spellID == id and item.itemType == env.Enum.SpellBookItemType.Spell
                and not item.isOffSpec then return true end
        end
        return false
    end
    env.IsSpellKnown = isKnown
    env.IsPlayerSpell = isKnown
    env.C_SpellBook = {
        GetNumSpellBookSkillLines = function() return 1 end,
        GetSpellBookSkillLineInfo = function()
            return {itemIndexOffset = 0, numSpellBookItems = #state.book}
        end,
        GetSpellBookItemInfo = function(slot) return state.book[slot] end,
        IsSpellKnown = isKnown,
        IsSpellInSpellBook = isKnown,
    }
    env.C_TooltipInfo = {GetSpellByID = function(id)
        state.descReads[id] = (state.descReads[id] or 0) + 1
        local spell = state.spells[id]
        if not spell then return nil end
        local description = type(spell.desc) == "function" and spell.desc(state) or spell.desc
        return {id = id, lines = state.tooltipLines[id] or {{leftText = description}}}
    end}
    env.TooltipDataProcessor = {AddTooltipPostCall = function(_, fn) state.tooltipHook = fn end}
    env.CreateFrame = function()
        local frame = {events = {}, scripts = {}}
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:RegisterUnitEvent(event) self.events[event] = true end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        state.frames[#state.frames + 1] = frame
        return frame
    end
    env.HasAction = function(slot) return state.actions[slot] ~= nil end
    env.GetActionInfo = function(slot)
        local action = state.actions[slot]
        if type(action) == "table" then return action.type, action.id end
        return "spell", action
    end
    env.hooksecurefunc = function(target, name, fn)
        if fn then
            state.hooks[#state.hooks + 1] = {target = target, name = name, fn = fn}
        else
            state.hooks[#state.hooks + 1] = {name = target, fn = name}
        end
    end
    env.ActionButton_UpdateAction = function() end

    local chunk = assert(loadstring(source, "@ForeverRank.lua"))
    setfenv(chunk, env)
    chunk("ForeverRank", {})

    local world = {state = state, env = env}
    function world:event(event, ...)
        for _, frame in ipairs(state.frames) do
            if frame.events[event] and frame.scripts.OnEvent then
                frame.scripts.OnEvent(frame, event, ...)
            end
        end
    end
    function world:registered(event)
        for _, frame in ipairs(state.frames) do
            if frame.events[event] then return true end
        end
        return false
    end
    function world:drainTimers()
        local count = 0
        while #state.timers > 0 do
            count = count + 1
            assert(count < 100, "timer loop did not settle")
            local timer = table.remove(state.timers, 1)
            timer.fn()
        end
    end
    local private = {}
    local visited = {}
    local function collect(fn)
        if visited[fn] then return end
        visited[fn] = true
        local index = 1
        while true do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            private[name] = value
            if type(value) == "function" then collect(value) end
            index = index + 1
        end
    end
    function world:private(name)
        -- Re-read upvalues so atomic cache replacement remains testable.
        private, visited = {}, {}
        if state.tooltipHook then collect(state.tooltipHook) end
        for _, frame in ipairs(state.frames) do
            for _, fn in pairs(frame.scripts) do collect(fn) end
        end
        for _, fn in pairs(env.SlashCmdList) do collect(fn) end
        return assert(private[name], "unreachable private helper: " .. name)
    end
    function world:addSpell(id, name, rank, description, cost, options)
        local spell = options or {}
        spell.name, spell.rank, spell.desc, spell.cost = name, "Rank " .. rank, description, cost or 100
        state.spells[id] = spell
    end
    function world:learn(id, options)
        local item = options or {}
        item.spellID = id
        if not item.itemType then item.itemType = env.Enum.SpellBookItemType.Spell end
        state.book[#state.book + 1] = item
    end
    function world:scan()
        self:private("ScanSpellbook")()
        self:drainTimers()
    end
    function world:evaluate(id, description)
        if not description then
            local spell = state.spells[id]
            description = type(spell.desc) == "function" and spell.desc(state) or spell.desc
        end
        return assert(self:private("EvaluateSpell")(id, description), "spell was not evaluated")
    end
    function world:tooltip(id, description, lines)
        local tooltip = {lines = {}, shown = false}
        function tooltip:AddLine(text) self.lines[#self.lines + 1] = {text} end
        function tooltip:AddDoubleLine(a, b) self.lines[#self.lines + 1] = {a, b} end
        function tooltip:Show() self.shown = true end
        if not description then
            local spell = state.spells[id]
            description = type(spell.desc) == "function" and spell.desc(state) or spell.desc
        end
        state.tooltipHook(tooltip, {id = id, lines = lines or {{leftText = description}}})
        return tooltip
    end
    function world:button(name, slot)
        local button = {action = slot}
        function button:CreateFontString()
            local font = {shown = false, text = ""}
            function font:SetFont() end
            function font:SetPoint() end
            function font:SetJustifyH() end
            function font:SetText(text) self.text = text end
            function font:Show() self.shown = true end
            function font:Hide() self.shown = false end
            return font
        end
        env[name] = button
        return button
    end
    world:event("ADDON_LOADED", "ForeverRank")
    return world
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function parse(world, text, mode, direct, periodic, duration)
    local value = assert(world:private("ParseSpellValues")(text), "description was not parsed: " .. text)
    equal(value.mode, mode, "parsed mode")
    near(value.directAvg, direct, "direct output")
    near(value.dotAvg, periodic, "periodic output")
    near(value.duration, duration or 0, "duration")
    return value
end

test("live heal, damage, and shield totals do not add spell power again", function()
    local world = newWorld()
    world.state.healing = 1000
    world.state.damage[3] = 1000
    world:addSpell(1, "Heal", 1, "Heals the target for 200.", 100, {castMS = 3500, level = 1})
    world:addSpell(2, "Fire Blast", 1, "Blasts the enemy for 200 Fire damage.")
    world:addSpell(17, "Power Word: Shield", 1, "Absorbs 200 damage for 30 sec.")
    for _, id in ipairs({1, 2, 17}) do
        local result = world:evaluate(id)
        near(result.effectiveSingle, 200, "live output")
        near(result.effPerMana, 2, "output per mana")
    end
end)

test("causing and causes damage ranges parse without selecting slow durations", function()
    local world = newWorld()
    parse(world, "Sends a shadowy bolt at the enemy, causing 11 to 15 Shadow damage.", "DIRECT", 13, 0)
    parse(world, "Launches a bolt of frost, causing 20 to 22 Frost damage and slowing movement speed by 40% for 5 sec.", "DIRECT", 21, 0)
    parse(world, "Hurls a bolt that causes 100 to 120 Fire damage.", "DIRECT", 110, 0)
end)

test("flat damage sentences parse output rather than duration or debuff percentage", function()
    local world = newWorld()
    parse(world, "Blasts the target, causing 50 Fire damage and stunning it for 3 sec.", "DIRECT", 50, 0)
    parse(world, "Causes 50 Shadow damage to the target.", "DIRECT", 50, 0)
    parse(world, "Deals 50 Nature damage to the enemy.", "DIRECT", 50, 0)
end)

test("each-second channel output uses complete duration", function()
    local world = newWorld()
    local description = "Launches Arcane Missiles at the enemy, causing 20 Arcane damage each second for 5 sec."
    parse(world, description, "PERIODIC", 0, 100, 5)
    world:addSpell(5143, "Arcane Missiles", 1, description, 100, {castMS = 0})
    local result = world:evaluate(5143)
    near(result.perCastSec, 20, "channel throughput")
    near(result.perTickSec, 20, "periodic throughput")
end)

test("every-N-second channel output uses tick count", function()
    local world = newWorld()
    local description = "Drains the target, causing 30 Shadow damage every 2 sec for 6 sec."
    parse(world, description, "PERIODIC", 0, 90, 6)
    world:addSpell(689, "Drain Life", 1, description, 100, {castMS = 0})
    near(world:evaluate(689).perCastSec, 15, "drain channel throughput")
end)

test("channels with continuing mana costs are rejected until total cost is modeled", function()
    local world = newWorld()
    local description = "Causes 20 Arcane damage each second for 5 sec."
    world:addSpell(5143, "Arcane Missiles", 1, description, 100, {costPerSec = 20})
    equal(world:private("EvaluateSpell")(5143, description), nil, "continuing mana cost")
end)

test("ordinary mana cost applies with requiredAuraID zero and hasRequiredAura false", function()
    local world = newWorld()
    world:addSpell(1, "Cost Heal", 1, "Heals the target for 200.", 100,
        {requiredAuraID = 0, hasRequiredAura = false})
    near(world:evaluate(1).manaCost, 100, "unconditional mana cost")
end)

test("inactive conditional cost is skipped before the applicable ordinary cost", function()
    local world = newWorld()
    world:addSpell(1, "Cost Heal", 1, "Heals the target for 200.", 100, {costs = {
        {type = 0, name = "MANA", cost = 10, costPerSec = 0, requiredAuraID = 123, hasRequiredAura = false},
        {type = 0, name = "MANA", cost = 100, costPerSec = 0, requiredAuraID = 0, hasRequiredAura = false},
    }})
    near(world:evaluate(1).manaCost, 100, "applicable mana cost")
end)

test("an active conditional aura cost is eligible", function()
    local world = newWorld()
    world:addSpell(1, "Cost Heal", 1, "Heals the target for 200.", 10,
        {requiredAuraID = 123, hasRequiredAura = true})
    near(world:evaluate(1).manaCost, 10, "active aura mana cost")
end)

test("unreadable mana costs are rejected before arithmetic", function()
    local world = newWorld()
    world:addSpell(1, "Cost Heal", 1, "Heals the target for 200.")
    world.state.secret[100] = true
    equal(world:private("EvaluateSpell")(1, world.state.spells[1].desc), nil, "secret mana cost")
end)

test("ranged hybrid damage preserves the additional periodic component", function()
    local world = newWorld()
    parse(world, "Hurls a fiery ball that causes 100 to 120 Fire damage and an additional 20 Fire damage over 8 sec.", "HYBRID", 110, 20, 8)
end)

test("flat hybrid damage and healing preserve both components", function()
    local world = newWorld()
    parse(world, "Causes 100 Fire damage and an additional 40 Fire damage over 12 sec.", "HYBRID", 100, 40, 12)
    parse(world, "Heals the target for 100 and another 50 over 15 sec.", "HYBRID", 100, 50, 15)
end)

test("periodic-only ranges and totals are not treated as direct damage", function()
    local world = newWorld()
    parse(world, "Causes 80 Shadow damage over 8 sec.", "PERIODIC", 0, 80, 8)
    parse(world, "Heals the target for 100 over 15 sec.", "PERIODIC", 0, 100, 15)
    parse(world, "Causes 80 to 100 Shadow damage over 8 sec.", "PERIODIC", 0, 90, 8)
end)

test("thousands separators do not truncate live output", function()
    local world = newWorld()
    parse(world, "Heals the target for 1,000 to 1,200.", "DIRECT", 1100, 0)
    parse(world, "Absorbs 1,000 damage for 30 sec.", "ABSORB", 1000, 0)
end)

test("mana restoration, costs, and slow-only descriptions are rejected", function()
    local world = newWorld()
    for _, description in ipairs({
        "Restores 100 mana over 5 sec.",
        "Costs 100 mana. Slows the target for 5 sec.",
        "Increases healing done by 20% for 15 sec.",
    }) do
        equal(world:private("ParseSpellValues")(description), nil, "non-output description")
    end
end)

test("mana-restoring totems do not confuse their health with spell output", function()
    local world = newWorld()
    local description = "Summons a Mana Spring Totem with 5 health at the feet of the caster for 2 min that restores 4 mana every 2 sec to group members within 20 yards."
    equal(world:private("ParseSpellValues")(description), nil, "Mana Spring mana restoration")
end)

test("mana-consuming shields are rejected rather than assuming an upfront-only cost", function()
    local world = newWorld()
    local description = "Absorbs 120 physical damage, draining mana instead. Lasts 1 min."
    world:addSpell(1463, "Mana Shield", 1, description)
    equal(world:private("EvaluateSpell")(1463, description), nil, "Mana Shield continuing cost")
end)

test("unsupported periodic schedules do not fall through to flat direct output", function()
    local world = newWorld()
    for _, description in ipairs({
        "Summons a Healing Stream Totem with 5 health for 5 min that heals nearby party members for 5 every 2 sec.",
        "Causes 10 Shadow damage every 2 sec.",
        "Heals the target for 100 over 1 min.",
    }) do
        equal(world:private("ParseSpellValues")(description), nil, "unsupported schedule: " .. description)
    end
end)

test("ordinary caster-centered AoE damage is not confused with Hellfire self damage", function()
    local world = newWorld()
    local nova = "Blasts enemies near the caster for 19 to 21 Frost damage and freezes them in place for 8 sec."
    local blast = "A wave of flame radiates outward from the caster, damaging all enemies caught within the blast for 154 to 186 Fire damage, and dazing them for 6 sec."
    parse(world, nova, "DIRECT", 20, 0)
    parse(world, blast, "DIRECT", 170, 0)
    world:addSpell(122, "Frost Nova", 1, nova)
    world:addSpell(11113, "Blast Wave", 1, blast)
    near(world:evaluate(122).effectiveSingle, 20, "Frost Nova output")
    near(world:evaluate(11113).effectiveSingle, 170, "Blast Wave output")
end)

test("percentage effects do not become flat output amounts", function()
    local world = newWorld()
    for _, description in ipairs({
        "Causes 20% of the target's health as Shadow damage.",
        "Heals the target for 20% of its maximum health.",
        "Absorbs 20% of incoming damage for 5 sec.",
        "Increases damage by 20% for 10 sec.",
    }) do
        equal(world:private("ParseSpellValues")(description), nil, "percentage output: " .. description)
    end
end)

test("tooltip descriptions are found before an unrelated footer", function()
    local world = newWorld()
    world:addSpell(1, "Footer Heal", 1, "")
    world.state.tooltipLines[1] = {
        {leftText = "Footer Heal"}, {leftText = "100 Mana"},
        {leftText = "Heals the target for 200."},
        {leftText = "Requires Level 30"},
    }
    world:learn(1)
    world:scan()
    local best, efficiency = world:private("GetSpellRankLeaders")("Footer Heal")
    equal(best, "Rank 1", "leader with tooltip footer")
    near(efficiency, 2, "efficiency from description line")
    equal(world:tooltip(1).shown, true, "tooltip metrics with footer")
end)

test("visible tooltip lines can supply a description when headless data is unavailable", function()
    local world = newWorld()
    world:addSpell(1, "Visible Heal", 1, "")
    local tooltip = world:tooltip(1, nil, {
        {leftText = "Visible Heal"}, {leftText = "Heals the target for 200."},
        {leftText = "Required Level 30"},
    })
    equal(tooltip.shown, true, "visible tooltip fallback")
    equal(world:private("GetSpellRankLeaders")("Visible Heal"), nil, "unlearned visible tooltip cache")
end)

test("missing descriptions load asynchronously without duplicate requests", function()
    local world = newWorld()
    world:addSpell(1, "Loading Heal", 1, "Heals the target for 100.")
    world:addSpell(2, "Loading Heal", 2, "")
    world:learn(1)
    world:learn(2)
    world:scan()
    world:scan()
    equal(world.state.loadRequests[2], 1, "one pending description load request")
    local _, _, maximum, _, count = world:private("GetSpellRankLeaders")("Loading Heal")
    equal(maximum, "Rank 1", "maximum while higher rank is unavailable")
    equal(count, 1, "loaded candidate count")
    world.state.spells[2].desc = "Heals the target for 500."
    world:event("SPELL_DATA_LOAD_RESULT", 2, true)
    world:drainTimers()
    local best, efficiency, loadedMaximum, _, loadedCount = world:private("GetSpellRankLeaders")("Loading Heal")
    equal(best, "Rank 2", "leader after data load")
    near(efficiency, 5, "loaded rank efficiency")
    equal(loadedMaximum, "Rank 2", "maximum after data load")
    equal(loadedCount, 2, "candidate count after data load")
end)

test("a completed spell-data load with an empty description does not request forever", function()
    local world = newWorld()
    world:addSpell(1, "Empty Spell", 1, "")
    world:learn(1)
    world:scan()
    equal(world.state.loadRequests[1], 1, "initial missing-description request")
    world:event("SPELL_DATA_LOAD_RESULT", 1, true)
    world:drainTimers()
    world:event("SPELLS_CHANGED")
    world:drainTimers()
    world:scan()
    equal(world.state.loadRequests[1], 1, "bounded completed data request")
end)

test("a supported unranked spell can show output without requesting nonexistent rank data", function()
    local world = newWorld()
    world:addSpell(1, "Unranked Heal", 1, "Heals the target for 200.")
    world.state.spells[1].rank = ""
    world:learn(1)
    world:scan()
    equal(world.state.loadRequests[1], nil, "unranked metadata request")
    equal(world:tooltip(1).shown, true, "unranked output tooltip")
    equal(world:private("GetSpellRankLeaders")("Unranked Heal"), nil, "unranked leaders")
end)

test("future, off-spec, passive, and non-spell entries do not become rank leaders", function()
    local world = newWorld()
    for id = 1, 5 do world:addSpell(id, "Known Heal", id, "Heals the target for " .. id * 100 .. ".") end
    world:learn(1)
    world:learn(2, {itemType = world.env.Enum.SpellBookItemType.FutureSpell})
    world:learn(3, {isOffSpec = true})
    world:learn(4, {isPassive = true})
    world:learn(5, {itemType = world.env.Enum.SpellBookItemType.Flyout})
    world:scan()
    local best, _, maximum, _, count = world:private("GetSpellRankLeaders")("Known Heal")
    equal(best, "Rank 1", "best learned rank")
    equal(maximum, "Rank 1", "maximum learned rank")
    equal(count, 1, "learned rank count")
    equal(world.state.descReads[2], nil, "future rank should not be evaluated")
    equal(world.state.descReads[3], nil, "off-spec rank should not be evaluated")
end)

test("hovering an unlearned rank cannot insert it into learned-rank leaders", function()
    local world = newWorld()
    world:addSpell(1, "Known Heal", 1, "Heals the target for 100.")
    world:addSpell(2, "Known Heal", 2, "Heals the target for 500.")
    world:learn(1)
    world:scan()
    world:tooltip(2)
    world:drainTimers()
    local best, _, maximum, _, count = world:private("GetSpellRankLeaders")("Known Heal")
    equal(best, "Rank 1", "best learned rank after hover")
    equal(maximum, "Rank 1", "maximum learned rank after hover")
    equal(count, 1, "learned rank count after hover")
end)

test("standalone spell evaluation does not mutate the learned rank cache", function()
    local world = newWorld()
    world:addSpell(1, "Known Heal", 1, "Heals the target for 100.")
    world:addSpell(2, "Known Heal", 2, "Heals the target for 500.")
    world:learn(1)
    world:scan()
    world:evaluate(2)
    local best, _, _, _, count = world:private("GetSpellRankLeaders")("Known Heal")
    equal(best, "Rank 1", "leader after independent evaluation")
    equal(count, 1, "cache size after independent evaluation")
end)

test("removing a learned spell clears its rank and action badge", function()
    local world = newWorld()
    world:addSpell(1, "Known Heal", 1, "Heals the target for 100.")
    world:addSpell(2, "Known Heal", 2, "Heals the target for 150.")
    world:learn(1)
    world:learn(2)
    world.state.actions[1] = 2
    local button = world:button("ActionButton1", 1)
    world:scan()
    equal(button.foreverRankBadge.shown, true, "initial badge")
    table.remove(world.state.book, 2)
    world:event("SPELLS_CHANGED")
    world:drainTimers()
    local _, _, maximum, _, count = world:private("GetSpellRankLeaders")("Known Heal")
    equal(maximum, "Rank 1", "maximum rank after removal")
    equal(count, 1, "rank count after removal")
    equal(button.foreverRankBadge.shown, false, "removed rank badge")
end)

test("Renew and Rejuvenation periodic healing includes eligible critical strikes", function()
    local world = newWorld()
    world.state.critChance = 100
    for _, spell in ipairs({{139, "Renew"}, {774, "Rejuvenation"}}) do
        world:addSpell(spell[1], spell[2], 1, "Heals the target for 100 over 15 sec.")
        local result = world:evaluate(spell[1])
        near(result.effectiveSingle, 150, spell[2] .. " critical output")
    end
    world.env.ForeverRankDB.includeCrit = false
    near(world:evaluate(139).effectiveSingle, 100, "crit toggle disabled")
end)

test("Tranquility channel healing uses duration and periodic critical chance", function()
    local world = newWorld()
    world.state.critChance = 100
    world:addSpell(740, "Tranquility", 1,
        "Heals nearby party members for 30 every 2 sec for 6 sec.", 100, {castMS = 0})
    local result = world:evaluate(740)
    near(result.effectiveSingle, 135, "Tranquility output")
    near(result.perCastSec, 22.5, "Tranquility channel throughput")
end)

test("known periodic crit families match higher ranks through localized base names", function()
    local world = newWorld({
        [139] = {name = "Renouveau", rank = "Rank 1", desc = "Heals the target for 100 over 15 sec.", cost = 100},
    })
    world.state.critChance = 100
    world:addSpell(6074, "Renouveau", 2, "Heals the target for 200 over 15 sec.")
    near(world:evaluate(6074).effectiveSingle, 300, "higher localized periodic rank")
end)

test("shields and ordinary damage-over-time effects do not gain periodic crit", function()
    local world = newWorld()
    world.state.critChance = 100
    world:addSpell(17, "Power Word: Shield", 1, "Absorbs 100 damage for 30 sec.")
    world:addSpell(172, "Corruption", 1, "Causes 100 Shadow damage over 18 sec.")
    near(world:evaluate(17).effectiveSingle, 100, "shield output")
    near(world:evaluate(172).effectiveSingle, 100, "non-critting periodic damage")
end)

test("school-specific zero power does not borrow another school's power", function()
    local world = newWorld()
    world.state.damage[3], world.state.damage[6] = 0, 200
    world:addSpell(1, "Fire Blast", 1, "Blasts the enemy for 100 Fire damage.")
    near(world:evaluate(1).effectiveSingle, 100, "Fire output with Shadow-only power")
    equal(world.state.bonusReads, 0, "spell-power lookups for already-scaled live total")
end)

local function changingRanks(world)
    world:addSpell(1, "Changing Heal", 1, function(state)
        return "Heals the target for " .. (100 + state.healing) .. "."
    end, 50)
    world:addSpell(2, "Changing Heal", 2, function(state)
        return "Heals the target for " .. (300 + state.healing) .. "."
    end, 200)
    world:learn(1)
    world:learn(2)
    world:scan()
    equal(world:private("GetSpellRankLeaders")("Changing Heal"), "Rank 1", "initial leader")
end

test("all ranks in one scan use the same critical-chance snapshot", function()
    local world = newWorld()
    world:addSpell(1, "Snapshot Heal", 1, "Heals the target for 100.")
    world:addSpell(2, "Snapshot Heal", 2, "Heals the target for 100.")
    world:learn(1)
    world:learn(2)
    world.state.critValues = {100, 0}
    world:scan()
    local ranks = world:private("rankCache")["Snapshot Heal"]
    near(ranks["Rank 1"].eff, 1.5, "Rank 1 snapshot")
    near(ranks["Rank 2"].eff, 1.5, "Rank 2 snapshot")
end)

test("a stat-change event refreshes every learned rank before comparison", function()
    local world = newWorld()
    changingRanks(world)
    world.state.healing = 500
    equal(world:registered("UNIT_STATS"), true, "stat event registration")
    world:event("UNIT_STATS", "player")
    world:drainTimers()
    local best, efficiency = world:private("GetSpellRankLeaders")("Changing Heal")
    equal(best, "Rank 1", "same-snapshot best rank")
    near(efficiency, 12, "same-snapshot leader efficiency")
end)

test("hovering during a queued refresh never updates only one cached rank", function()
    local world = newWorld()
    changingRanks(world)
    world.state.healing = 500
    world:event("UNIT_AURA", "player", {})
    world:tooltip(2)
    -- The visible comparison must either use the old complete snapshot or a new
    -- complete snapshot. Updating only Rank 2 would falsely make it the leader.
    equal(world:private("GetSpellRankLeaders")("Changing Heal"), "Rank 1", "leader during pending refresh")
    world:drainTimers()
    local best, efficiency = world:private("GetSpellRankLeaders")("Changing Heal")
    equal(best, "Rank 1", "leader after aura refresh")
    near(efficiency, 12, "updated leader efficiency")
end)

test("tooltip-only evaluation does not overwrite one rank with a different snapshot", function()
    local world = newWorld()
    changingRanks(world)
    world.state.healing = 500
    world:tooltip(2)
    equal(world:private("GetSpellRankLeaders")("Changing Heal"), "Rank 1", "leader after unannounced live tooltip change")
end)

test("other units' aura/stat events do not rescan the player's spellbook", function()
    local world = newWorld()
    changingRanks(world)
    local reads = world.state.descReads[1]
    world:event("UNIT_AURA", "target", {})
    world:event("UNIT_STATS", "target")
    world:drainTimers()
    equal(world.state.descReads[1], reads, "player description reads for target events")
end)

test("stat changes during combat refresh all ranks after combat ends", function()
    local world = newWorld()
    changingRanks(world)
    local reads = world.state.descReads[1]
    world.state.combat = true
    world.state.healing = 500
    world:event("UNIT_AURA", "player", {})
    world:drainTimers()
    equal(world.state.descReads[1], reads, "description reads in combat")
    world.state.combat = false
    world:event("PLAYER_REGEN_ENABLED")
    world:drainTimers()
    local best, efficiency = world:private("GetSpellRankLeaders")("Changing Heal")
    equal(best, "Rank 1", "leader after combat refresh")
    near(efficiency, 12, "leader efficiency after combat refresh")
end)

local function badgeRanks(world)
    world:addSpell(1, "Badge Heal", 1, "Heals the target for 100.", 50)
    world:addSpell(2, "Badge Heal", 2, "Heals the target for 150.", 200)
    world:learn(1)
    world:learn(2)
    world.state.actions[1], world.state.actions[13] = 1, 2
    local button = world:button("ActionButton1", 1)
    world:scan()
    assert(button.foreverRankBadge.text:find("R1", 1, true), "initial badge must show Rank 1")
    return button
end

test("action page changes replace badges on reused action buttons", function()
    local world = newWorld()
    local button = badgeRanks(world)
    equal(world:registered("ACTIONBAR_PAGE_CHANGED"), true, "page event registration")
    world:event("ACTIONBAR_PAGE_CHANGED")
    -- Native action-button handlers may reassign the action after this addon
    -- receives the event. A deferred refresh must see the final slot.
    button.action = 13
    world:drainTimers()
    assert(button.foreverRankBadge.text:find("R2", 1, true), "new page must show Rank 2")
    equal(button.foreverRankBadge.shown, true, "paged badge visibility")
end)

test("action changes to macros or empty slots hide previous spell badges", function()
    local world = newWorld()
    local button = badgeRanks(world)
    world.state.actions[1] = {type = "macro", id = 1}
    world:event("ACTIONBAR_SLOT_CHANGED", 1)
    world:drainTimers()
    equal(button.foreverRankBadge.shown, false, "macro badge")
    world.state.actions[1] = nil
    world:event("ACTIONBAR_SLOT_CHANGED", 1)
    world:drainTimers()
    equal(button.foreverRankBadge.shown, false, "empty action badge")
end)

test("combat page changes defer badge work until combat ends", function()
    local world = newWorld()
    local button = badgeRanks(world)
    world.state.combat = true
    button.action = 13
    world:event("ACTIONBAR_PAGE_CHANGED")
    world:drainTimers()
    assert(button.foreverRankBadge.text:find("R1", 1, true), "badge should not mutate in combat")
    world.state.combat = false
    world:event("PLAYER_REGEN_ENABLED")
    world:drainTimers()
    assert(button.foreverRankBadge.text:find("R2", 1, true), "post-combat badge must use current action")
end)

local failures = 0
for _, entry in ipairs(tests) do
    local ok, err = pcall(entry.fn)
    if ok then
        print("PASS " .. entry.name)
    else
        failures = failures + 1
        print("FAIL " .. entry.name .. "\n  " .. tostring(err))
    end
end
print(string.format("Lua 5.1 regression checks: %d/%d passed.", #tests - failures, #tests))
print("Limits: mocked APIs cannot validate native tooltip values, event ordering, secrecy, taint, or gameplay.")
assert(failures == 0, tostring(failures) .. " regression check(s) failed")
return #tests
