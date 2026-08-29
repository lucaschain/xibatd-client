local TURRET_OPCODE = modules.game_xibat_core.XibatOpcode.Turret
local PROTOCOL_VERSION = 2
local MAX_STAT_VALUE = 1000000000
local MAX_REQUEST_ID = 2147483647
local MAX_UINT32 = 4294967295

local resultMessages = {
    invalid_state = 'That turret is no longer available.',
    max_level = 'That turret is already at maximum level.',
    not_enough_soul = 'You do not have enough soul.',
    not_owner = 'You no longer own that turret.',
    out_of_range = 'Move closer to manage that turret.',
    stale_revision = 'The turret changed. Inspect it again before retrying.',
    mutation_failed = 'The turret could not be changed.',
}

turretInspectorController = Controller:new()
turretInspectorController:setUI('turret_inspector')

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function isNumberInRange(value, minimum, maximum)
    return isFiniteNumber(value) and value >= minimum and value <= maximum
end

local function isIntegerInRange(value, minimum, maximum)
    return isNumberInRange(value, minimum, maximum) and value == math.floor(value)
end

local function isBoundedText(value, maximum, allowEmpty)
    return type(value) == 'string' and #value <= maximum and (allowEmpty or value ~= '') and
        not value:find('%c')
end

local function hasExactFields(value, required, optional)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do
        if not required[field] and not (optional and optional[field]) then return false end
    end
    for field in pairs(required) do
        if value[field] == nil then return false end
    end
    return true
end

local function isDenseArray(value, maximum)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 then return false end
        count = count + 1
    end
    if count > maximum then return false end
    for index = 1, count do
        if value[index] == nil then return false end
    end
    return true
end

local envelopeFields = { version = true, action = true, body = true }
local positionFields = { x = true, y = true, z = true }
local projectionEntryFields = { token = true, position = true, stateRevision = true }
local projectionEntryOptionalFields = { nextUpgradeCost = true }
local inspectorFields = {
    token = true, position = true, stateRevision = true, name = true, itemId = true,
    currentLevel = true, nextLevel = true, currentAttackSpeed = true, nextAttackSpeed = true,
    currentRange = true, nextRange = true, sellPrice = true, currentDamageMin = true,
    nextDamageMin = true, currentDamageMax = true, nextDamageMax = true,
}
local inspectorOptionalFields = { nextUpgradeCost = true }
local mutationFields = {
    operation = true, requestId = true, token = true, stateRevision = true, ok = true, code = true,
}

local function validatePosition(position)
    return hasExactFields(position, positionFields) and
        isIntegerInRange(position.x, 0, 65535) and isIntegerInRange(position.y, 0, 65535) and
        isIntegerInRange(position.z, 0, 15)
end

local function validateToken(token)
    return isBoundedText(token, 128, false)
end

local function validateNullableCost(cost)
    return cost == nil or isIntegerInRange(cost, 0, MAX_UINT32)
end

local function validateProjectionEntry(entry)
    return hasExactFields(entry, projectionEntryFields, projectionEntryOptionalFields) and
        validateToken(entry.token) and validatePosition(entry.position) and
        isIntegerInRange(entry.stateRevision, 1, MAX_REQUEST_ID) and
        validateNullableCost(entry.nextUpgradeCost)
end

local function validateProjectionEntries(entries, maximum)
    if not isDenseArray(entries, maximum) then return nil end
    local validated = {}
    for _, entry in ipairs(entries) do
        if not validateProjectionEntry(entry) or validated[entry.token] then return nil end
        validated[entry.token] = entry
    end
    return validated
end

local function validateInspector(payload)
    if not hasExactFields(payload, envelopeFields) or payload.version ~= PROTOCOL_VERSION or
        payload.action ~= 'openInspector' or
        not hasExactFields(payload.body, inspectorFields, inspectorOptionalFields) then return nil end
    local body = payload.body
    if not validateToken(body.token) or not validatePosition(body.position) or
        not isIntegerInRange(body.stateRevision, 1, MAX_REQUEST_ID) or
        not isBoundedText(body.name, 64, false) or not isIntegerInRange(body.itemId, 1, 65535) or
        not isIntegerInRange(body.currentLevel, 1, 100) or
        not isIntegerInRange(body.nextLevel, body.currentLevel, body.currentLevel + 1) or
        not validateNullableCost(body.nextUpgradeCost) or
        not isNumberInRange(body.currentAttackSpeed, 0, MAX_STAT_VALUE) or
        not isNumberInRange(body.nextAttackSpeed, 0, MAX_STAT_VALUE) or
        not isIntegerInRange(body.currentRange, 0, 100) or not isIntegerInRange(body.nextRange, 0, 100) or
        not isNumberInRange(body.sellPrice, 0, MAX_UINT32) or
        not isNumberInRange(body.currentDamageMin, 0, MAX_STAT_VALUE) or
        not isNumberInRange(body.nextDamageMin, 0, MAX_STAT_VALUE) or
        not isNumberInRange(body.currentDamageMax, body.currentDamageMin, MAX_STAT_VALUE) or
        not isNumberInRange(body.nextDamageMax, body.nextDamageMin, MAX_STAT_VALUE) then return nil end
    if (body.currentLevel == body.nextLevel) ~= (body.nextUpgradeCost == nil) then return nil end
    return body
end

local function validateProjection(payload)
    if not hasExactFields(payload, envelopeFields) or payload.version ~= PROTOCOL_VERSION or
        payload.action ~= 'upgradeProjection' or type(payload.body) ~= 'table' then return nil end
    local body = payload.body
    if body.mode == 'full' then
        if not hasExactFields(body, { mode = true, revision = true, entries = true }) or
            not isIntegerInRange(body.revision, 1, MAX_REQUEST_ID) then return nil end
        local entries = validateProjectionEntries(body.entries, 512)
        return entries and { mode = body.mode, revision = body.revision, entries = entries } or nil
    end
    if body.mode == 'delta' then
        if not hasExactFields(body, {
            mode = true, baseRevision = true, revision = true, upsert = true, remove = true,
        }) or not isIntegerInRange(body.baseRevision, 1, MAX_REQUEST_ID) or
            not isIntegerInRange(body.revision, body.baseRevision + 1, MAX_REQUEST_ID) then return nil end
        local upsert = validateProjectionEntries(body.upsert, 128)
        if not upsert or not isDenseArray(body.remove, 128) then return nil end
        local remove = {}
        for _, token in ipairs(body.remove) do
            if not validateToken(token) or remove[token] or upsert[token] then return nil end
            remove[token] = true
        end
        return { mode = body.mode, baseRevision = body.baseRevision, revision = body.revision,
            upsert = upsert, remove = remove }
    end
    return nil
end

local function validateMutationResult(payload)
    if not hasExactFields(payload, envelopeFields) or payload.version ~= PROTOCOL_VERSION or
        payload.action ~= 'mutationResult' or not hasExactFields(payload.body, mutationFields) then return nil end
    local body = payload.body
    if (body.operation ~= 'upgrade' and body.operation ~= 'sell') or
        not isIntegerInRange(body.requestId, 1, MAX_REQUEST_ID) or not validateToken(body.token) or
        not isIntegerInRange(body.stateRevision, 1, MAX_REQUEST_ID) or type(body.ok) ~= 'boolean' or
        not isBoundedText(body.code, 64, false) or (body.ok and body.code ~= 'ok') then return nil end
    return body
end

local function formatDamage(minimum, maximum)
    return string.format('%d - %d', math.floor(minimum), math.floor(maximum))
end

local function currentSoul()
    local player = g_game.getLocalPlayer()
    return player and player:getSoul() or 0
end

function turretInspectorController:destroyPrompt()
    if self.sellPrompt then
        self.sellPrompt:destroy()
        self.sellPrompt = nil
    end
end

function turretInspectorController:removeIndicator(token)
    local attached = self.indicators[token]
    if not attached then return end
    self.indicators[token] = nil
    if attached.widget and not attached.widget:isDestroyed() then
        if attached.tile then attached.tile:detachWidget(attached.widget) end
        attached.widget:destroy()
    end
end

function turretInspectorController:clearIndicators()
    local tokens = {}
    for token in pairs(self.indicators or {}) do table.insert(tokens, token) end
    for _, token in ipairs(tokens) do self:removeIndicator(token) end
end

function turretInspectorController:reconcileIndicators()
    if not self.gameReady then
        self:clearIndicators()
        return
    end
    local soul = currentSoul()
    local retained = {}
    for token, entry in pairs(self.projectionEntries) do
        if entry.nextUpgradeCost ~= nil and soul >= entry.nextUpgradeCost then
            local tile = g_map.getTile(entry.position)
            if tile then
                local attached = self.indicators[token]
                if attached and attached.tile == tile and attached.widget and not attached.widget:isDestroyed() then
                    retained[token] = true
                else
                    self:removeIndicator(token)
                    local badge = g_ui.createWidget('XibatTurretUpgradeBadge')
                    badge:setId('xibatTurretUpgradeBadge')
                    badge:setPhantom(true)
                    badge:setFocusable(false)
                    badge:setDraggable(false)
                    tile:attachWidget(badge)
                    self.indicators[token] = { tile = tile, widget = badge }
                    retained[token] = true
                end
            end
        end
    end
    local removed = {}
    for token in pairs(self.indicators) do
        if not retained[token] then table.insert(removed, token) end
    end
    for _, token in ipairs(removed) do self:removeIndicator(token) end
end

function turretInspectorController:refreshControls()
    local details = self.currentDetails
    if not details or not self.ui then return end
    local soul = currentSoul()
    local isMaximum = details.nextUpgradeCost == nil
    local pending = self.pendingRequest ~= nil
    self.ui.soulBalance:setText(tr('Available soul: %d', soul))
    self.ui.upgradeButton:setEnabled(not pending and not isMaximum and soul >= (details.nextUpgradeCost or 0))
    self.ui.upgradeButton:setText(pending and self.pendingRequest.operation == 'upgrade' and tr('Upgrading...') or
        isMaximum and tr('Maximum Level') or tr('Upgrade (-%d)', details.nextUpgradeCost))
    self.ui.upgradeButton:setTooltip(not pending and not isMaximum and soul < details.nextUpgradeCost and
        tr('Not enough soul.') or '')
    self.ui.sellButton:setEnabled(not pending)
    self.ui.sellButton:setText(pending and self.pendingRequest.operation == 'sell' and tr('Selling...') or
        tr('Sell (+%g)', details.sellPrice))
end

function turretInspectorController:close()
    self:destroyPrompt()
    self.pendingRequest = nil
    self.currentDetails = nil
    if self.ui then self.ui:hide() end
end

function turretInspectorController:sendAction(operation, token, stateRevision)
    local details = self.currentDetails
    if self.pendingRequest or not details or details.token ~= token or details.stateRevision ~= stateRevision then return end
    local protocol = g_game.getProtocolGame()
    if not protocol then return end
    self.nextRequestId = self.nextRequestId + 1
    if self.nextRequestId > MAX_REQUEST_ID then self.nextRequestId = 1 end
    self.pendingRequest = {
        operation = operation, requestId = self.nextRequestId, token = token, stateRevision = stateRevision,
    }
    self.ui.statusMessage:setText(tr('Waiting for the server...'))
    self:refreshControls()
    protocol:sendExtendedJSONOpcode(TURRET_OPCODE, {
        version = PROTOCOL_VERSION,
        action = operation,
        body = { requestId = self.nextRequestId, token = token, expectedStateRevision = stateRevision },
    })
end

function turretInspectorController:confirmSell()
    local details = self.currentDetails
    if not details or self.pendingRequest then return end
    self:destroyPrompt()
    local token, stateRevision = details.token, details.stateRevision
    local function cancel() self:destroyPrompt() end
    local function confirm()
        self:destroyPrompt()
        self:sendAction('sell', token, stateRevision)
    end
    self.sellPrompt = displayGeneralBox(tr('Sell Turret'),
        tr('Dismantle %s for %g soul?', details.name, details.sellPrice), {
            { text = tr('Sell'), callback = confirm },
            { text = tr('Cancel'), callback = cancel },
        }, confirm, cancel)
end

function turretInspectorController:open(details)
    if self.pendingRequest then return end
    self:destroyPrompt()
    self.currentDetails = details
    local isMaximum = details.nextUpgradeCost == nil
    local stats = self.statWidgets
    self.ui.name:setText(details.name)
    self.ui.levelBadge:setText(string.format('LEVEL %d', details.currentLevel))
    stats.levelCurrent:setText(tostring(details.currentLevel))
    stats.damageCurrent:setText(formatDamage(details.currentDamageMin, details.currentDamageMax))
    stats.speedCurrent:setText(string.format('%.2f/s', details.currentAttackSpeed))
    stats.rangeCurrent:setText(tostring(details.currentRange))
    if isMaximum then
        stats.levelNext:setText(tr('MAX'))
        stats.damageNext:setText('-')
        stats.speedNext:setText('-')
        stats.rangeNext:setText('-')
    else
        stats.levelNext:setText(string.format('%d (%+d)', details.nextLevel, details.nextLevel - details.currentLevel))
        stats.damageNext:setText(string.format('%s (%+d / %+d)',
            formatDamage(details.nextDamageMin, details.nextDamageMax),
            math.floor(details.nextDamageMin) - math.floor(details.currentDamageMin),
            math.floor(details.nextDamageMax) - math.floor(details.currentDamageMax)))
        stats.speedNext:setText(string.format('%.2f/s (%+.2f)', details.nextAttackSpeed,
            details.nextAttackSpeed - details.currentAttackSpeed))
        stats.rangeNext:setText(string.format('%d (%+d)', details.nextRange, details.nextRange - details.currentRange))
    end
    self.ui.statusMessage:setText(tr('Ready'))
    local token, stateRevision = details.token, details.stateRevision
    self.ui.upgradeButton.onClick = function() self:sendAction('upgrade', token, stateRevision) end
    self.ui.sellButton.onClick = function() self:confirmSell() end
    self:refreshControls()
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function turretInspectorController:applyProjection(projection)
    if projection.mode == 'full' then
        if self.projectionRevision and projection.revision <= self.projectionRevision then return end
        self.projectionEntries = projection.entries
        self.projectionRevision = projection.revision
    else
        if self.projectionRevision ~= projection.baseRevision then
            self:sendSync()
            return
        end
        for token in pairs(projection.remove) do self.projectionEntries[token] = nil end
        for token, entry in pairs(projection.upsert) do self.projectionEntries[token] = entry end
        self.projectionRevision = projection.revision
    end
    self:reconcileIndicators()
end

function turretInspectorController:handleMutationResult(result)
    local pending = self.pendingRequest
    if not pending or pending.operation ~= result.operation or pending.requestId ~= result.requestId or
        pending.token ~= result.token then return end
    self.pendingRequest = nil
    if result.ok then
        self:close()
        return
    end
    if not self.currentDetails then return end
    self.ui.statusMessage:setText(tr(resultMessages[result.code] or 'The server rejected that change.'))
    self:refreshControls()
end

function turretInspectorController:onTurretOpcode(_, _, payload)
    local inspector = validateInspector(payload)
    if inspector then self:open(inspector) return end
    local projection = validateProjection(payload)
    if projection then self:applyProjection(projection) return end
    local result = validateMutationResult(payload)
    if result then self:handleMutationResult(result) end
end

function turretInspectorController:sendSync()
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedJSONOpcode(TURRET_OPCODE, { version = PROTOCOL_VERSION, action = 'sync' })
    end
end

function turretInspectorController:onSoulChange()
    self:refreshControls()
    self:reconcileIndicators()
end

function turretInspectorController:onMapDescription()
    self:reconcileIndicators()
end

function turretInspectorController:resetRuntime()
    self:close()
    self:clearIndicators()
    self.projectionEntries = {}
    self.projectionRevision = nil
end

function turretInspectorController:onInit()
    self.nextRequestId = 0
    self.indicators = {}
    self.projectionEntries = {}
    self.gameReady = false
    self.statWidgets = {}
    for _, id in ipairs({
        'levelCurrent', 'damageCurrent', 'speedCurrent', 'rangeCurrent',
        'levelNext', 'damageNext', 'speedNext', 'rangeNext',
    }) do
        self.statWidgets[id] = assert(self.ui:recursiveGetChildById(id),
            string.format('Missing turret inspector widget: %s', id))
    end
    self.ui:hide()
    self:registerExtendedJSONOpcode(TURRET_OPCODE, function(...) self:onTurretOpcode(...) end)
    self:registerEvents(LocalPlayer, { onSoulChange = function() self:onSoulChange() end })
    self:registerEvents(g_game, {
        onMapKnown = function() self:onMapDescription() end,
        onMapDescription = function() self:onMapDescription() end,
    })
end

function turretInspectorController:onGameStart()
    self:resetRuntime()
    self.gameReady = true
    self:sendSync()
end

function turretInspectorController:onGameEnd()
    self.gameReady = false
    self:resetRuntime()
end

function turretInspectorController:onTerminate()
    self.gameReady = false
    self:resetRuntime()
end
