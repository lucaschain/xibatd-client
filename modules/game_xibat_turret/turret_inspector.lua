local TURRET_OPCODE = modules.game_xibat_core.XibatOpcode.Turret
local MAX_STAT_VALUE = 1000000000

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

local function validateDetails(details)
    if type(details) ~= 'table' or type(details.name) ~= 'string' or details.name == '' or #details.name > 64 or
        details.name:find('%c') or
        type(details.key) ~= 'string' or #details.key > 64 or not details.key:match('^%d+,%d+,%d+$') or
        not isIntegerInRange(details.itemId, 1, 65535) or
        not isIntegerInRange(details.currentLevel, 1, 100) or
        not isIntegerInRange(details.nextLevel, details.currentLevel, details.currentLevel + 1) or
        not isNumberInRange(details.currentAttackSpeed, 0, MAX_STAT_VALUE) or
        not isNumberInRange(details.nextAttackSpeed, 0, MAX_STAT_VALUE) or
        not isNumberInRange(details.soulRequiredForUpgrade, 0, 65535) or
        not isIntegerInRange(details.currentRange, 0, 100) or
        not isIntegerInRange(details.nextRange, 0, 100) or
        not isNumberInRange(details.sellPrice, 0, 65535) or
        not isNumberInRange(details.currentDamageMin, 0, MAX_STAT_VALUE) or
        not isNumberInRange(details.nextDamageMin, 0, MAX_STAT_VALUE) or
        not isNumberInRange(details.currentDamageMax, details.currentDamageMin, MAX_STAT_VALUE) or
        not isNumberInRange(details.nextDamageMax, details.nextDamageMin, MAX_STAT_VALUE) then
        return false
    end
    return true
end

local function formatDamage(minimum, maximum)
    return string.format('%d - %d', math.floor(minimum), math.floor(maximum))
end

function turretInspectorController:destroyPrompt()
    if self.sellPrompt then
        self.sellPrompt:destroy()
        self.sellPrompt = nil
    end
end

function turretInspectorController:close()
    self:destroyPrompt()
    self.currentDetails = nil
    if self.ui then
        self.ui:hide()
    end
end

function turretInspectorController:sendAction(action, key)
    if not self.currentDetails or self.currentDetails.key ~= key then
        return
    end

    local protocol = g_game.getProtocolGame()
    if not protocol then
        return
    end

    self.ui.upgradeButton:setEnabled(false)
    self.ui.sellButton:setEnabled(false)
    protocol:sendExtendedJSONOpcode(TURRET_OPCODE, { action = action, key = key })
    self:close()
end

function turretInspectorController:confirmSell()
    local details = self.currentDetails
    if not details then
        return
    end

    self:destroyPrompt()
    local key = details.key
    local function cancel()
        self:destroyPrompt()
    end
    local function confirm()
        self:destroyPrompt()
        self:sendAction('sell', key)
    end

    self.sellPrompt = displayGeneralBox(tr('Sell Turret'),
        tr('Dismantle %s for %g soul?', details.name, details.sellPrice), {
            { text = tr('Sell'), callback = confirm },
            { text = tr('Cancel'), callback = cancel },
        }, confirm, cancel)
end

function turretInspectorController:open(details)
    self:destroyPrompt()
    self.currentDetails = details

    local isMaxLevel = details.currentLevel == details.nextLevel
    local player = g_game.getLocalPlayer()
    local soul = player and player:getSoul() or 0
    local hasSoul = soul >= details.soulRequiredForUpgrade

    self.ui.name:setText(details.name)
    self.ui.levelBadge:setText(string.format('LEVEL %d', details.currentLevel))
    self.ui.levelCurrent:setText(tostring(details.currentLevel))
    self.ui.damageCurrent:setText(formatDamage(details.currentDamageMin, details.currentDamageMax))
    self.ui.speedCurrent:setText(string.format('%.2f/s', details.currentAttackSpeed))
    self.ui.rangeCurrent:setText(tostring(details.currentRange))

    if isMaxLevel then
        self.ui.levelNext:setText(tr('MAX'))
        self.ui.damageNext:setText('-')
        self.ui.speedNext:setText('-')
        self.ui.rangeNext:setText('-')
    else
        self.ui.levelNext:setText(string.format('%d (+%d)', details.nextLevel,
            details.nextLevel - details.currentLevel))
        self.ui.damageNext:setText(string.format('%s (%+d / %+d)',
            formatDamage(details.nextDamageMin, details.nextDamageMax),
            math.floor(details.nextDamageMin) - math.floor(details.currentDamageMin),
            math.floor(details.nextDamageMax) - math.floor(details.currentDamageMax)))
        self.ui.speedNext:setText(string.format('%.2f/s (%+.2f)', details.nextAttackSpeed,
            details.nextAttackSpeed - details.currentAttackSpeed))
        self.ui.rangeNext:setText(string.format('%d (%+d)', details.nextRange,
            details.nextRange - details.currentRange))
    end

    self.ui.soulBalance:setText(string.format(tr('Available soul: %g'), soul))
    self.ui.upgradeButton:setEnabled(not isMaxLevel and hasSoul)
    self.ui.upgradeButton:setText(isMaxLevel and tr('Maximum Level') or
        string.format(tr('Upgrade (-%g)'), details.soulRequiredForUpgrade))
    self.ui.upgradeButton:setTooltip(not isMaxLevel and not hasSoul and tr('Not enough soul.') or '')
    self.ui.sellButton:setEnabled(true)
    self.ui.sellButton:setText(string.format(tr('Sell (+%g)'), details.sellPrice))

    local key = details.key
    self.ui.upgradeButton.onClick = function()
        self:sendAction('upgrade', key)
    end
    self.ui.sellButton.onClick = function()
        self:confirmSell()
    end

    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function turretInspectorController:onTurretOpcode(_, _, payload)
    if validateDetails(payload) then
        self:open(payload)
    end
end

function turretInspectorController:onInit()
    self.ui:hide()
    self:registerExtendedJSONOpcode(TURRET_OPCODE, function(...)
        self:onTurretOpcode(...)
    end)
end

function turretInspectorController:onGameStart()
    self:close()
end

function turretInspectorController:onGameEnd()
    self:close()
end

function turretInspectorController:onTerminate()
    self:close()
end
