-- Offline synthetic packets in an isolated native Windows profile. No login/database.
local finished = false
local errors = {}
local function finish(reason)
    if finished then return end
    finished = true
    if reason then errors[#errors + 1] = tostring(reason) end
    g_resources.writeFileContentsToWorkDir('mutation-smoke-result.json', json.encode({
        status = #errors == 0 and 'PASS' or 'FAIL', errors = errors, writeDir = g_resources.getWriteDir(),
    }))
    scheduleEvent(function() g_app.exit() end, 100)
end

scheduleEvent(function()
    local ok, err = pcall(function()
        g_window.resize({ width = 1280, height = 960 })
        modules.client_entergame.EnterGame.hide()
        local controller = assert(modules.game_xibat_raid.raidSelectorController)
        -- Synthetic packets arrive without a login; mirror Controller's GAME_INIT
        -- event ownership so normal selector timers can be cancelled on teardown.
        controller.currentTypeEvent = 2
        local raidId = 10
        controller:onRaidOpcode(nil, 207, { action = 'openRaidSelector', body = {
            availableRaids = 1, maxRaids = 1, timerReset = os.time() + 3600,
            mutations = { version = 1, session = '1' }, raidList = { {
                name = 'Glacio', description = 'Synthetic mutation UI fixture', raidId = raidId,
                available = true, wavesTotal = 9, wavesCompleted = 0, items = {}, tier = 'bronze', mode = 'survival',
            } },
        } })
        controller:openMutations()
        controller.mutationPending = { action = 'mutationCatalog', requestId = 1, raidId = raidId }
        controller:onMutationOpcode('mutationCatalog', { version = 1, session = '1', requestId = 1, raidId = raidId,
            catalogHash = string.rep('a', 64), maximumSelections = 2, mutations = {
                { id = 'fortified', name = 'Fortified', description = 'Enemies have more health.', available = true, reason = '', requiresCrystal = false, conflicts = {} },
                { id = 'fragile', name = 'Fragile Crystal', description = 'The crystal has less health.', available = true, reason = '', requiresCrystal = true, conflicts = {} },
            } })
        controller.mutationSelection = { fortified = true, fragile = true }
        controller:renderMutationChoices()
        local summary = { configurationHash = string.rep('b', 64), raidName = 'Glacio',
            selected = { { id = 'fortified', name = 'Fortified' }, { id = 'fragile', name = 'Fragile Crystal' } },
            effects = { { key = 'enemy_health_bps', factor = 1.25 }, { key = 'enemy_speed_bps', factor = 1 },
                { key = 'spawn_count_bps', factor = 1 }, { key = 'wave_time_bps', factor = 1 }, { key = 'crystal_health_bps', factor = 0.8 } },
            goldBonusBps = 1500, ascensionXpBonusBps = 2500, goldCapped = true, xpCapped = false,
            loot = { { id = 'coins', rolls = 2, entries = {
                { clientId = 3031, name = 'Gold coin', quantity = 101, chanceBps = 5000, noDrop = false },
                { clientId = 0, name = 'No drop', quantity = 0, chanceBps = 5000, noDrop = true },
            } } } }
        controller.mutationPending = { action = 'mutationPreview', requestId = 2, raidId = raidId }
        controller:onMutationOpcode('mutationPreview', { version = 1, session = '1', requestId = 2, raidId = raidId,
            token = '9007199254740993', expires = os.time() + 60, joining = false, summary = summary })
        scheduleEvent(function()
            local success, detail = pcall(function()
                local window = controller.mutationWindow
                assert(window:isVisible() and window.deployButton:isEnabled(), 'Preview controls did not render')
                assert(window:getParent() == g_ui.getRootWidget(), 'Mutation window is detached from the root')
                local p, rootSize = window:getPosition(), g_ui.getRootWidget():getSize()
                assert(p.x >= 0 and p.y >= 0 and p.x + window:getWidth() <= rootSize.width and
                    p.y + window:getHeight() <= rootSize.height, 'Mutation window is outside the viewport')
                assert(window.choices:getChildCount() == 2 and window.summary:getChildCount() > 5, 'Mutation rows are missing')
                assert(window.choices:getWidth() > 200 and window.summary:getWidth() > 200, 'Mutation columns collapsed')
                modules.client_entergame.EnterGame.hide()
                window:raise()
                window:focus()
                -- Screenshots read the rendered framebuffer, not pending widget changes.
                scheduleEvent(function() g_app.doScreenshot('raid-mutations.png') end, 150)
                scheduleEvent(function()
                    local pass, result = pcall(function()
                        controller:onMutationOpcode('mutationStatus', { version = 1, raidId = raidId,
                            runId = '9007199254740994', generation = '2', phase = 'active', summary = summary })
                        controller.mutationStatus.onClick()
                        assert(controller.mutationWindow:isVisible() and not controller.mutationWindow.deployButton:isEnabled(), 'Active configuration is not read-only')
                        controller:onMutationOpcode('mutationStatus', { version = 1, raidId = raidId,
                            runId = '9007199254740994', generation = '2', phase = 'clear' })
                        assert(not controller.mutationStatus:isVisible() and not controller.mutationWindow:isVisible(), 'Terminal UI did not clear')
                    end)
                    finish(not pass and result or nil)
                end, 500)
            end)
            if not success then finish(detail) end
        end, 700)
    end)
    if not ok then finish(err) end
end, 1500)
scheduleEvent(function() finish('Mutation UI smoke exceeded its deadline') end, 15000)
