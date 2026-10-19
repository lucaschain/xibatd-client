-- Offline synthetic menu data in an isolated native Windows profile.
local finished = false
local function finish(reason)
    if finished then return end
    finished = true
    g_resources.writeFileContentsToWorkDir('mutation-smoke-result.json', json.encode({
        status = reason and 'FAIL' or 'PASS', errors = reason and {tostring(reason)} or {}, writeDir = g_resources.getWriteDir(),
    }))
    scheduleEvent(function() g_app.exit() end, 100)
end
scheduleEvent(function()
    local ok, err = pcall(function()
        g_window.resize({ width = 1280, height = 960 })
        modules.client_entergame.EnterGame.hide()
        local controller = assert(modules.game_xibat_raid.raidSelectorController)
        controller.currentTypeEvent = 2 -- Synthetic menu opened in the controller's gameplay scope.
        local catalog, offer, menu = dofile('/mutation-fixture.lua')()
        controller:onMutationOpcode('mutationCatalog', catalog)
        controller:onMutationOpcode('raidConfiguration', offer)
        controller:onRaidOpcode(nil, 207, menu)
        controller:configureRaid()
        local window = controller.mutationWindow
        assert(not window:getChildById('refreshButton'), 'Refresh button should not exist for local settings')
        local choice = window.choices:getChildren()[1]
        assert(choice:getClassName() == 'UICheckBox' and choice:getHeight() == 24, 'Choice is not a compact native checkbox')
        choice:setChecked(true)
        assert(not window.choices:getChildren()[2]:isEnabled(), 'Conflict is not shown locally')
        window.choices:getChildren()[3]:setChecked(true)
        assert(controller.localMutationPreview.goldBonusBps == 1500 and controller.localMutationPreview.xpCapped,
            'Local reward preview is incorrect')
        assert(not controller.deployPending and window.deployButton:isEnabled(), 'Toggling sent a deployment or left Deploy disabled')
        scheduleEvent(function()
            local pass, result = pcall(function()
                assert(window:isVisible() and window:getParent() == g_ui.getRootWidget(), 'Configuration window is detached')
                local p, rootSize = window:getPosition(), g_ui.getRootWidget():getSize()
                assert(p.x >= 0 and p.y >= 0 and p.x + window:getWidth() <= rootSize.width and
                    p.y + window:getHeight() <= rootSize.height, 'Configuration window is outside viewport')
                assert(window.summary:getChildCount() > 5 and window.summary:getWidth() > 200, 'Local summary did not render')
                for _, row in ipairs(window.summary:getChildren()) do
                    if row:getChildById('item') then
                        assert(row.caption:getPosition().y == row.value:getPosition().y and
                            row.caption:getHeight() == row.value:getHeight(), 'Loot name and probability are vertically misaligned')
                    end
                end
                modules.client_entergame.EnterGame.hide()
                window:raise(); window:focus()
                scheduleEvent(function() g_app.doScreenshot('raid-mutations.png') end, 150)
                scheduleEvent(function()
                    local success, detail = pcall(function()
                        local summary = controller.localMutationPreview
                        summary.configurationHash = string.rep('d', 64)
                        controller:onMutationOpcode('mutationStatus', { version = 2, raidId = offer.raidId,
                            runId = '9007199254740994', generation = '2', phase = 'active', summary = summary })
                        controller.mutationStatus.onClick()
                        assert(window:isVisible() and not window.deployButton:isEnabled(), 'Run configuration is editable')
                        controller:onMutationOpcode('mutationStatus', { version = 2, raidId = offer.raidId,
                            runId = '9007199254740994', generation = '2', phase = 'clear' })
                        assert(not controller.mutationStatus:isVisible() and not window:isVisible(), 'Terminal status did not clear')
                    end)
                    finish(not success and detail or nil)
                end, 500)
            end)
            if not pass then finish(result) end
        end, 700)
    end)
    if not ok then finish(err) end
end, 1500)
scheduleEvent(function() finish('Mutation UI smoke exceeded its deadline') end, 15000)
