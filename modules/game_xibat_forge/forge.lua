local FORGE_OPCODE = modules.game_xibat_core.XibatOpcode.Forge
local MAX_COSTS = 4
local REQUEST_TIMEOUT = 5000

local resultMessages = {
    branch_locked = 'Two upgrade branches are already active.',
    invalid_branch = 'That upgrade branch is no longer available.',
    invalid_state = 'The turret rune is no longer available.',
    material_remove_failed = 'The forge could not consume the required materials.',
    max_level = 'That branch is already at maximum level.',
    mutation_failed = 'The forge could not apply that change.',
    not_enough_material = 'You do not have enough material.',
    rune_update_failed = 'The turret rune could not be updated.',
}

xibatForgeController = Controller:new()
xibatForgeController:setUI('forge')

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function isIntegerInRange(value, minimum, maximum)
    return isFiniteNumber(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isBoundedText(value, maximum, allowEmpty)
    return type(value) == 'string' and #value <= maximum and (allowEmpty or value ~= '') and not value:find('%c')
end

local function hasExactFields(value, required, optional)
    if type(value) ~= 'table' then
        return false
    end
    for field in pairs(value) do
        if not required[field] and not (optional and optional[field]) then
            return false
        end
    end
    for field in pairs(required) do
        if value[field] == nil then
            return false
        end
    end
    return true
end

local resultFields = { operation = true, requestId = true, ok = true, code = true }
local costFields = { clientId = true, name = true, amount = true }
local nextUpgradeFields = { description = true, cost = true }
local branchFields = {
    branchId = true,
    name = true,
    turretClientId = true,
    unlocked = true,
    level = true,
    maxLevel = true,
}
local branchOptionalFields = { nextUpgrade = true }
local bodyFields = {
    name = true,
    turretId = true,
    turretClientId = true,
    currentLevel = true,
    maxActiveBranches = true,
    sessionActive = true,
    branches = true,
    result = true,
}

local function validateResult(result, allowOpen)
    if not hasExactFields(result, resultFields) or type(result.ok) ~= 'boolean' or not result.ok or
        result.code ~= 'ok' then
        return false
    end
    if result.operation == 'open' then
        return allowOpen and result.requestId == 0
    end
    return (result.operation == 'upgrade' or result.operation == 'reset') and
        isIntegerInRange(result.requestId, 1, 2147483647)
end

local function validateCost(cost)
    return hasExactFields(cost, costFields) and isIntegerInRange(cost.clientId, 1, 65535) and
        isBoundedText(cost.name, 128, false) and isIntegerInRange(cost.amount, 1, 65535)
end

local function validateBranch(branch)
    if not hasExactFields(branch, branchFields, branchOptionalFields) or
        not isIntegerInRange(branch.branchId, 1, 3) or not isBoundedText(branch.name, 64, false) or
        not isIntegerInRange(branch.turretClientId, 1, 65535) or type(branch.unlocked) ~= 'boolean' or
        not isIntegerInRange(branch.level, 0, 9) or not isIntegerInRange(branch.maxLevel, 1, 9) or
        branch.level > branch.maxLevel then
        return false
    end

    if branch.level == branch.maxLevel then
        return branch.nextUpgrade == nil
    end
    local nextUpgrade = branch.nextUpgrade
    if not hasExactFields(nextUpgrade, nextUpgradeFields) or
        not isBoundedText(nextUpgrade.description, 512, true) or type(nextUpgrade.cost) ~= 'table' or
        #nextUpgrade.cost < 1 or #nextUpgrade.cost > MAX_COSTS then
        return false
    end
    for _, cost in ipairs(nextUpgrade.cost) do
        if not validateCost(cost) then
            return false
        end
    end
    return true
end

local function validateSnapshot(payload)
    if not hasExactFields(payload, { action = true, body = true }) or payload.action ~= 'openForgeView' or
        not hasExactFields(payload.body, bodyFields) then
        return nil
    end

    local body = payload.body
    if not isBoundedText(body.name, 64, false) or not isIntegerInRange(body.turretId, 1, 2147483647) or
        not isIntegerInRange(body.turretClientId, 1, 65535) or not isIntegerInRange(body.currentLevel, 0, 999) or
        body.maxActiveBranches ~= 2 or type(body.sessionActive) ~= 'boolean' or
        type(body.branches) ~= 'table' or #body.branches ~= 3 or
        not validateResult(body.result, true) then
        return nil
    end

    local branches = {}
    local activeBranches = 0
    local encodedLevel = 0
    for _, branch in ipairs(body.branches) do
        if not validateBranch(branch) or branches[branch.branchId] then
            return nil
        end
        branches[branch.branchId] = branch
        if branch.level > 0 then
            activeBranches = activeBranches + 1
        end
        encodedLevel = encodedLevel + branch.level * math.pow(10, 3 - branch.branchId)
    end
    if not branches[1] or not branches[2] or not branches[3] or activeBranches > body.maxActiveBranches or
        encodedLevel ~= body.currentLevel then
        return nil
    end
    for branchId = 1, 3 do
        local expectedUnlocked = activeBranches < body.maxActiveBranches or branches[branchId].level > 0
        if branches[branchId].unlocked ~= expectedUnlocked then
            return nil
        end
    end
    body.branches = { branches[1], branches[2], branches[3] }
    return body
end

local function validateFailure(payload)
    if not hasExactFields(payload, { action = true, body = true }) or payload.action ~= 'forgeResult' or
        not hasExactFields(payload.body, resultFields) then
        return nil
    end
    local body = payload.body
    if (body.operation ~= 'upgrade' and body.operation ~= 'reset') or body.ok ~= false or
        not isIntegerInRange(body.requestId, 1, 2147483647) or not isBoundedText(body.code, 64, false) then
        return nil
    end
    return body
end

function xibatForgeController:destroyPrompt()
    if self.resetPrompt then
        self.resetPrompt:destroy()
        self.resetPrompt = nil
    end
end

function xibatForgeController:clearBranches()
    self.branchWidgets = {}
    if self.ui then
        self.ui.branches:destroyChildren()
    end
end

function xibatForgeController:close()
    self:destroyPrompt()
    if self.pendingEvent then
        self:removeEvent(self.pendingEvent)
        self.pendingEvent = nil
    end
    self.pendingRequest = nil
    self.snapshot = nil
    self:clearBranches()
    if self.ui then
        self.ui:hide()
    end
end

function xibatForgeController:setPending(operation, selectedBranch)
    self.pendingRequest = operation
    for _, entry in ipairs(self.branchWidgets) do
        entry.button:setEnabled(false)
        if entry.branch.branchId == selectedBranch then
            entry.button:setText(tr('Applying...'))
        end
    end
    self.ui.resetButton:setEnabled(false)
    self.ui.statusMessage:setText(tr('Waiting for the forge...'))
    local requestId = operation.requestId
    self.pendingEvent = self:scheduleEvent(function()
        self.pendingEvent = nil
        if self.pendingRequest and self.pendingRequest.requestId == requestId then
            self:close()
        end
    end, REQUEST_TIMEOUT, 'xibatForgeRequest')
end

function xibatForgeController:sendRequest(payload, selectedBranch)
    if self.pendingRequest or not self.snapshot or not self.snapshot.sessionActive then
        return
    end
    local protocol = g_game.getProtocolGame()
    if not protocol then
        return
    end
    self.nextRequestId = (self.nextRequestId or 0) + 1
    if self.nextRequestId > 2147483647 then
        self.nextRequestId = 1
    end
    payload.requestId = self.nextRequestId
    self:setPending({ operation = payload.action, requestId = payload.requestId }, selectedBranch)
    protocol:sendExtendedJSONOpcode(FORGE_OPCODE, payload)
end

function xibatForgeController:requestUpgrade(branchId)
    local snapshot = self.snapshot
    local branch = snapshot and snapshot.branches[branchId]
    if not branch or not branch.unlocked or not branch.nextUpgrade then
        return
    end
    self:sendRequest({
        action = 'upgrade',
        branchId = branchId,
        turretId = snapshot.turretId,
        currentLevel = snapshot.currentLevel,
    }, branchId)
end

function xibatForgeController:confirmReset()
    local snapshot = self.snapshot
    if not snapshot or not snapshot.sessionActive or snapshot.currentLevel == 0 or self.pendingRequest then
        return
    end
    self:destroyPrompt()
    local turretId = snapshot.turretId
    local currentLevel = snapshot.currentLevel
    local function cancel()
        self:destroyPrompt()
    end
    local function confirm()
        self:destroyPrompt()
        if self.snapshot and self.snapshot.turretId == turretId and self.snapshot.currentLevel == currentLevel then
            self:sendRequest({ action = 'reset', turretId = turretId, currentLevel = currentLevel })
        end
    end
    self.resetPrompt = displayGeneralBox(tr('Reset Turret Rune'),
        tr('Reset all branch levels on %s? Previously consumed materials will not be refunded.', snapshot.name), {
            { text = tr('Reset'), callback = confirm },
            { text = tr('Cancel'), callback = cancel },
        }, confirm, cancel)
end

function xibatForgeController:renderBranch(branch)
    local card = g_ui.createWidget('XibatForgeBranchCard', self.ui.branches)
    local costs = g_ui.createWidget('XibatForgeCosts', card)
    costs:setId('costs')
    local isMaximum = branch.level == branch.maxLevel
    local isActive = branch.level > 0
    card.branchId = branch.branchId
    card.preview:setItemId(branch.turretClientId)
    card.name:setText(branch.name)
    card.level:setText(tr('Level %d / %d', branch.level, branch.maxLevel))
    card.progress:setValue(branch.level / branch.maxLevel * 100, 0, 100)
    card.status:setText(isMaximum and tr('MAX') or isActive and tr('ACTIVE') or
        branch.unlocked and tr('AVAILABLE') or tr('LOCKED'))
    card:setOpacity(branch.unlocked and 1 or 0.55)

    if branch.nextUpgrade then
        card.description:setText(branch.nextUpgrade.description)
        card.description:setTooltip(branch.nextUpgrade.description)
        for _, cost in ipairs(branch.nextUpgrade.cost) do
            local item = g_ui.createWidget('XibatForgeCost', costs)
            item:setItemId(cost.clientId)
            item:setItemCount(cost.amount)
            item:setTooltip(tr('%s: %d required', cost.name, cost.amount))
        end
    else
        card.description:setText(tr('This branch is fully upgraded.'))
    end

    local canUpgrade = self.snapshot.sessionActive and branch.unlocked and branch.nextUpgrade ~= nil
    card.upgradeButton:setEnabled(canUpgrade)
    card.upgradeButton:setText(isMaximum and tr('Maximum Level') or not branch.unlocked and
        tr('Two Branch Limit') or tr('Upgrade to Level %d', branch.level + 1))
    if canUpgrade then
        card.upgradeButton.onClick = function()
            self:requestUpgrade(branch.branchId)
        end
    end
    table.insert(self.branchWidgets, { branch = branch, button = card.upgradeButton })
end

function xibatForgeController:open(snapshot)
    self:destroyPrompt()
    if self.pendingEvent then
        self:removeEvent(self.pendingEvent)
        self.pendingEvent = nil
    end
    self.pendingRequest = nil
    self.snapshot = snapshot
    self:clearBranches()

    local activeBranches = 0
    for _, branch in ipairs(snapshot.branches) do
        if branch.level > 0 then activeBranches = activeBranches + 1 end
    end
    self.ui.name:setText(snapshot.name)
    self.ui.preview:setItemId(snapshot.turretClientId)
    self.ui.branchSummary:setText(tr('%d / %d branches active', activeBranches, snapshot.maxActiveBranches))
    self.ui.levelSummary:setText(tr('Rune levels %d-%d-%d', snapshot.branches[1].level,
        snapshot.branches[2].level, snapshot.branches[3].level))
    self.ui.statusMessage:setText(not snapshot.sessionActive and
        tr('Change applied. Reopen the forge to continue.') or snapshot.result.operation == 'open' and
        tr('Choose up to two specialization branches.') or tr('Forge change applied.'))
    for _, branch in ipairs(snapshot.branches) do
        self:renderBranch(branch)
    end
    self.ui.resetButton:setEnabled(snapshot.sessionActive and snapshot.currentLevel > 0)
    self.ui.resetButton:setText(snapshot.currentLevel > 0 and tr('Reset Upgrades') or tr('No Upgrades to Reset'))
    self.ui.resetButton.onClick = function()
        self:confirmReset()
    end

    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function xibatForgeController:onForgeOpcode(_, _, payload)
    local snapshot = validateSnapshot(payload)
    if snapshot then
        local result = snapshot.result
        if result.operation ~= 'open' and (not self.pendingRequest or
            self.pendingRequest.operation ~= result.operation or self.pendingRequest.requestId ~= result.requestId) then
            return
        end
        self:open(snapshot)
        return
    end

    local failure = validateFailure(payload)
    if not failure then
        return
    end
    if not self.pendingRequest or self.pendingRequest.operation ~= failure.operation or
        self.pendingRequest.requestId ~= failure.requestId then
        return
    end
    if self.pendingEvent then
        self:removeEvent(self.pendingEvent)
        self.pendingEvent = nil
    end
    self.pendingRequest = nil
    if failure.code == 'session_invalid' then
        self:close()
        return
    end
    if not self.snapshot then
        return
    end
    self.ui.statusMessage:setText(tr(resultMessages[failure.code] or 'The forge rejected that change.'))
    for _, entry in ipairs(self.branchWidgets) do
        local branch = entry.branch
        entry.button:setEnabled(self.snapshot.sessionActive and branch.unlocked and branch.nextUpgrade ~= nil)
        entry.button:setText(branch.level == branch.maxLevel and tr('Maximum Level') or
            not branch.unlocked and tr('Two Branch Limit') or tr('Upgrade to Level %d', branch.level + 1))
    end
    self.ui.resetButton:setEnabled(self.snapshot.sessionActive and self.snapshot.currentLevel > 0)
end

function xibatForgeController:onInit()
    self.branchWidgets = {}
    self.nextRequestId = 0
    self:clearBranches()
    self.ui:hide()
    self:registerExtendedJSONOpcode(FORGE_OPCODE, function(...)
        self:onForgeOpcode(...)
    end)
end

function xibatForgeController:onGameStart()
    self:close()
end

function xibatForgeController:onGameEnd()
    self:close()
end

function xibatForgeController:onTerminate()
    self:close()
end
