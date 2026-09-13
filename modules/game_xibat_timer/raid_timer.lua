local TIMER_OPCODE = modules.game_xibat_core.XibatOpcode.RaidTimer
local RAID_OPCODE = modules.game_xibat_core.XibatOpcode.RaidSelector
local TICK_INTERVAL = 1000
local MAX_TITLE_LENGTH = 64
local TIMER_SETTINGS = 'xibatRaidTimer'

raidTimerController = Controller:new()
raidTimerController:setUI('raid_timer')

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function raidTimerController:clearTimer()
    if self.timerEvent then
        self:removeEvent(self.timerEvent)
        self.timerEvent = nil
    end

    self.deadline = nil
    self.preparation = nil
    self.skipPending = false
    if self.ui then
        self.ui.startWaveButton:hide()
        self.ui:setHeight(58)
        self.ui:hide()
    end
end

function raidTimerController:dismissTimer()
    if self.ui then self.ui:hide() end
end

function raidTimerController:onTimerMoved(widget)
    if not widget then return end
    local position = widget:getPosition()
    g_settings.setNode(TIMER_SETTINGS, { position = { x = position.x, y = position.y } })
end

function raidTimerController:restorePosition()
    local settings = g_settings.getNode(TIMER_SETTINGS) or {}
    local position = settings.position
    if type(position) ~= 'table' or type(position.x) ~= 'number' or type(position.y) ~= 'number' then return end
    self.ui:breakAnchors()
    self.ui:setPosition(position)
    self.ui:bindRectToParent()
end

function raidTimerController:updateTimer()
    if not self.deadline or not self.ui then
        return false
    end

    local secondsLeft = math.max(0, math.ceil(self.deadline - os.time()))
    self.ui.clock:setText(string.format('%02d:%02d', math.floor(secondsLeft / 60), secondsLeft % 60))

    if secondsLeft == 0 then
        self.deadline = nil
        self.preparation = nil
        self.timerEvent = nil
        self.ui:hide()
        return false
    end

    return true
end

function raidTimerController:startTimer(title, deadline, preparation)
    self:clearTimer()
    self.deadline = deadline
    self.preparation = preparation
    self.ui.startWaveButton:setVisible(preparation ~= nil)
    self.ui.startWaveButton:setEnabled(true)
    self.ui:setHeight(preparation and 90 or 58)
    self.ui.title:setText(title)
    self.ui:show()

    if self:updateTimer() then
        self.timerEvent = self:cycleEvent(function()
            return self:updateTimer()
        end, TICK_INTERVAL, 'xibatRaidTimer')
    end
end

function raidTimerController:onTimerOpcode(_, _, payload)
    if type(payload) ~= 'table' or type(payload.action) ~= 'string' then
        return
    end

    if payload.action == 'stop' then
        self:clearTimer()
        return
    end

    if payload.action ~= 'start' or type(payload.name) ~= 'string' or payload.name == '' or
        #payload.name > MAX_TITLE_LENGTH or not isFiniteNumber(payload.expires) then
        return
    end

    local preparation = payload.preparation
    if preparation ~= nil and (type(preparation) ~= 'string' or #preparation > 80 or
        not preparation:match('^%d+:%d+:%d+$')) then
        return
    end
    self:startTimer(payload.name, payload.expires, preparation)
end

function raidTimerController:startWaveNow()
    if not self.preparation or self.skipPending or not self.deadline or self.deadline <= os.time() then return end
    local protocol = g_game.getProtocolGame()
    if not protocol then return end
    self.skipPending = true
    self.ui.startWaveButton:setEnabled(false)
    protocol:sendExtendedJSONOpcode(RAID_OPCODE, {
        action = 'startWave', body = { preparation = self.preparation }
    })
end

function raidTimerController:onInit()
    self:restorePosition()
    self.ui.closeButton.onClick = function() self:dismissTimer() return true end
    self.ui.startWaveButton.onClick = function() self:startWaveNow() return true end
    self.ui.onDragLeave = function(widget) self:onTimerMoved(widget) end
    self.ui:hide()
    self:registerExtendedJSONOpcode(TIMER_OPCODE, function(...)
        self:onTimerOpcode(...)
    end)
end

function raidTimerController:onGameStart()
    self:clearTimer()
end

function raidTimerController:onGameEnd()
    self:clearTimer()
end

function raidTimerController:onTerminate()
    self:clearTimer()
end
