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

local state = { callbacks = {}, sent = {}, events = {}, nextEvent = 1 }

local function makeWidget()
    local widget = { visible = true, enabled = true, children = {} }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:isVisible() return self.visible end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
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
    function widget:setOn(on) self.on = on end
    return widget
end

local ui = makeWidget()
for _, id in ipairs({
    'categoryRail', 'nodes', 'categoryTitle', 'categoryProgress', 'message', 'level', 'points', 'experience', 'reset',
}) do
    ui[id] = makeWidget()
end

local environment = {
    modules = {
        game_xibat_core = { XibatOpcode = { Ascension = 203 } },
        client_topmenu = {},
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

function environment.modules.client_topmenu.addRightGameToggleButton(_, _, _, callback)
    local button = makeWidget()
    button.callback = callback
    return button
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

loadModule('modules/game_xibat_ascension/ascension.lua', environment)
local controller = environment.xibatAscensionController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[203] and state.hotkey and controller.button, 'Ascension lifecycle was not registered')

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
    not ui.nodes.children[2].spend.enabled, 'Ascension spend result did not update authoritative state')

ui.reset.onClick()
requireValue(state.prompt and #state.prompt.buttons == 2, 'Ascension reset did not require confirmation')
local prompt = state.prompt
controller:onGameEnd()
requireValue(prompt.destroyed and not ui.visible and not controller.snapshot,
    'Ascension logout retained its view or reset confirmation')

controller:onTerminate()
requireValue(controller.button == nil, 'Ascension termination retained its top-menu button')

print('Xibat Ascension tests passed')
