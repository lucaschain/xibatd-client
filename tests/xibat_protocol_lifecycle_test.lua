local root = arg[1] or "."

local function requireValue(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function loadModule(path, environment)
    setmetatable(environment, { __index = _G })
    local chunk = assert(loadfile(root .. "/" .. path))
    setfenv(chunk, environment)
    chunk()
    return environment
end

local errors = 0
local environment = {
    ProtocolGame = {},
    g_game = {},
    json = {
        decode = function(value)
            if value == "{}" then
                return {}
            end
            error("invalid fixture JSON")
        end,
    },
    g_logger = {
        error = function()
            errors = errors + 1
        end,
    },
}

loadModule("modules/gamelib/protocolgame.lua", environment)

local function makeProtocolWrapper(fields)
    return setmetatable({}, {
        __index = function(_, key)
            return environment.ProtocolGame[key] or fields[key]
        end,
        __newindex = function(_, key, value)
            fields[key] = value
        end,
    })
end

local firstProtocolFields = {}
local secondProtocolFields = {}
local firstProtocol = makeProtocolWrapper(firstProtocolFields)
local secondProtocol = makeProtocolWrapper(secondProtocolFields)
function environment.g_game.getProtocolGame()
    return makeProtocolWrapper(firstProtocolFields)
end
local received = 0

environment.ProtocolGame.registerExtendedJSONOpcode(207, function()
    received = received + 1
end)

firstProtocol:onExtendedOpcode(207, "{}")
requireValue(received == 1, "unfragmented JSON opcode was not delivered")

local malformedOk = pcall(firstProtocol.onExtendedOpcode, firstProtocol, 207, "broken")
requireValue(malformedOk and errors == 1 and received == 1,
    "malformed JSON escaped or reached its callback")

makeProtocolWrapper(firstProtocolFields):onExtendedOpcode(207, "S{")
makeProtocolWrapper(firstProtocolFields):onExtendedOpcode(207, "P")
makeProtocolWrapper(firstProtocolFields):onExtendedOpcode(207, "E}")
requireValue(received == 2, "fragmented JSON opcode was not reassembled")

firstProtocol:onExtendedOpcode(207, "S{")
secondProtocol:onExtendedOpcode(207, "E}")
requireValue(received == 2, "fragments crossed protocol sessions")
firstProtocol:onExtendedOpcode(207, "E}")
requireValue(received == 3, "the owning protocol could not finish its fragment")

firstProtocol:onExtendedOpcode(207, "S{")
secondProtocol:onExtendedOpcode(207, "S{")
firstProtocol:onExtendedOpcode(207, "E}")
secondProtocol:onExtendedOpcode(207, "E}")
requireValue(received == 5, "parallel protocol fragments replaced each other")

firstProtocol:onExtendedOpcode(207, "S{")
environment.ProtocolGame.unregisterExtendedJSONOpcode(207)
environment.ProtocolGame.registerExtendedJSONOpcode(207, function()
    received = received + 1
end)

local orphanOk = pcall(firstProtocol.onExtendedOpcode, firstProtocol, 207, "E}")
firstProtocol:onExtendedOpcode(207, "Pignored")
requireValue(orphanOk and received == 5,
    "stale or orphaned fragments reached a new registration")

firstProtocol:onExtendedOpcode(207, "S" .. string.rep("x", 1024 * 1024 + 1))
requireValue(errors == 2 and received == 5, "oversized JSON fragment was not rejected")

environment.ProtocolGame.unregisterExtendedJSONOpcode(207)

local controllerEnvironment = {
    g_modules = {
        getCurrentModule = function()
            return nil
        end,
    },
    removeEvent = function(event)
        requireValue(event == 42, "controller removed the wrong named event")
    end,
}
loadModule("modules/corelib/table.lua", controllerEnvironment)
loadModule("modules/modulelib/controller.lua", controllerEnvironment)
local namedEventController = controllerEnvironment.Controller:new()
namedEventController.scheduledEvents[2] = { xibatTimer = 42 }
namedEventController:removeEvent(42)
requireValue(next(namedEventController.scheduledEvents[2]) == nil,
    "controller retained a named event after explicit removal")

local timerState = {
    callbacks = {},
    events = {},
    nextEvent = 1,
    now = 1000,
    settings = {},
}

local function activeEvents()
    local count = 0
    for _ in pairs(timerState.events) do
        count = count + 1
    end
    return count
end

local timerEnvironment = {
    modules = {
        game_xibat_core = {
            XibatOpcode = { RaidTimer = 204 },
        },
    },
    Controller = {},
    g_settings = {},
    os = {
        time = function()
            return timerState.now
        end,
    },
}
function timerEnvironment.g_settings.getNode(key) return timerState.settings[key] end
function timerEnvironment.g_settings.setNode(key, value) timerState.settings[key] = value end

function timerEnvironment.Controller:new()
    local controller = {}

    function controller:setUI(name)
        self.uiName = name
    end

    function controller:registerExtendedJSONOpcode(opcode, callback)
        timerState.callbacks[opcode] = callback
    end

    function controller:cycleEvent(callback, _, name)
        if name and self.namedEvent then
            timerState.events[self.namedEvent] = nil
        end
        local event = timerState.nextEvent
        timerState.nextEvent = event + 1
        timerState.events[event] = callback
        self.namedEvent = event
        return event
    end

    function controller:removeEvent(event)
        timerState.events[event] = nil
        if self.namedEvent == event then
            self.namedEvent = nil
        end
    end

    return controller
end

local function makeLabel()
    return {
        setText = function(self, text)
            self.text = text
        end,
    }
end

local timerUI = {
    visible = true,
    title = makeLabel(),
    clock = makeLabel(),
    closeButton = {},
}
function timerUI:hide() self.visible = false end
function timerUI:show() self.visible = true end
function timerUI:breakAnchors() self.anchorsBroken = true end
function timerUI:setPosition(position) self.position = position end
function timerUI:getPosition() return self.position end
function timerUI:bindRectToParent() self.bound = true end

loadModule("modules/game_xibat_timer/raid_timer.lua", timerEnvironment)
local timerController = timerEnvironment.raidTimerController
timerController.ui = timerUI
timerController:onInit()
requireValue(timerState.callbacks[204], "timer opcode callback was not registered")

local malformedTimers = {
    {},
    { action = "start" },
    { action = "start", name = 1, expires = "soon" },
    { action = "start", name = "Invalid", expires = 0 / 0 },
    { action = "start", name = "Invalid", expires = math.huge },
}
for _, payload in ipairs(malformedTimers) do
    local ok = pcall(timerState.callbacks[204], nil, 204, payload)
    requireValue(ok and activeEvents() == 0, "malformed timer escaped or scheduled work")
end

timerState.callbacks[204](nil, 204, { action = "start", name = "Time Left", expires = 1061 })
requireValue(timerUI.visible and timerUI.title.text == "Time Left" and timerUI.clock.text == "01:01" and
    activeEvents() == 1, "valid timer did not render or schedule one event")
timerUI.closeButton.onClick()
requireValue(not timerUI.visible and activeEvents() == 1,
    "dismissing timer cancelled authoritative countdown state")
timerUI.position = { x = 77, y = 88 }
timerUI.onDragLeave(timerUI)
requireValue(timerState.settings.xibatRaidTimer.position.x == 77 and
    timerState.settings.xibatRaidTimer.position.y == 88, "timer position was not persisted")

timerState.callbacks[204](nil, 204, { action = "start", name = "Starting In", expires = 1030 })
requireValue(timerUI.visible and timerUI.title.text == "Starting In" and activeEvents() == 1,
    "timer replacement retained a stale event or remained dismissed")

timerState.callbacks[204](nil, 204, { action = "stop" })
requireValue(not timerUI.visible and activeEvents() == 0, "timer stop retained UI or scheduled work")

timerState.callbacks[204](nil, 204, { action = "start", name = "Time Left", expires = 1100 })
timerController:onGameEnd()
requireValue(not timerUI.visible and activeEvents() == 0, "game end retained timer state")

local selectorState = {
    callbacks = {},
    events = {},
    nextEvent = 1,
    cards = {},
    sent = nil,
    prompt = nil,
    now = 1000,
}

local function selectorActiveEvents()
    local count = 0
    for _ in pairs(selectorState.events) do
        count = count + 1
    end
    return count
end

local function makeSelectorWidget()
    local widget = { visible = true, enabled = true, children = {} }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
    function widget:destroyChildren() self.children = {} end
    function widget:setText(text) self.text = text end
    function widget:setColor(color) self.color = color end
    function widget:setValue(value) self.value = value end
    function widget:setVisible(visible) self.visible = visible end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setOpacity(opacity) self.opacity = opacity end
    function widget:setBackgroundColor(color) self.backgroundColor = color end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setItemId(itemId) self.itemId = itemId end
    function widget:setImageSource(imageSource) self.imageSource = imageSource end
    function widget:getWidth() return self.width end
    function widget:getHeight() return self.height end
    function widget:setHeight(height) self.height = height end
    return widget
end

local selectorUI = makeSelectorWidget()
selectorUI.entries = makeSelectorWidget()
selectorUI.reset = makeSelectorWidget()
selectorUI.listPanel = makeSelectorWidget()
selectorUI.listPanel.raidList = makeSelectorWidget()
selectorUI.emptyDetail = makeSelectorWidget()
selectorUI.detail = makeSelectorWidget()
function selectorUI:recursiveGetChildById(id)
    if id == 'raidList' then
        return self.listPanel.raidList
    end
end
for _, id in ipairs({ 'name', 'mode', 'tier', 'waves', 'progress', 'screenshot', 'description', 'rewards', 'rewardsTitle', 'startButton' }) do
    selectorUI.detail[id] = makeSelectorWidget()
end
selectorUI.detail.screenshot.width = 610
selectorUI.detail.screenshot.height = 100

local selectorEnvironment = {
    modules = {
        game_xibat_core = {
            XibatOpcode = { RaidSelector = 207 },
        },
    },
    Controller = {},
    g_ui = {},
    g_game = {},
    os = {
        time = function()
            return selectorState.now
        end,
    },
    tr = function(text, ...)
        if select('#', ...) > 0 then
            return string.format(text, ...)
        end
        return text
    end,
}

function selectorEnvironment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) selectorState.callbacks[opcode] = callback end
    function controller:cycleEvent(callback, _, name)
        if name and self.namedEvent then
            selectorState.events[self.namedEvent] = nil
        end
        local event = selectorState.nextEvent
        selectorState.nextEvent = event + 1
        selectorState.events[event] = callback
        self.namedEvent = event
        return event
    end
    function controller:removeEvent(event)
        selectorState.events[event] = nil
        if self.namedEvent == event then self.namedEvent = nil end
    end
    return controller
end

function selectorEnvironment.g_ui.createWidget(style, parent)
    local widget = makeSelectorWidget()
    if style == 'XibatRaidCard' then
        widget.name = makeSelectorWidget()
        widget.mode = makeSelectorWidget()
        widget.status = makeSelectorWidget()
        widget.progress = makeSelectorWidget()
        table.insert(selectorState.cards, widget)
    end
    table.insert(parent.children, widget)
    return widget
end

function selectorEnvironment.g_game.getProtocolGame()
    return {
        sendExtendedJSONOpcode = function(_, opcode, payload)
            selectorState.sent = { opcode = opcode, payload = payload }
        end,
    }
end

function selectorEnvironment.displayGeneralBox(_, _, buttons)
    local prompt = makeSelectorWidget()
    prompt.buttons = buttons
    selectorState.prompt = prompt
    return prompt
end

loadModule("modules/game_xibat_raid/raid_selector.lua", selectorEnvironment)
local selectorController = selectorEnvironment.raidSelectorController
selectorController.ui = selectorUI
selectorController:onInit()
requireValue(selectorState.callbacks[207] and selectorUI.detail.screenshot.height == 496,
    "selector opcode callback or aspect-fitted screenshot was not initialized")

local invalidSelector = {
    action = 'openRaidSelector',
    body = {
        availableRaids = 1,
        maxRaids = 1,
        timerReset = 1100,
        raidList = { { name = 'Broken', wavesTotal = 0 } },
    },
}
local invalidOk = pcall(selectorState.callbacks[207], nil, 207, invalidSelector)
requireValue(invalidOk and not selectorUI.visible and selectorActiveEvents() == 0,
    "malformed selector escaped or changed UI state")

local validSelector = {
    action = 'openRaidSelector',
    body = {
        availableRaids = 1,
        maxRaids = 1,
        timerReset = 1100,
        raidList = { {
            name = 'Tutorial',
            description = 'Fixture raid',
            raidId = 1,
            available = true,
            wavesTotal = 6,
            wavesCompleted = 0,
            items = {},
            tier = 'bronze',
            mode = 'classic',
        } },
    },
}
selectorState.callbacks[207](nil, 207, validSelector)
requireValue(selectorUI.visible and #selectorState.cards == 1 and selectorUI.detail.visible and
    selectorController.selectedRaid.raidId == 1 and selectorActiveEvents() == 1,
    "valid selector did not render and select its available raid")
requireValue(selectorUI.detail.screenshot.visible and
    selectorUI.detail.screenshot.imageSource == '/game_xibat_raid/images/raids/Tutorial',
    "raid selector did not render the matching screenshot")

selectorUI.detail.startButton.onClick()
requireValue(selectorState.prompt and #selectorState.prompt.buttons == 2,
    "raid start confirmation did not open")
selectorState.prompt.buttons[1].callback()
requireValue(selectorState.sent and selectorState.sent.opcode == 207 and
    selectorState.sent.payload.action == 'startRaid' and selectorState.sent.payload.body.raidId == 1,
    "raid start request did not preserve the server contract")
requireValue(not selectorUI.visible and selectorActiveEvents() == 0,
    "confirmed raid start retained selector UI or scheduled work")

print("Xibat protocol lifecycle tests passed")
