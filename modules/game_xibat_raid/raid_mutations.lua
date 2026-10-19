local C = RaidMutationContract
local opcode = modules.game_xibat_core.XibatOpcode.RaidSelector

function raidSelectorController:initMutations()
    self.mutationWindow = g_ui.loadUI('raid_mutations', g_ui.getRootWidget())
    self.mutationStatus = g_ui.loadUI('raid_mutation_status', g_ui.getRootWidget())
    self.mutationWindow:hide()
    self.mutationStatus:hide()
    self.mutationWindow.closeButton.onClick = function() self:closeMutations() end
    self.mutationWindow.refreshButton.onClick = function() self:requestMutationCatalog() end
    self.mutationWindow.normalButton.onClick = function()
        if self.mutationCatalog and not self.mutationCatalog.lobby and not self.acceptPending then
            self.mutationSelection = {}
            self:renderMutationChoices()
            self:requestMutationPreview()
        end
    end
    self.mutationWindow.deployButton.onClick = function() self:confirmMutations() end
    self.mutationStatus.onClick = function()
        if not self.activeMutationStatus then return end
        self:closeMutations()
        self.mutationView = 'status'
        self.mutationWindow.heading:setText(self.activeMutationStatus.summary.raidName .. ' - ' .. self.activeMutationStatus.phase)
        self.mutationWindow.choices:destroyChildren()
        self.mutationWindow.notice:setText('Locked configuration for your current raid.')
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.refreshButton:setEnabled(false)
        self.mutationWindow.normalButton:setEnabled(false)
        self:renderMutationSummary(self.activeMutationStatus.summary)
        self.mutationWindow:show()
        self.mutationWindow:raise()
        self.mutationWindow:focus()
    end
end

function raidSelectorController:closeMutations()
    self:destroyPrompt()
    self.mutationPreview = nil
    self.mutationPending = nil
    self.acceptPending = false
    self.mutationView = nil
    if self.mutationWindow then self.mutationWindow:hide() end
end

function raidSelectorController:sendMutationRequest(action, body)
    local protocol = g_game.getProtocolGame()
    if not protocol or not self.mutationSession then return end
    self.mutationRequestId = (self.mutationRequestId or 0) % 2147483647 + 1
    body.version, body.session, body.requestId = C.version, self.mutationSession, self.mutationRequestId
    self.mutationPending = { action = action, requestId = body.requestId, raidId = self.selectedRaid.raidId }
    protocol:sendExtendedJSONOpcode(opcode, { action = action, body = body })
end

function raidSelectorController:openMutations()
    self:closeMutations()
    self.mutationView = 'selection'
    self.mutationWindow.heading:setText(self.selectedRaid.name .. ' - mutations')
    self.mutationWindow:show()
    self.mutationWindow:raise()
    self.mutationWindow:focus()
    self:requestMutationCatalog()
end

function raidSelectorController:requestMutationCatalog()
    if self.mutationView ~= 'selection' or not self.selectedRaid or self.acceptPending then return end
    self:destroyPrompt()
    self.mutationPreview, self.mutationCatalog = nil, nil
    self.mutationWindow.choices:destroyChildren()
    self.mutationWindow.summary:destroyChildren()
    self.mutationWindow.notice:setText('Loading available mutations...')
    self.mutationWindow.deployButton:setEnabled(false)
    self.mutationWindow.normalButton:setEnabled(false)
    self.mutationWindow.refreshButton:setEnabled(true)
    self:sendMutationRequest('mutationCatalog', { raidId = self.selectedRaid.raidId })
end

function raidSelectorController:renderMutationSummary(summary)
    self.mutationWindow.summary:destroyChildren()
    for _, line in ipairs(C.lines(summary)) do
        local label = g_ui.createWidget('XibatMutationLine', self.mutationWindow.summary)
        label:setText(line)
        label:setHeight(#line > 80 and 64 or (#line > 40 and 40 or 24))
    end
end

function raidSelectorController:renderMutationChoices()
    local catalog = self.mutationCatalog
    self.mutationWindow.choices:destroyChildren()
    local selected, count = self.mutationSelection, 0
    for _ in pairs(selected) do count = count + 1 end
    for _, m in ipairs(catalog.mutations) do
        local reason = not m.available and m.reason or nil
        if not selected[m.id] then
            for _, other in ipairs(catalog.mutations) do
                if selected[other.id] then
                    for _, conflict in ipairs(m.conflicts) do if conflict == other.id then reason = 'Conflicts with ' .. other.name end end
                    for _, conflict in ipairs(other.conflicts) do if conflict == m.id then reason = 'Conflicts with ' .. other.name end end
                end
            end
            if count >= catalog.maximumSelections then reason = 'Selection limit reached.' end
        end
        local card = g_ui.createWidget('XibatMutationChoice', self.mutationWindow.choices)
        card:setText((selected[m.id] and '[x] ' or '[ ] ') .. m.name)
        card:setTooltip(m.description .. (m.requiresCrystal and '\nRequires a crystal raid.' or '') .. (reason and ('\n' .. reason) or ''))
        card:setEnabled(not self.acceptPending and not catalog.lobby and (selected[m.id] or not reason))
        card:setOpacity(selected[m.id] and 1 or (reason and 0.45 or 0.8))
        card.onClick = function()
            if self.acceptPending or catalog.lobby or (reason and not selected[m.id]) then return end
            selected[m.id] = not selected[m.id] or nil
            self:renderMutationChoices()
            self:requestMutationPreview()
        end
    end
    self.mutationWindow.normalButton:setEnabled(not catalog.lobby and not self.acceptPending)
    self.mutationWindow.deployButton:setText(catalog.lobby and tr('Join party lobby') or tr('Deploy to raid'))
end

function raidSelectorController:requestMutationPreview()
    local catalog = self.mutationCatalog
    if not catalog or self.acceptPending then return end
    self:destroyPrompt()
    self.mutationPreview = nil
    self.mutationWindow.summary:destroyChildren()
    self.mutationWindow.deployButton:setEnabled(false)
    self.mutationWindow.notice:setText(catalog.lobby and 'Reviewing the locked party configuration...' or 'Calculating challenge and rewards...')
    local selected = {}
    for id in pairs(self.mutationSelection) do table.insert(selected, id) end
    table.sort(selected)
    self:sendMutationRequest('mutationPreview', { raidId = self.selectedRaid.raidId, catalogHash = catalog.catalogHash,
        ids = selected, lobbyChannel = catalog.lobby and catalog.lobby.channel or 0,
        lobbyGeneration = catalog.lobby and catalog.lobby.generation or '0' })
end

function raidSelectorController:updateMutationExpiry()
    if self.mutationPreview and self.mutationPreview.expires <= os.time() then
        self.mutationPreview = nil
        self:destroyPrompt()
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.notice:setText('Preview expired. Open the raid selector again to refresh it.')
    end
end

function raidSelectorController:confirmMutations()
    self:updateMutationExpiry()
    local preview, session = self.mutationPreview, self.mutationSession
    if not preview or self.acceptPending then return end
    self:destroyPrompt()
    local function confirm()
        if self.mutationPreview ~= preview or self.mutationSession ~= session or preview.expires <= os.time() or self.acceptPending then return end
        self:destroyPrompt()
        self.acceptPending = true
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.refreshButton:setEnabled(false)
        self:renderMutationChoices()
        self.ui:hide()
        self.mutationWindow.notice:setText('Waiting for raid admission...')
        self:sendMutationRequest('mutationAccept', { token = preview.token })
    end
    local function cancel() self:destroyPrompt() end
    self.startPrompt = displayGeneralBox(preview.joining and tr('Join party lobby') or tr('Deploy to raid'),
        string.format('%s %s with %d mutation(s)?\nGold +%.2f%%; Ascension XP +%.2f%%.\nCompletion loot requires a successful clear.',
            preview.joining and 'Join' or 'Enter', preview.summary.raidName, #preview.summary.selected,
            preview.summary.goldBonusBps / 100, preview.summary.ascensionXpBonusBps / 100),
        { { text = tr('Confirm'), callback = confirm }, { text = tr('Cancel'), callback = cancel } }, confirm, cancel)
end

function raidSelectorController:onMutationOpcode(action, body)
    if not C.response(action, body) then return end
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
    local pending = self.mutationPending
    if not pending or body.session ~= self.mutationSession or body.requestId ~= pending.requestId or
        (body.raidId and body.raidId ~= pending.raidId) then return end
    if action ~= 'mutationError' and action ~= (pending.action == 'mutationAccept' and 'mutationAccepted' or pending.action) then return end
    self.mutationPending = nil
    if action == 'mutationError' then
        self.acceptPending, self.mutationPreview = false, nil
        self:destroyPrompt()
        self.mutationWindow.deployButton:setEnabled(false)
        self.mutationWindow.refreshButton:setEnabled(true)
        self.mutationWindow.notice:setText(body.message)
    elseif action == 'mutationAccepted' then
        self:close()
    elseif action == 'mutationCatalog' then
        self.mutationCatalog, self.mutationSelection = body, {}
        if body.lobby then for _, id in ipairs(body.lobby.ids) do self.mutationSelection[id] = true end end
        self:renderMutationChoices()
        self:requestMutationPreview()
    elseif action == 'mutationPreview' then
        self.mutationPreview = body
        self:renderMutationSummary(body.summary)
        self.mutationWindow.notice:setText(body.joining and 'Party lobby: the shown configuration is locked.' or
            (#self.mutationCatalog.mutations == 0 and 'No mutations are configured. Review the normal raid below.' or
                'Choose mutations, then confirm the shown challenge and rewards.'))
        self.mutationWindow.deployButton:setEnabled(true)
        self:updateMutationExpiry()
    end
end
