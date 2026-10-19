local C = RaidMutationContract
local opcode = modules.game_xibat_core.XibatOpcode.RaidSelector

function raidSelectorController:initMutations()
    self.cachedRaidConfigurations, self.mutationSelections = {}, {}
    self.mutationWindow = g_ui.loadUI('raid_mutations', g_ui.getRootWidget())
    self.mutationStatus = g_ui.loadUI('raid_mutation_status', g_ui.getRootWidget())
    self.mutationWindow:hide()
    self.mutationStatus:hide()
    self.mutationWindow.closeButton.onClick = function() self:closeMutations() end
    self.mutationWindow.normalButton.onClick = function()
        if self.mutationView ~= 'selection' or self.deployPending or (self.mutationOffer and self.mutationOffer.lobbyChannel > 0) then return end
        self.mutationSelection = {}
        self.mutationSelections[self.selectedRaid.raidId] = self.mutationSelection
        self:renderMutationChoices()
        self:updateLocalMutationPreview()
    end
    self.mutationWindow.deployButton.onClick = function() self:deployConfiguredRaid() end
    self.mutationStatus.onClick = function()
        if not self.activeMutationStatus then return end
        self:closeMutations()
        self.mutationView = 'status'
        self.mutationWindow.heading:setText(self.activeMutationStatus.summary.raidName .. ' - ' .. self.activeMutationStatus.phase)
        self.mutationWindow.choices:destroyChildren()
        self.mutationWindow.notice:setText('Locked configuration for your current raid.')
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.normalButton:setEnabled(false)
        self:renderMutationSummary(self.activeMutationStatus.summary)
        self.mutationWindow:show()
        self.mutationWindow:raise()
        self.mutationWindow:focus()
    end
end

function raidSelectorController:closeMutations()
    self.localMutationPreview, self.deployPending, self.mutationView = nil, nil, nil
    if self.mutationWindow then self.mutationWindow:hide() end
end

function raidSelectorController:openMutations()
    self:closeMutations()
    self.mutationView = 'selection'
    self.mutationWindow.heading:setText(self.selectedRaid.name .. ' - mutations')
    self:loadLocalMutationConfiguration()
    self.mutationWindow:show()
    self.mutationWindow:raise()
    self.mutationWindow:focus()
end

function raidSelectorController:loadLocalMutationConfiguration()
    local raid = self.selectedRaid
    self.mutationOffer = self.mutationVersion and self.cachedRaidConfigurations[raid.raidId] or nil
    self.mutationCatalog = self.cachedMutationCatalog
    if self.mutationVersion and (not self.mutationOffer or self.mutationOffer.revision ~= raid.configurationRevision) then
        self.mutationWindow.choices:destroyChildren()
        self.mutationWindow.summary:destroyChildren()
        self.mutationWindow.notice:setText('Raid configuration is unavailable. Reopen the raid menu.')
        self.localMutationPreview = nil
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.normalButton:setEnabled(false)
        return
    end
    if self.mutationOffer and self.mutationOffer.lobbyChannel > 0 then
        self.mutationSelection = {}
        for _, selected in ipairs(self.mutationOffer.summary.selected) do self.mutationSelection[selected.id] = true end
    else
        local previous = self.mutationSelections[raid.raidId] or {}
        self.mutationSelection = {}
        if self.mutationOffer and self.mutationCatalog then
            for _, mutation in ipairs(self.mutationCatalog.mutations) do
                if previous[mutation.id] and not C.unavailable(self.mutationCatalog, self.mutationOffer, mutation) then self.mutationSelection[mutation.id] = true end
            end
        end
        self.mutationSelections[raid.raidId] = self.mutationSelection
    end
    self:renderMutationChoices()
    self:updateLocalMutationPreview()
end

function raidSelectorController:renderMutationSummary(summary)
    local panel = self.mutationWindow.summary
    panel:destroyChildren()
    local function section(title)
        g_ui.createWidget('XibatMutationSection', panel):setText(title)
    end
    local function stat(caption, value, icon, color, style)
        local row = g_ui.createWidget(style or 'XibatMutationStat', panel)
        row.caption:setText(caption)
        row.value:setText(value)
        row.value:setColor(color or '#f0bf83')
        if icon then row.icon:setImageSource('/images/icons/' .. icon) end
        row:setTooltip(caption .. ': ' .. value)
        return row
    end
    section('MUTATIONS  /  ' .. #summary.selected)
    if #summary.selected == 0 then
        stat('Normal raid', 'Standard', 'icon_shielding', '#9eafb9')
    end
    for _, selected in ipairs(summary.selected) do
        stat(selected.name, 'Active', 'icon-impactanalyser-widget', '#86c8b2')
    end
    local effects = {
        enemy_health_bps = {'Enemy health', 'icon_health'},
        enemy_speed_bps = {'Enemy speed', 'icon-progressanalyser-widget'},
        spawn_count_bps = {'Enemy count', 'icon_players'},
        wave_time_bps = {'Wave time', 'icon-huntingsessionanalyser-widget'},
        crystal_health_bps = {'Crystal health', 'icon_shielding'},
    }
    if #summary.selected > 0 then section('COMBINED DIFFICULTY') end
    for _, effect in ipairs(summary.effects) do
        if effect.factor ~= 1 then
            local meta = effects[effect.key]
            stat(meta[1], string.format('%+.0f%%', (effect.factor - 1) * 100), meta[2])
        end
    end
    section('REWARD BONUSES')
    stat('Gold', string.format('+%.2f%%', summary.goldBonusBps / 100), 'icon-balance', '#f4d08a')
        :setTooltip(summary.goldCapped and 'Gold bonus reached its cap.' or 'Bonus applies to eligible gold rewards.')
    stat('Ascension XP', string.format('+%.2f%%', summary.ascensionXpBonusBps / 100), 'icon_experience', '#86c8b2')
        :setTooltip(summary.xpCapped and 'Ascension XP bonus reached its cap.' or 'Bonus applies to eligible Ascension XP rewards.')
    for _, loot in ipairs(summary.loot) do
        section('COMPLETION LOOT  /  ' .. loot.rolls .. ' ROLL(S)')
        for _, entry in ipairs(loot.entries) do
            local chance = entry.chanceBps > 0 and entry.chanceBps < 1 and '<0.01%' or string.format('%.2f%%', entry.chanceBps / 100)
            local row = stat(entry.name .. (entry.noDrop and '' or (' x' .. entry.quantity)), chance, nil, '#9ac5df', 'XibatMutationLoot')
            if not entry.noDrop then row.item:setItemId(entry.clientId) end
            row:setTooltip(entry.name .. ': ' .. chance .. ' per independent roll. Requires a successful clear and final-wave eligibility.')
        end
    end
    local note = g_ui.createWidget('XibatMutationLine', panel)
    note:setText('Bonuses require eligible rewards. Completion drops are not guaranteed.')
end

function raidSelectorController:renderMutationChoices()
    self.mutationWindow.choices:destroyChildren()
    local catalog, offer, selected = self.mutationCatalog, self.mutationOffer, self.mutationSelection
    local locked = offer and offer.lobbyChannel > 0
    local definitions = locked and offer.summary.selected or (offer and catalog and catalog.mutations or {})
    local count = 0
    for _ in pairs(selected) do count = count + 1 end
    for _, m in ipairs(definitions) do
        local reason = not locked and C.unavailable(catalog, offer, m) or nil
        if not locked and not selected[m.id] then
            for _, other in ipairs(definitions) do
                if selected[other.id] then
                    for _, conflict in ipairs(m.conflicts) do if conflict == other.id then reason = 'Conflicts with ' .. other.name end end
                    for _, conflict in ipairs(other.conflicts) do if conflict == m.id then reason = 'Conflicts with ' .. other.name end end
                end
            end
            if count >= catalog.maximumSelections then reason = 'Selection limit reached.' end
        end
        local card = g_ui.createWidget('XibatMutationChoice', self.mutationWindow.choices)
        card:setText(m.name)
        card:setChecked(selected[m.id] == true)
        card:setTooltip(m.name .. (m.description and ('\n' .. m.description) or '') .. (reason and ('\n' .. reason) or ''))
        card:setEnabled(not self.deployPending and not locked and (selected[m.id] or not reason))
        card:setOpacity(selected[m.id] and 1 or (reason and 0.45 or 0.8))
        card.onCheckChange = function(widget, checked)
            if self.mutationView ~= 'selection' or self.mutationOffer ~= offer or self.mutationSelection ~= selected then return end
            if self.deployPending or locked or (reason and not selected[m.id]) then widget:setChecked(selected[m.id] == true) return end
            selected[m.id] = checked or nil
            self:renderMutationChoices()
            self:updateLocalMutationPreview()
        end
    end
    self.mutationWindow.normalButton:setEnabled(not locked and not self.deployPending)
    self.mutationWindow.deployButton:setText(locked and tr('Join party lobby') or tr('Deploy to raid'))
end

function raidSelectorController:updateLocalMutationPreview()
    local preview, error = C.preview(self.mutationCatalog, self.mutationOffer, self.selectedRaid.name, self.mutationSelection)
    self.localMutationPreview = preview
    self.mutationWindow.deployButton:setEnabled(preview ~= nil and not self.deployPending)
    if not preview then self.mutationWindow.notice:setText(error) return end
    self:renderMutationSummary(preview)
    self.mutationWindow.notice:setText(self.mutationOffer and self.mutationOffer.lobbyChannel > 0 and
        'Party lobby: the shown configuration is locked.' or 'Choose your settings, then Deploy. Settings are checked when you deploy.')
end

function raidSelectorController:deployConfiguredRaid()
    if self.mutationView ~= 'selection' or self.deployPending or not self.localMutationPreview or not self.selectedRaid then return end
    local protocol = g_game.getProtocolGame()
    if not protocol then return end
    local raid = self.selectedRaid
    if not self.mutationVersion then
        protocol:sendExtendedJSONOpcode(opcode, { action = 'startRaid', body = { raidId = raid.raidId } })
        self:close()
        return
    end
    self.mutationRequestId = (self.mutationRequestId or 0) % 2147483647 + 1
    local offer = self.mutationOffer
    local selected = {}
    for _, entry in ipairs(self.localMutationPreview.selected) do table.insert(selected, entry.id) end
    self.deployPending = { requestId = self.mutationRequestId, raidId = raid.raidId }
    self:renderMutationChoices()
    self.mutationWindow.deployButton:setEnabled(false)
    self.mutationWindow.notice:setText('Deploying...')
    self.ui:hide()
    protocol:sendExtendedJSONOpcode(opcode, { action = 'deployRaid', body = {
        version = C.version, requestId = self.mutationRequestId, raidId = raid.raidId, ids = selected,
        revision = offer.revision, catalogHash = offer.catalogHash, lobbyChannel = offer.lobbyChannel, lobbyGeneration = offer.lobbyGeneration,
    } })
end

function raidSelectorController:onMutationOpcode(action, body)
    if not C.response(action, body) then return end
    if action == 'mutationCatalog' then self.cachedMutationCatalog = body return end
    if action == 'raidConfiguration' then self.cachedRaidConfigurations[body.raidId] = body return end
    if action == 'mutationStatus' then
        local old = self.activeMutationStatus
        if body.phase == 'clear' then
            if old and old.raidId == body.raidId and old.runId == body.runId and old.generation == body.generation then
                self.activeMutationStatus = nil
                self.mutationStatus:hide()
                if self.mutationView == 'status' then self:closeMutations() end
            end
            return
        end
        self.activeMutationStatus = body
        self.mutationStatus:setText(string.format('%s - %d mutation(s) [%s]', body.summary.raidName, #body.summary.selected, body.phase))
        self.mutationStatus:setTooltip('Click to inspect your locked raid configuration.')
        self.mutationStatus:show()
        if self.mutationView == 'status' then
            self.mutationWindow.heading:setText(body.summary.raidName .. ' - ' .. body.phase)
            self:renderMutationSummary(body.summary)
        end
        return
    end
    local pending = self.deployPending
    if not pending or body.requestId ~= pending.requestId or body.raidId ~= pending.raidId then return end
    self.deployPending = nil
    if action == 'raidDeployed' then self:close() return end
    -- The server pushes updated data before a rejection. Preserve valid local
    -- choices and require another explicit Deploy, never an automatic retry.
    local updated = self.cachedRaidConfigurations[body.raidId]
    if updated then self.selectedRaid.configurationRevision = updated.revision end
    self:loadLocalMutationConfiguration()
    self.mutationWindow.notice:setText(body.message)
end
