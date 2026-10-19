RaidMutationContract = { version = 1, maxMutations = 64, maxSelection = 16, maxLootEntries = 128 }
local C = RaidMutationContract
local effects = {
    enemy_health_bps = 'Enemy health', enemy_speed_bps = 'Enemy movement speed',
    spawn_count_bps = 'Enemy count', wave_time_bps = 'Wave time', crystal_health_bps = 'Crystal health',
}

local function number(v, low, high, integer)
    return type(v) == 'number' and v == v and v >= low and v <= high and (not integer or v == math.floor(v))
end
local function text(v, maximum, empty)
    return type(v) == 'string' and #v <= maximum and (empty or #v > 0)
end
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
    return text(v, 20) and (v == '0' or v:match('^[1-9]%d*$') ~= nil) and
        (#v < 20 or v <= '18446744073709551615')
end
local function hash(v, empty) return empty and v == '' or text(v, 64) and #v == 64 and v:match('^[a-f0-9]+$') ~= nil end
local function uniqueIds(v, maximum)
    local seen = {}
    return array(v, maximum, function(entry)
        if not id(entry) or seen[entry] then return false end
        seen[entry] = true
        return true
    end)
end
function C.summary(v)
    if type(v) ~= 'table' or not hash(v.configurationHash) or not text(v.raidName, 64) or
        not number(v.goldBonusBps, 0, 1000000, true) or not number(v.ascensionXpBonusBps, 0, 1000000, true) or
        type(v.goldCapped) ~= 'boolean' or type(v.xpCapped) ~= 'boolean' then return false end
    local seen = {}
    if not array(v.selected, C.maxSelection, function(entry)
        if type(entry) ~= 'table' or not id(entry.id) or not text(entry.name, 128) or seen[entry.id] then return false end
        seen[entry.id] = true
        return true
    end) then return false end
    seen = {}
    if not array(v.effects, 5, function(entry)
        if type(entry) ~= 'table' or not effects[entry.key] or seen[entry.key] or not number(entry.factor, 0.009999, 100.001) then return false end
        seen[entry.key] = true
        return true
    end) or #v.effects ~= 5 then return false end
    local total, tables = 0, {}
    return array(v.loot, C.maxSelection, function(t)
        if type(t) ~= 'table' or not id(t.id) or tables[t.id] or not number(t.rolls, 1, 1024, true) then return false end
        tables[t.id] = true
        if not array(t.entries, C.maxLootEntries, function(e)
            if type(e) ~= 'table' or type(e.noDrop) ~= 'boolean' or not text(e.name, 128) or
                not number(e.clientId, 0, 65535, true) or not number(e.quantity, 0, 1000000, true) or
                not number(e.chanceBps, 0, 10000) then return false end
            return e.noDrop and e.clientId == 0 and e.quantity == 0 or not e.noDrop and e.clientId > 0 and e.quantity > 0
        end) or #t.entries == 0 then return false end
        total = total + #t.entries
        return total <= C.maxLootEntries
    end)
end
function C.response(action, v)
    if type(v) ~= 'table' or v.version ~= C.version then return false end
    if action == 'mutationStatus' then
        if not number(v.raidId, 1, 2147483647, true) or not C.identity(v.runId) or not C.identity(v.generation) then return false end
        if v.phase == 'clear' then return true end
        return (v.phase == 'lobby' or v.phase == 'active' or v.phase == 'finished') and C.summary(v.summary)
    end
    if not C.identity(v.session) or not number(v.requestId, 1, 2147483647, true) then return false end
    if action == 'mutationError' then return text(v.code, 64) and text(v.message, 512) end
    if action == 'mutationAccepted' then return true end
    if not number(v.raidId, 1, 2147483647, true) then return false end
    if action == 'mutationPreview' then
        return C.identity(v.token) and v.token ~= '0' and number(v.expires, 0, 9007199254740991, true) and
            type(v.joining) == 'boolean' and C.summary(v.summary)
    end
    if action ~= 'mutationCatalog' or not hash(v.catalogHash, true) or not number(v.maximumSelections, 0, C.maxSelection, true) then return false end
    local definitions = {}
    if not array(v.mutations, C.maxMutations, function(m)
        if type(m) ~= 'table' or not id(m.id) or definitions[m.id] or not text(m.name, 128) or
            not text(m.description, 2048) or not text(m.reason, 512, true) or type(m.available) ~= 'boolean' or type(m.requiresCrystal) ~= 'boolean' or
            not uniqueIds(m.conflicts, C.maxMutations) then return false end
        definitions[m.id] = m
        return true
    end) then return false end
    for _, m in ipairs(v.mutations) do
        for _, conflict in ipairs(m.conflicts) do if not definitions[conflict] then return false end end
    end
    if v.lobby ~= nil then
        if type(v.lobby) ~= 'table' or not number(v.lobby.channel, 1, 65535, true) or not C.identity(v.lobby.generation) or
            not uniqueIds(v.lobby.ids, C.maxSelection) then return false end
        for _, selected in ipairs(v.lobby.ids) do if not definitions[selected] then return false end end
    end
    return true
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
