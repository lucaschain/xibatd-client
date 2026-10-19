-- Shared synthetic v2 wire data for Lua lifecycle and native Windows UI tests.
return function()
    local keys = { 'enemy_health_bps', 'enemy_speed_bps', 'spawn_count_bps', 'wave_time_bps', 'crystal_health_bps' }
    local function factors(overrides, default)
        local result = {}
        for _, key in ipairs(keys) do result[#result + 1] = { key = key, bps = overrides[key] or default or 10000 } end
        return result
    end
    local function mutation(id, name, overrides, conflicts, crystal)
        return { id = id, name = name, description = name .. ' test definition.', requiresCrystal = crystal or false,
            excludedRaids = {}, conflicts = conflicts or {}, effects = factors(overrides), goldBonusBps = 1000,
            ascensionXpBonusBps = 1500, lootTable = 'supplies', lootRolls = 1 }
    end
    local catalog = { version = 2, catalogHash = string.rep('a', 64), maximumSelections = 3,
        maximumFactors = factors({}, 20000), goldCapBps = 1500, xpCapBps = 2500, excludedRaids = {5},
        mutations = {
            mutation('fortified', 'Fortified', { enemy_health_bps = 12500 }, {'haste'}),
            mutation('haste', 'Haste', { enemy_speed_bps = 11000 }),
            mutation('fragile', 'Fragile Crystal', { crystal_health_bps = 8000 }, {}, true),
        }, lootTables = { { id = 'supplies', entries = {
            { clientId = 3031, name = 'Gold coin', quantity = 101, chanceBps = 5000, noDrop = false },
            { clientId = 0, name = 'No drop', quantity = 0, chanceBps = 5000, noDrop = true },
        } } } }
    local offer = { version = 2, raidId = 10, revision = string.rep('b', 64), catalogHash = catalog.catalogHash,
        useCrystal = true, lobbyChannel = 0, lobbyGeneration = '0' }
    local raid = { raidId = 10, name = 'Glacio', description = 'Synthetic mutation UI fixture.', available = true,
        configurationRevision = offer.revision, wavesTotal = 9, wavesCompleted = 0, items = {}, tier = 'bronze', mode = 'survival' }
    return catalog, offer, { action = 'openRaidSelector', body = {
        mutationVersion = 2, availableRaids = 1, maxRaids = 1, timerReset = os.time() + 3600, raidList = {raid},
    } }
end
