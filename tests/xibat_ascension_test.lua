local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then error(message, 2) end
end

local function loadModule(path, environment)
    setmetatable(environment, { __index = _G })
    local chunk = assert(loadfile(root .. '/' .. path))
    setfenv(chunk, environment)
    chunk()
end

local styleFile = assert(io.open(root .. '/modules/game_xibat_ascension/ascension.otui', 'rb'))
local styleSource = styleFile:read('*a')
styleFile:close()
requireValue(not styleSource:match('\n%s*UIImage%s*\n') and
    styleSource:match('\n%s*UIWidget%s*\n%s*id: icon'),
    'Ascension symbolic icon must use the registered UIWidget type')
requireValue(styleSource:match('AscensionViewportButton < UIButton') and
    styleSource:match('size: 72 72') and styleSource:match('id: badge') and
    styleSource:match('anchors%.bottom: parent%.bottom') and styleSource:match('margin%-right: 10') and
    styleSource:match('margin%-bottom: 10') and styleSource:match('background%-color: #172128f2') and
    styleSource:match('/images/ui/highlight') and styleSource:match('/images/ui/bright%-x20') and
    styleSource:match('/game_xibat_ascension/images/upgrade'),
    'Ascension viewport launcher must retain its large highlighted badge presentation')
for _, path in ipairs({ 'upgrade.svg', 'upgrade.png', 'LICENSE-upgrade.md' }) do
    local iconFile = io.open(root .. '/modules/game_xibat_ascension/images/' .. path, 'rb')
    requireValue(iconFile, 'missing vendored Ascension upgrade icon file: ' .. path)
    iconFile:close()
end

local state = { callbacks = {}, sent = {}, events = {}, nextEvent = 1 }

local function makeWidget()
    local widget = { visible = true, enabled = true, children = {} }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:isVisible() return self.visible end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
    function widget:isDestroyed() return self.destroyed == true end
    function widget:destroyChildren() self.children = {} end
    function widget:setText(text) self.text = text end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setOpacity(opacity) self.opacity = opacity end
    function widget:setValue(value) self.value = value end
    function widget:setItemId(itemId) self.itemId = itemId end
    function widget:setItemCount(count) self.itemCount = count end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setImageSource(source) self.imageSource = source end
    function widget:setColor(color) self.color = color end
    function widget:setBackgroundColor(color) self.backgroundColor = color end
    function widget:setWidth(width) self.width = width end
    function widget:setOn(on) self.on = on end
    return widget
end

local ui = makeWidget()
local mapPanel = makeWidget()
for _, id in ipairs({
    'categoryRail', 'nodes', 'categoryTitle', 'categoryProgress', 'message', 'level', 'points', 'experience', 'reset',
}) do
    ui[id] = makeWidget()
end

local environment = {
    modules = {
        game_xibat_core = { XibatOpcode = { Ascension = 203 } },
        game_interface = { getMapPanel = function() return mapPanel end },
    },
    Controller = {},
    g_game = {},
    g_ui = {},
    tr = function(text, ...) return string.format(text, ...) end,
}

function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:bindKeyDown(_, callback) state.hotkey = callback end
    function controller:scheduleEvent(callback)
        local event = state.nextEvent
        state.nextEvent = event + 1
        state.events[event] = callback
        return event
    end
    function controller:removeEvent(event) state.events[event] = nil end
    return controller
end

function environment.g_game.isOnline() return true end
function environment.g_game.getProtocolGame()
    return {
        sendExtendedJSONOpcode = function(_, opcode, payload)
            table.insert(state.sent, { opcode = opcode, payload = payload })
        end,
    }
end

function environment.g_ui.createWidget(style, parent)
    local widget = makeWidget()
    if style == 'AscensionNodeCard' then
        for _, id in ipairs({ 'item', 'icon', 'name', 'requirement', 'status', 'spend' }) do
            widget[id] = makeWidget()
        end
    elseif style == 'AscensionViewportButton' then
        for _, id in ipairs({ 'glow', 'bright', 'frame', 'icon', 'badge' }) do widget[id] = makeWidget() end
    end
    table.insert(parent.children, widget)
    return widget
end

function environment.displayGeneralBox(_, _, buttons)
    local prompt = makeWidget()
    prompt.buttons = buttons
    state.prompt = prompt
    return prompt
end

local function makeView()
    local spentPoints, categories = {}, {}
    for categoryId = 1, 13 do
        spentPoints[tostring(categoryId)] = 0
        local passives = {}
        for node = 1, 10 do
            table.insert(passives, {
                name = 'Milestone ' .. node,
                cost = 1,
                unlockPoints = node,
                raidLevel = node + 7,
                icon = node == 1 and 'raid_start_level' or nil,
                previewItems = node == 2 and { { clientId = 3000, name = 'Reward item', count = 2 } } or {},
            })
        end
        table.insert(categories, {
            id = categoryId,
            name = 'Path ' .. categoryId,
            spentPoints = 0,
            maxPoints = 10,
            passives = passives,
        })
    end
    return {
        action = 'ascensionView',
        body = {
            progress = {
                level = 1,
                levelExperience = 100,
                levelExperienceRequired = 100,
                levelProgress = 1,
                availablePoints = 1,
                totalSpentPoints = 0,
                spentPoints = spentPoints,
            },
            categories = categories,
        },
    }
end

local function result(operation, requestId, ok, code, stateBody)
    return {
        action = 'ascensionResult',
        body = { operation = operation, requestId = requestId, ok = ok, code = code, state = stateBody },
    }
end

local function status(availablePoints, extra)
    local progress = {
        level = 4,
        levelExperience = 25,
        levelExperienceRequired = 100,
        levelProgress = 0.25,
        availablePoints = availablePoints,
        totalSpentPoints = 0,
    }
    if extra then progress.extra = true end
    return { action = 'ascensionStatus', body = { progress = progress } }
end

loadModule('modules/game_xibat_ascension/ascension.lua', environment)
local controller = environment.xibatAscensionController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[203] and state.hotkey and controller.launcher and
    controller.launcher == mapPanel.children[1] and not controller.launcher.visible,
    'Ascension lifecycle or viewport launcher was not registered')

controller:onGameStart()
requireValue(#state.sent == 1 and state.sent[1].opcode == 203 and state.sent[1].payload.action == 'sync' and
    not ui.visible and not controller.launcher.visible,
    'Ascension game start did not perform one silent authoritative sync')
local retry = controller.syncEvent
requireValue(retry and state.events[retry], 'login sync has no recovery for a missed startup response')
state.events[retry]()
requireValue(#state.sent == 2 and state.sent[2].payload.action == 'sync' and not ui.visible,
    'missed login sync did not retry silently')
state.sent = {}

state.callbacks[203](nil, 203, status(12))
requireValue(not controller.syncEvent, 'authoritative status did not cancel login retries')
requireValue(controller.launcher.visible and controller.launcher.badge.text == '12' and
    controller.launcher.badge.width == 26 and not ui.visible,
    'Ascension status did not show the viewport badge without opening the board')
controller.launcher.onClick()
requireValue(#state.sent == 1 and state.sent[1].payload.action == 'open',
    'Ascension viewport launcher did not request the board')
state.sent = {}

state.callbacks[203](nil, 203, status(0, true))
requireValue(controller.availablePoints == 12 and controller.launcher.visible,
    'malformed Ascension status changed launcher state')
state.callbacks[203](nil, 203, status(0))
requireValue(not controller.launcher.visible, 'zero available Ascension points did not hide the launcher')

local invalid = makeView()
invalid.body.extra = true
local invalidOk = pcall(state.callbacks[203], nil, 203, invalid)
requireValue(invalidOk and not ui.visible and not controller.snapshot,
    'malformed Ascension view escaped or changed UI state')

state.callbacks[203](nil, 203, makeView())
requireValue(ui.visible and #ui.categoryRail.children == 13 and #ui.nodes.children == 10 and
    ui.experience.value == 100 and ui.nodes.children[1].icon.imageSource and
    ui.nodes.children[2].item.itemId == 3000 and ui.nodes.children[1].spend.enabled,
    'valid Ascension view did not render categories, progress, icons, and item previews')

ui.nodes.children[1].spend.onClick()
ui.nodes.children[1].spend.onClick()
local spendRequest = state.sent[1]
requireValue(#state.sent == 1 and spendRequest.opcode == 203 and spendRequest.payload.action == 'spend' and
    spendRequest.payload.requestId == 1 and spendRequest.payload.categoryId == 1 and
    spendRequest.payload.points == 1 and spendRequest.payload.expectedSpentPoints == 0,
    'Ascension milestone did not emit one exact correlated spend')

state.callbacks[203](nil, 203, result('spend', 2, true, 'ok', {
    level = 1, levelExperience = 100, levelExperienceRequired = 100, levelProgress = 1,
    availablePoints = 0, totalSpentPoints = 1, categoryId = 1, spentPoints = 1,
}))
requireValue(controller.pendingRequest, 'stale Ascension response cleared the active request')

state.callbacks[203](nil, 203, result('spend', 1, true, 'ok', {
    level = 1, levelExperience = 100, levelExperienceRequired = 100, levelProgress = 1,
    availablePoints = 0, totalSpentPoints = 1, categoryId = 1, spentPoints = 1,
}))
requireValue(not controller.pendingRequest and controller.snapshot.categories[1].spentPoints == 1 and
    not ui.nodes.children[2].spend.enabled and not controller.launcher.visible,
    'Ascension spend result did not update authoritative state or launcher')

ui.reset.onClick()
requireValue(state.prompt and #state.prompt.buttons == 2, 'Ascension reset did not require confirmation')
local prompt = state.prompt
prompt.buttons[1].callback()
requireValue(state.sent[2].payload.action == 'reset' and state.sent[2].payload.requestId == 2,
    'Ascension reset confirmation did not send one correlated request')
state.callbacks[203](nil, 203, result('reset', 2, true, 'ok', {
    level = 1, levelExperience = 100, levelExperienceRequired = 100, levelProgress = 1,
    availablePoints = 1, totalSpentPoints = 0, reset = true,
}))
requireValue(controller.launcher.visible and controller.launcher.badge.text == '1',
    'Ascension reset result did not restore the viewport launcher')

controller:onGameEnd()
requireValue(prompt.destroyed and not ui.visible and not controller.snapshot and
    not controller.availablePoints and not controller.launcher.visible,
    'Ascension logout retained its view, point state, launcher, or reset confirmation')

local launcher = controller.launcher
controller:onTerminate()
requireValue(controller.launcher == nil and launcher.destroyed,
    'Ascension termination retained its viewport launcher')

print('Xibat Ascension tests passed')
