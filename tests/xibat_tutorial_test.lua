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

local assetPaths = {
    'modules/game_xibat_tutorial/images/raids/1.png',
    'modules/game_xibat_tutorial/images/raids/2.png',
    'modules/game_xibat_tutorial/images/raids/3.png',
    'modules/game_xibat_tutorial/images/raids/4.png',
    'modules/game_xibat_tutorial/images/forge/1.png',
    'modules/game_xibat_tutorial/images/forge/2.png',
    'modules/game_xibat_tutorial/images/forge/3.png',
    'modules/game_xibat_tutorial/images/ascension/1.png',
}
for _, path in ipairs(assetPaths) do
    local file = io.open(root .. '/' .. path, 'rb')
    requireValue(file ~= nil, 'missing tutorial asset: ' .. path)
    file:close()
end

local styleFile = assert(io.open(root .. '/modules/game_xibat_tutorial/tutorial.otui', 'rb'))
local styleSource = styleFile:read('*a')
styleFile:close()
requireValue(not styleSource:match('\n%s*UIImage%s*\n') and
    styleSource:match('\n%s*UIWidget%s*\n%s*id: screenshot'),
    'tutorial screenshot must use the registered UIWidget type')

local state = { callbacks = {}, settings = {}, existing = {}, failPath = nil }
for _, path in ipairs(assetPaths) do
    state.existing['/' .. path:gsub('^modules/', '')] = true
end

local function makeWidget()
    local widget = { visible = true, enabled = true, children = {} }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:isVisible() return self.visible end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
    function widget:setOn(on) self.on = on end
    function widget:setText(text) self.text = text end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setVisible(visible) self.visible = visible end
    function widget:setValue(value) self.value = value end
    function widget:setImageSource(source) self.imageSource = source end
    function widget:setBackgroundColor(color) self.backgroundColor = color end
    function widget:setSize(size) self.size = size end
    function widget:setHeight(height) self.height = height end
    function widget:setWidth(width) self.width = width end
    function widget:getSize() return self.size end
    function widget:getParent() return self.parent end
    return widget
end

local parent = makeWidget()
parent.size = { width = 640, height = 360 }
local ui = makeWidget()
ui.parent = parent
for _, id in ipairs({
    'topicRail', 'topicTitle', 'stepCounter', 'screenshot', 'description', 'progress', 'previous', 'next', 'close',
}) do
    ui[id] = makeWidget()
end

local environment = {
    modules = {
        game_xibat_core = { XibatOpcode = { Tutorial = 208 } },
        client_topmenu = {},
    },
    Controller = {},
    g_ui = {},
    g_resources = {},
    g_settings = {},
    tr = function(text, ...) return string.format(text, ...) end,
}

function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:registerUIEvents(_, events) state.uiEvents = events end
    return controller
end

function environment.modules.client_topmenu.addRightGameToggleButton(_, _, _, callback)
    local button = makeWidget()
    button.callback = callback
    return button
end

function environment.g_ui.createWidget(_, parent)
    local widget = makeWidget()
    table.insert(parent.children, widget)
    return widget
end

function environment.g_resources.fileExists(path)
    return path ~= state.failPath and state.existing[path] == true
end

function environment.g_settings.getBoolean(key, default)
    local value = state.settings[key]
    if value == nil then return default end
    return value
end
function environment.g_settings.set(key, value) state.settings[key] = value end

local function openPayload(topic, forceOpen)
    return { version = 1, action = 'open', body = { topic = topic, forceOpen = forceOpen } }
end

loadModule('modules/game_xibat_tutorial/tutorial.lua', environment)
local controller = environment.xibatTutorialController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[208] and #ui.topicRail.children == 3 and controller.button and
    ui.size.width == 630 and ui.size.height == 350 and ui.screenshot.height == 122 and
    ui.topicRail.children[1].width == 184,
    'tutorial lifecycle or deterministic topic rail was not initialized')
parent.size = { width = 360, height = 640 }
state.uiEvents.onGeometryChange()
requireValue(ui.size.width == 350 and ui.size.height == 600 and ui.screenshot.height == 372 and
    ui.topicRail.children[1].width == 90, 'tutorial did not adapt to a portrait geometry change')

local invalid = {
    {},
    1,
    { version = 1, action = 'open', body = { topic = 'Turrets', forceOpen = false } },
    { version = 1, action = 'open', body = { topic = 'Raids', forceOpen = 1 } },
    { version = 2, action = 'open', body = { topic = 'Raids', forceOpen = false } },
    { version = 1, action = 'open', body = { topic = 'Raids', forceOpen = false }, extra = true },
}
local nilOk = pcall(state.callbacks[208], nil, 208, nil)
requireValue(nilOk and not ui.visible, 'nil tutorial payload escaped')
for _, payload in ipairs(invalid) do
    local ok = pcall(state.callbacks[208], nil, 208, payload)
    requireValue(ok and not ui.visible and not state.settings['xiba-help-already-saw-topic-Raids'],
        'invalid tutorial payload escaped or changed seen state')
end

state.callbacks[208](nil, 208, openPayload('Raids', false))
requireValue(ui.visible and controller.topicId == 'Raids' and controller.step == 1 and
    ui.topicTitle.text == 'Raid Operations' and ui.stepCounter.text == 'LESSON 1 OF 4' and
    ui.screenshot.imageSource == '/game_xibat_tutorial/images/raids/1' and
    state.settings['xiba-help-already-saw-topic-Raids'] == true,
    'valid tutorial did not render and commit its legacy seen key')

ui.next.onClick()
ui.next.onClick()
ui.next.onClick()
ui.next.onClick()
requireValue(controller.step == 4 and not ui.next.visible and ui.close.visible,
    'tutorial navigation escaped its final bound')
ui.previous.onClick()
requireValue(controller.step == 3 and ui.next.visible and not ui.close.visible,
    'tutorial previous navigation did not restore controls')

controller:close()
state.callbacks[208](nil, 208, openPayload('Raids', false))
requireValue(not ui.visible, 'seen non-forced tutorial reopened')

state.settings['xiba-help-already-saw-topic-Forge'] = false
state.callbacks[208](nil, 208, openPayload('Forge', true))
requireValue(ui.visible and controller.topicId == 'Forge' and controller.step == 1 and
    state.settings['xiba-help-already-saw-topic-Forge'] == false,
    'forced tutorial was suppressed, retained a stale step, or changed seen state')

state.failPath = '/game_xibat_tutorial/images/ascension/1.png'
state.callbacks[208](nil, 208, openPayload('Ascension', false))
requireValue(ui.visible and controller.topicId == 'Forge' and controller.step == 1 and
    not state.settings['xiba-help-already-saw-topic-Ascension'],
    'failed tutorial render corrupted visible state or was marked seen')
state.failPath = nil

controller:close()
state.settings['xiba-help-already-saw-topic-Ascension'] = true
controller:open('Ascension', false)
requireValue(ui.visible and controller.topicId == 'Ascension', 'manual tutorial access honored seen suppression')
controller:onGameEnd()
requireValue(not ui.visible and controller.topicId == 'Raids' and controller.step == 1,
    'tutorial game-end cleanup retained visible or stale state')

local button = controller.button
controller:onTerminate()
requireValue(button.destroyed and controller.button == nil, 'tutorial termination retained its top-menu button')

print('Xibat tutorial tests passed')
