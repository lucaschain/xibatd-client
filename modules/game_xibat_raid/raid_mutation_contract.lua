RaidMutationContract = { version = 2, maxMutations = 64, maxSelection = 16, maxLootEntries = 128 }
local C = RaidMutationContract
local effectKeys = { 'enemy_health_bps', 'enemy_speed_bps', 'spawn_count_bps', 'wave_time_bps', 'crystal_health_bps' }
local effects = { enemy_health_bps = 'Enemy health', enemy_speed_bps = 'Enemy movement speed',
    spawn_count_bps = 'Enemy count', wave_time_bps = 'Wave time', crystal_health_bps = 'Crystal health' }
local function number(v, low, high, integer)
    return type(v) == 'number' and v == v and v >= low and v <= high and (not integer or v == math.floor(v))
end
local function text(v, maximum, empty) return type(v) == 'string' and #v <= maximum and (empty or #v > 0) end
local function array(v, maximum, validate)
    if type(v) ~= 'table' or #v > maximum then return false end
    local count = 0
    for k, entry in pairs(v) do
        if not number(k, 1, #v, true) or not validate(entry) then return false end
        count = count + 1
    end
    return count == #v
end
local function id(v) return text(v, 64) and v:match('^[a-z0-9_-]+$') ~= nil end
function C.identity(v)
    return text(v, 20) and (v == '0' or v:match('^[1-9]%d*$') ~= nil) and (#v < 20 or v <= '18446744073709551615')
end
local function hash(v, empty) return empty and v == '' or text(v, 64) and #v == 64 and v:match('^[a-f0-9]+$') ~= nil end
local function unique(v, maximum, validate)
    local seen = {}
    return array(v, maximum, function(entry)
        if not validate(entry) or seen[entry] then return false end
        seen[entry] = true
        return true
    end)
end
local function raidIds(v) return unique(v, 64, function(n) return number(n, 1, 2147483647, true) end) end
local function effectList(v, field, low, high)
    local seen = {}
    return array(v, 5, function(e)
        if type(e) ~= 'table' or not effects[e.key] or seen[e.key] or not number(e[field], low, high, field == 'bps') then return false end
        seen[e.key] = true
        return true
    end) and #v == 5
end
local function lootEntries(v)
    return array(v, C.maxLootEntries, function(e)
        if type(e) ~= 'table' or type(e.noDrop) ~= 'boolean' or not text(e.name, 128) or not number(e.clientId, 0, 65535, true) or
            not number(e.quantity, 0, 1000000, true) or not number(e.chanceBps, 0, 10000) then return false end
        return e.noDrop and e.clientId == 0 and e.quantity == 0 or not e.noDrop and e.clientId > 0 and e.quantity > 0
    end) and #v > 0
end
function C.summary(v)
    if type(v) ~= 'table' or not hash(v.configurationHash) or not text(v.raidName, 64) or
        not number(v.goldBonusBps, 0, 1000000, true) or not number(v.ascensionXpBonusBps, 0, 1000000, true) or
        type(v.goldCapped) ~= 'boolean' or type(v.xpCapped) ~= 'boolean' or not effectList(v.effects, 'factor', 0.009999, 100.001) then return false end
    local seen = {}
    if not array(v.selected, C.maxSelection, function(e)
        if type(e) ~= 'table' or not id(e.id) or not text(e.name, 128) or seen[e.id] then return false end
        seen[e.id] = true
        return true
    end) then return false end
    local total, tables = 0, {}
    return array(v.loot, C.maxSelection, function(t)
        if type(t) ~= 'table' or not id(t.id) or tables[t.id] or not number(t.rolls, 1, 1024, true) or not lootEntries(t.entries) then return false end
        tables[t.id] = true
        total = total + #t.entries
        return total <= C.maxLootEntries
    end)
end
function C.catalog(v)
    if not hash(v.catalogHash) or not number(v.maximumSelections, 1, C.maxSelection, true) or
        not number(v.goldCapBps, 0, 1000000, true) or not number(v.xpCapBps, 0, 1000000, true) or
        not raidIds(v.excludedRaids) or not effectList(v.maximumFactors, 'bps', 10000, 1000000) then return false end
    local tables, definitions, total = {}, {}, 0
    if not array(v.lootTables, C.maxMutations, function(t)
        if type(t) ~= 'table' or not id(t.id) or tables[t.id] or not lootEntries(t.entries) then return false end
        tables[t.id] = true
        total = total + #t.entries
        return total <= C.maxLootEntries
    end) then return false end
    if not array(v.mutations, C.maxMutations, function(m)
        if type(m) ~= 'table' or not id(m.id) or definitions[m.id] or not text(m.name, 128) or not text(m.description, 2048) or
            type(m.requiresCrystal) ~= 'boolean' or not raidIds(m.excludedRaids) or not unique(m.conflicts, C.maxMutations, id) or
            not effectList(m.effects, 'bps', 1, 1000000) or not number(m.goldBonusBps, 0, 1000000, true) or
            not number(m.ascensionXpBonusBps, 0, 1000000, true) or not text(m.lootTable, 64, true) or
            not number(m.lootRolls, 0, 1024, true) then return false end
        if (m.lootRolls == 0 and m.lootTable ~= '') or (m.lootRolls > 0 and not tables[m.lootTable]) then return false end
        definitions[m.id] = true
        return true
    end) then return false end
    for _, m in ipairs(v.mutations) do for _, conflict in ipairs(m.conflicts) do if not definitions[conflict] or conflict == m.id then return false end end end
    return true
end
function C.response(action, v)
    if type(v) ~= 'table' or v.version ~= C.version then return false end
    if action == 'mutationCatalog' then return C.catalog(v) end
    if not number(v.raidId, 1, 2147483647, true) then return false end
    if action == 'raidConfiguration' then
        if not hash(v.revision) or not hash(v.catalogHash, true) or type(v.useCrystal) ~= 'boolean' or
            not number(v.lobbyChannel, 0, 65535, true) or not C.identity(v.lobbyGeneration) then return false end
        return v.lobbyChannel == 0 and v.lobbyGeneration == '0' and v.summary == nil or
            v.lobbyChannel > 0 and v.lobbyGeneration ~= '0' and C.summary(v.summary) and v.summary.configurationHash == v.revision
    end
    if action == 'mutationStatus' then
        if not C.identity(v.runId) or not C.identity(v.generation) then return false end
        return v.phase == 'clear' or (v.phase == 'lobby' or v.phase == 'active' or v.phase == 'finished') and C.summary(v.summary)
    end
    if not number(v.requestId, 1, 2147483647, true) then return false end
    if action == 'raidDeployed' then return true end
    return action == 'raidDeploymentError' and text(v.code, 64) and text(v.message, 512)
end
local function contains(values, value)
    for _, candidate in ipairs(values) do if candidate == value then return true end end
    return false
end
function C.unavailable(catalog, offer, mutation)
    if contains(catalog.excludedRaids, offer.raidId) or contains(mutation.excludedRaids, offer.raidId) then return 'Unavailable for this raid.' end
    if mutation.requiresCrystal and not offer.useCrystal then return 'Requires a crystal raid.' end
end
function C.preview(catalog, offer, name, selection)
    if offer and offer.lobbyChannel > 0 then return offer.summary end
    local result = { raidName = name, selected = {}, effects = {}, loot = {}, goldBonusBps = 0, ascensionXpBonusBps = 0, goldCapped = false, xpCapped = false }
    local factors, limits = {}, {}
    for _, key in ipairs(effectKeys) do factors[key] = 1 end
    if not offer then -- Original server: a normal raid only.
        for _, key in ipairs(effectKeys) do table.insert(result.effects, { key = key, factor = 1 }) end
        return result
    end
    if not catalog or catalog.catalogHash ~= offer.catalogHash then return nil, 'Raid configuration is unavailable. Reopen the raid menu.' end
    local definitions, tables, selected, rolls = {}, {}, {}, {}
    for _, m in ipairs(catalog.mutations) do definitions[m.id] = m end
    for _, t in ipairs(catalog.lootTables) do tables[t.id] = t end
    for _, e in ipairs(catalog.maximumFactors) do limits[e.key] = e.bps end
    for mid in pairs(selection) do
        if not definitions[mid] then return nil, 'Unknown mutation in the selection.' end
        table.insert(selected, mid)
    end
    table.sort(selected)
    if #selected > catalog.maximumSelections then return nil, 'Selection limit reached. Uncheck a mutation.' end
    for _, mid in ipairs(selected) do
        local m = definitions[mid]
        local unavailable = C.unavailable(catalog, offer, m)
        if unavailable then return nil, m.name .. ': ' .. unavailable end
        for _, conflict in ipairs(m.conflicts) do if selection[conflict] then return nil, m.name .. ' conflicts with ' .. definitions[conflict].name end end
        table.insert(result.selected, { id = mid, name = m.name })
        for _, e in ipairs(m.effects) do factors[e.key] = factors[e.key] * e.bps / 10000 end
        result.goldBonusBps = result.goldBonusBps + m.goldBonusBps
        result.ascensionXpBonusBps = result.ascensionXpBonusBps + m.ascensionXpBonusBps
        if m.lootRolls > 0 then rolls[m.lootTable] = (rolls[m.lootTable] or 0) + m.lootRolls end
    end
    for i, key in ipairs(effectKeys) do
        local factor = factors[key]
        local strength = i <= 3 and factor or 1 / factor
        if strength * 10000 > limits[key] + 0.000001 then return nil, 'Combined ' .. effects[key]:lower() .. ' exceeds the raid limits.' end
        table.insert(result.effects, { key = key, factor = factor })
    end
    result.goldCapped, result.xpCapped = result.goldBonusBps > catalog.goldCapBps, result.ascensionXpBonusBps > catalog.xpCapBps
    result.goldBonusBps = math.min(result.goldBonusBps, catalog.goldCapBps)
    result.ascensionXpBonusBps = math.min(result.ascensionXpBonusBps, catalog.xpCapBps)
    local tableIds = {}
    for tid in pairs(rolls) do table.insert(tableIds, tid) end
    table.sort(tableIds)
    for _, tid in ipairs(tableIds) do table.insert(result.loot, { id = tid, rolls = rolls[tid], entries = tables[tid].entries }) end
    return result
end
function C.lines(summary)
    local lines = { #summary.selected == 0 and 'Normal raid' or 'Selected mutations' }
    for _, selected in ipairs(summary.selected) do table.insert(lines, selected.name) end
    for _, effect in ipairs(summary.effects) do
        if effect.factor ~= 1 then table.insert(lines, string.format('%s: %.2f%% of normal', effects[effect.key], effect.factor * 100)) end
    end
    table.insert(lines, string.format('Gold: +%.2f%%%s', summary.goldBonusBps / 100, summary.goldCapped and ' (capped)' or ''))
    table.insert(lines, string.format('Ascension XP: +%.2f%%%s', summary.ascensionXpBonusBps / 100, summary.xpCapped and ' (capped)' or ''))
    table.insert(lines, 'Bonuses apply to eligible rewards. Levels, soul and supplies keep their normal rules.')
    for _, t in ipairs(summary.loot) do
        table.insert(lines, string.format('Completion loot: %d independent roll(s)', t.rolls))
        for _, e in ipairs(t.entries) do
            local chance = e.chanceBps > 0 and e.chanceBps < 1 and '<0.01%' or string.format('%.2f%%', e.chanceBps / 100)
            table.insert(lines, string.format('%s%s - %s per roll', e.name, e.noDrop and '' or (' x' .. e.quantity), chance))
        end
    end
    if #summary.loot > 0 then table.insert(lines, 'Completion loot requires a successful clear and final-wave eligibility. Random drops are not guaranteed.') end
    return lines
end
