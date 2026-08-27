local RAID_OPCODE = modules.game_xibat_core.XibatOpcode.RaidSelector
local RESET_TICK_INTERVAL = 1000
local MAX_RAIDS = 64
local MAX_REWARDS = 128

local tierColors = {
    bronze = '#cd8a54',
    silver = '#c4ccd1',
    gold = '#f0c95b',
}

local raidImageSources = {
    Bloons = '/game_xibat_raid/images/raids/Bloons',
    Cemetery = '/game_xibat_raid/images/raids/Cemetery',
    Corrodestone = '/game_xibat_raid/images/raids/Corrodestone',
    Crystal = '/game_xibat_raid/images/raids/Crystal',
    Desert = '/game_xibat_raid/images/raids/Desert',
    Forest = '/game_xibat_raid/images/raids/Forest',
    Glacio = '/game_xibat_raid/images/raids/Glacio',
    Hive = '/game_xibat_raid/images/raids/Hive',
    Prison = '/game_xibat_raid/images/raids/Prison',
    Seabed = '/game_xibat_raid/images/raids/Seabed',
    Tutorial = '/game_xibat_raid/images/raids/Tutorial',
    Volcano = '/game_xibat_raid/images/raids/Volcano',
}

raidSelectorController = Controller:new()
raidSelectorController:setUI('raid_selector')

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function isIntegerInRange(value, minimum, maximum)
    return isFiniteNumber(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isBoundedString(value, maximum, allowEmpty)
    return type(value) == 'string' and #value <= maximum and (allowEmpty or value ~= '')
end

local function validateReward(reward)
    if type(reward) ~= 'table' or type(reward.basicInfo) ~= 'table' or
        not isIntegerInRange(reward.basicInfo.clientId, 1, 65535) or
        not isBoundedString(reward.basicInfo.name, 128, false) or
        not isIntegerInRange(reward.waveId, 1, 10000) then
        return false
    end

    return reward.chance == nil or (isFiniteNumber(reward.chance) and reward.chance >= 0 and reward.chance <= 100)
end

local function validateRaid(raid)
    if type(raid) ~= 'table' or not isBoundedString(raid.name, 64, false) or
        not isBoundedString(raid.description, 2048, true) or
        not isIntegerInRange(raid.raidId, 1, 2147483647) or type(raid.available) ~= 'boolean' or
        not isIntegerInRange(raid.wavesTotal, 1, 10000) or
        not isIntegerInRange(raid.wavesCompleted, 0, raid.wavesTotal) or
        not isBoundedString(raid.tier, 32, false) or not isBoundedString(raid.mode, 32, false) or
        type(raid.items) ~= 'table' or #raid.items > MAX_REWARDS then
        return false
    end

    for _, reward in ipairs(raid.items) do
        if not validateReward(reward) then
            return false
        end
    end
    return true
end

local function validateSelector(body)
    if type(body) ~= 'table' or not isIntegerInRange(body.availableRaids, 0, 10000) or
        not isIntegerInRange(body.maxRaids, 0, 10000) or body.availableRaids > body.maxRaids or
        not isFiniteNumber(body.timerReset) or type(body.raidList) ~= 'table' or #body.raidList > MAX_RAIDS then
        return false
    end

    for _, raid in ipairs(body.raidList) do
        if not validateRaid(raid) then
            return false
        end
    end
    return true
end

function raidSelectorController:destroyPrompt()
    if self.startPrompt then
        self.startPrompt:destroy()
        self.startPrompt = nil
    end
end

function raidSelectorController:clearResetTimer()
    if self.resetEvent then
        self:removeEvent(self.resetEvent)
        self.resetEvent = nil
    end
    self.resetDeadline = nil
end

function raidSelectorController:updateResetTimer()
    if not self.resetDeadline or not self.ui then
        return false
    end

    local secondsLeft = math.max(0, math.ceil(self.resetDeadline - os.time()))
    self.ui.reset:setText(string.format('%02d:%02d:%02d', math.floor(secondsLeft / 3600),
        math.floor(secondsLeft / 60) % 60, secondsLeft % 60))
    if secondsLeft == 0 then
        self.resetDeadline = nil
        self.resetEvent = nil
        return false
    end
    return true
end

function raidSelectorController:startResetTimer(deadline)
    self:clearResetTimer()
    self.resetDeadline = deadline
    if self:updateResetTimer() then
        self.resetEvent = self:cycleEvent(function()
            return self:updateResetTimer()
        end, RESET_TICK_INTERVAL, 'xibatRaidReset')
    end
end

function raidSelectorController:close()
    self:destroyPrompt()
    self:clearResetTimer()
    self.selectedRaid = nil
    if self.ui then
        self.ui:hide()
    end
end

function raidSelectorController:selectRaid(raid, card)
    self.selectedRaid = raid
    self.ui.emptyDetail:hide()
    self.ui.detail:show()
    self.ui.detail.name:setText(raid.name)
    self.ui.detail.mode:setText(string.upper(raid.mode))
    self.ui.detail.tier:setText(string.upper(raid.tier))
    self.ui.detail.tier:setColor(tierColors[string.lower(raid.tier)] or '#84b9c8')
    self.ui.detail.waves:setText(string.format('%d / %d waves', raid.wavesCompleted, raid.wavesTotal))
    self.ui.detail.progress:setValue(raid.wavesCompleted / raid.wavesTotal * 100, 0, 100)
    local imageSource = raidImageSources[raid.name]
    self.ui.detail.screenshot:setVisible(imageSource ~= nil)
    if imageSource then
        self.ui.detail.screenshot:setImageSource(imageSource)
    end
    self.ui.detail.description:setText(raid.description)
    self.ui.detail.rewards:destroyChildren()

    for _, reward in ipairs(raid.items) do
        local item = g_ui.createWidget('XibatRaidReward', self.ui.detail.rewards)
        item:setItemId(reward.basicInfo.clientId)
        local chance = reward.chance and string.format(' (%.2g%%)', reward.chance) or ''
        item:setTooltip(string.format('Wave %d\n%s%s', reward.waveId, reward.basicInfo.name, chance))
    end

    self.ui.detail.rewardsTitle:setVisible(#raid.items > 0)
    self.ui.detail.rewards:setVisible(#raid.items > 0)
    self.ui.detail.startButton:setEnabled(raid.available)
    self.ui.detail.startButton:setText(raid.available and tr('Deploy to Raid') or tr('Raid Locked'))
    self.ui.detail.startButton.onClick = function()
        self:confirmStart()
    end

    if self.selectedCard and self.selectedCard ~= card then
        self.selectedCard:setOpacity(0.82)
    end
    self.selectedCard = card
    card:setOpacity(1)
end

function raidSelectorController:buildRaidList(raids)
    self.raidList:destroyChildren()
    self.ui.detail:hide()
    self.ui.emptyDetail:show()
    self.selectedCard = nil

    local firstAvailable
    for _, raid in ipairs(raids) do
        local card = g_ui.createWidget('XibatRaidCard', self.raidList)
        card.name:setText(raid.name)
        card.mode:setText(string.upper(raid.mode))
        card.status:setText(raid.available and
            string.format('%d/%d waves', raid.wavesCompleted, raid.wavesTotal) or tr('Locked'))
        card.progress:setValue(raid.wavesCompleted / raid.wavesTotal * 100, 0, 100)
        card.progress:setBackgroundColor(tierColors[string.lower(raid.tier)] or '#617782')
        card:setOpacity(raid.available and 0.82 or 0.5)
        card:setEnabled(raid.available)
        if not raid.available then
            card:setTooltip(tr('Advance through the previous raid to unlock this route.'))
        else
            card.onClick = function()
                self:selectRaid(raid, card)
            end
            firstAvailable = firstAvailable or { raid = raid, card = card }
        end
    end

    if firstAvailable then
        self:selectRaid(firstAvailable.raid, firstAvailable.card)
    end
end

function raidSelectorController:confirmStart()
    local raid = self.selectedRaid
    if not raid or not raid.available then
        return
    end

    self:destroyPrompt()
    local function cancel()
        self:destroyPrompt()
    end
    local function confirm()
        local protocol = g_game.getProtocolGame()
        if not protocol then
            cancel()
            return
        end
        protocol:sendExtendedJSONOpcode(RAID_OPCODE, { action = 'startRaid', body = { raidId = raid.raidId } })
        self:close()
    end

    self.startPrompt = displayGeneralBox(tr('Deploy to Raid'),
        tr('Start %s now?', raid.name), {
            { text = tr('Deploy'), callback = confirm },
            { text = tr('Cancel'), callback = cancel },
        }, confirm, cancel)
end

function raidSelectorController:openSelector(body)
    self:destroyPrompt()
    self.ui.entries:setText(string.format('%d / %d', body.availableRaids, body.maxRaids))
    self:buildRaidList(body.raidList)
    self:startResetTimer(body.timerReset)
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
end

function raidSelectorController:onRaidOpcode(_, _, payload)
    if type(payload) ~= 'table' or payload.action ~= 'openRaidSelector' or not validateSelector(payload.body) then
        return
    end
    self:openSelector(payload.body)
end

function raidSelectorController:onInit()
    self.ui:hide()
    self.raidList = self.ui:recursiveGetChildById('raidList')
    if not self.raidList then
        error('Raid selector list widget was not found.')
    end
    self:registerExtendedJSONOpcode(RAID_OPCODE, function(...)
        self:onRaidOpcode(...)
    end)
end

function raidSelectorController:onGameStart()
    self:close()
end

function raidSelectorController:onGameEnd()
    self:close()
end

function raidSelectorController:onTerminate()
    self:close()
end
