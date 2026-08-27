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

local moduleFile = assert(io.open(root .. '/modules/game_xibat_guidance/guidance.lua', 'rb'))
local moduleSource = moduleFile:read('*a')
moduleFile:close()
requireValue(not moduleSource:match('autoWalk') and not moduleSource:match('walkTo'),
    'guidance first slice must not initiate walking')
requireValue(not moduleSource:match('registerUIEvents'),
    'map geometry must use regular controller events')

local interfaceFile = assert(io.open(root .. '/modules/game_interface/interface.otmod', 'rb'))
local interfaceSource = interfaceFile:read('*a')
interfaceFile:close()
requireValue(interfaceSource:match('%- game_xibat_tutorial%s*\n%s*%- game_xibat_guidance'),
    'guidance module must load after the Field Manual module')

local state = {
    callbacks = {},
    events = {},
    visible = true,
    created = {},
    tiles = {},
}

local function makeWidget(kind)
    local widget = { kind = kind, children = {}, width = 176, height = 38 }
    function widget:isDestroyed() return self.destroyed == true end
    function widget:destroy()
        if self.destroyed then return end
        self.destroyed = true
        if self.attachedTo then
            self.attachedTo.detachCount = self.attachedTo.detachCount + 1
            self.attachedTo = nil
        end
    end
    function widget:setText(text) self.text = text end
    function widget:setIcon(icon) self.icon = icon end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setRotation(rotation) self.rotation = rotation end
    function widget:setPosition(position) self.position = position end
    function widget:getWidth() return self.width end
    function widget:getHeight() return self.height end
    function widget:insertChild(index, child) table.insert(self.children, index, child) end
    if kind == 'XibatGuidanceAttached' or kind == 'XibatGuidanceEdge' then
        widget.arrow = makeWidget('arrow')
        widget.label = makeWidget('label')
        if kind == 'XibatGuidanceAttached' then widget.width, widget.height = 160, 42 end
    end
    table.insert(state.created, widget)
    return widget
end

local function makeAttachable(position, id, name, npc)
    local object = {
        position = position,
        id = id,
        name = name,
        npc = npc == true,
        removed = false,
        attachments = {},
        detachCount = 0,
    }
    function object:attachWidget(widget)
        widget.attachedTo = self
        table.insert(self.attachments, widget)
    end
    function object:getPosition() return self.position end
    function object:getId() return self.id end
    function object:getName() return self.name end
    function object:isNpc() return self.npc end
    function object:isRemoved() return self.removed end
    return object
end

local player = makeAttachable({ x = 100, y = 100, z = 7 }, 1, 'Player', false)
local tile = makeAttachable({ x = 102, y = 100, z = 7 })
state.tiles['102:100:7'] = tile

local panel = makeWidget('mapPanel')
panel.width, panel.height = 400, 300
function panel:getRect() return { x = 20, y = 30, width = self.width, height = self.height } end
function panel:isInRange() return state.visible end
function panel:getSpectators(multifloor)
    state.spectatorMultifloor = multifloor
    return state.spectators or {}
end

local minimap = makeWidget('minimap')
local existingPlayerFlag = makeWidget('existingFlag')
table.insert(minimap.children, existingPlayerFlag)
function minimap:centerInPosition(marker, position)
    marker.centered = { x = position.x, y = position.y, z = position.z }
end

local environment = {
    modules = {
        game_xibat_core = { XibatOpcode = { Tutorial = 208, Guidance = 209 } },
        game_interface = { getMapPanel = function() return panel end },
        game_minimap = { getMiniMapUi = function() return minimap end },
    },
    Controller = {},
    Creature = {},
    LocalPlayer = {},
    UIMap = {},
    g_ui = {},
    g_game = {},
    g_map = {},
}

function environment.Controller:new()
    local controller = {}
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:registerEvents(actor, events) state.events[actor] = events end
    return controller
end
function environment.g_ui.importStyle(path) state.style = path end
function environment.g_ui.createWidget(kind, parent)
    local widget = makeWidget(kind)
    if parent then parent:insertChild(1, widget) end
    return widget
end
function environment.g_game.isOnline() return state.online ~= false end
function environment.g_game.getLocalPlayer() return player end
function environment.g_map.getTile(position)
    return state.tiles[string.format('%d:%d:%d', position.x, position.y, position.z)]
end

local function showPacket(target, position)
    return {
        version = 1,
        action = 'show',
        body = { target = target, position = position or { x = 102, y = 100, z = 7 } },
    }
end

local clearPacket = { version = 1, action = 'clear' }

loadModule('modules/game_xibat_guidance/guidance.lua', environment)
local controller = environment.xibatGuidanceController
controller:onInit()
requireValue(state.style == 'guidance.otui' and state.callbacks[209] and not state.callbacks[208],
    'guidance did not register its independent opcode and style')
requireValue(state.events[environment.LocalPlayer].onPositionChange and
    state.events[environment.Creature].onAppear and state.events[environment.Creature].onDisappear and
    state.events[environment.Creature].onPositionChange and state.events[environment.UIMap].onZoomChange and
    state.events[panel].onGeometryChange, 'guidance refresh events were not registered')

local invalid = {
    {},
    { version = 2, action = 'clear' },
    { version = 1, action = 'hide' },
    { version = 1, action = 'clear', body = {} },
    { version = 1, action = 'clear', extra = true },
    { version = 1, action = 'show' },
    { version = 1, action = 'show', body = {} },
    { version = 1, action = 'show', body = showPacket('sergio').body, revision = 1 },
    { version = 1, action = 'show', body = { target = 'Sergio', position = { x = 1, y = 2, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'unknown', position = { x = 1, y = 2, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = -1, y = 2, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = 65536, y = 2, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = 1, y = 65536, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = 1, y = 2, z = 16 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = 1.5, y = 2, z = 3 } } },
    { version = 1, action = 'show', body = { target = 'sergio', position = { x = 1, y = 2, z = 3, extra = true } } },
    { version = 1, action = 'show', body = {
        target = 'sergio', position = { x = 1, y = 2, z = 3 }, label = 'server label',
    } },
}
for _, payload in ipairs(invalid) do
    local ok = pcall(state.callbacks[209], nil, 209, payload)
    requireValue(ok and not controller.target, 'invalid guidance packet escaped or changed state')
end
local nilOk = pcall(state.callbacks[209], nil, 209, nil)
requireValue(nilOk and not controller.target, 'nil guidance packet escaped')

local expectedMetadata = {
    sergio = { kind = 'npc', label = 'Sergio Rocket', name = 'Sergio Rocket' },
    nicolai = { kind = 'npc', label = 'Nicolai F', name = 'Nicolai F' },
    raidSelector = { kind = 'tile', label = 'Raid Selector' },
    globe = { kind = 'tile', label = 'Raid Globe' },
    araci = { kind = 'npc', label = 'Araci', name = 'Araci' },
}
state.visible = false
for _, target in ipairs({ 'sergio', 'nicolai', 'raidSelector', 'globe', 'araci' }) do
    state.callbacks[209](nil, 209, showPacket(target))
    local expected = expectedMetadata[target]
    requireValue(controller.target.target == target and controller.target.kind == expected.kind and
        controller.target.label == expected.label and controller.target.name == expected.name,
        'exact show packet did not derive local metadata for ' .. target)
end
state.callbacks[209](nil, 209, clearPacket)
requireValue(not controller.target, 'exact clear packet did not clear guidance')
state.callbacks[209](nil, 209, showPacket('globe', { x = 0, y = 65535, z = 15 }))
requireValue(controller.target.position.x == 0 and controller.target.position.y == 65535 and
    controller.target.position.z == 15, 'inclusive coordinate bounds were not accepted')
state.callbacks[209](nil, 209, clearPacket)

state.visible = true
state.callbacks[209](nil, 209, showPacket('raidSelector'))
local firstAttached = controller.attachedWidget
local firstMarker = controller.minimapMarker
requireValue(firstAttached and #tile.attachments == 1 and firstAttached.label.text == 'Raid Selector',
    'visible raid-selector tile guidance was not attached')
requireValue(firstMarker and firstMarker.temporary and firstMarker.icon == '/images/game/minimap/flag18' and
    minimap.children[1] == firstMarker and not existingPlayerFlag.destroyed,
    'temporary minimap marker replaced or destroyed an existing player flag')

state.visible = false
state.events[environment.UIMap].onZoomChange()
local edge = controller.edgeWidget
requireValue(firstAttached.destroyed and tile.detachCount == 1 and edge and edge.arrow.rotation == 0 and
    edge.position.x >= 32 and edge.position.x + edge.width <= 408 and
    edge.position.y >= 42 and edge.position.y + edge.height <= 318,
    'attached cleanup or offscreen arrow clamping failed')
controller:cleanup()
controller:cleanup()
requireValue(tile.detachCount == 1, 'direct attached-widget destruction was not idempotent')

player.position = { x = 100, y = 100, z = 9 }
local impostor = makeAttachable({ x = 101, y = 101, z = 9 }, 76, 'Sergio Rocket', false)
local sergio = makeAttachable({ x = 103, y = 104, z = 9 }, 77, 'Sergio Rocket', true)
state.spectators = { impostor, sergio }
state.visible = true
state.callbacks[209](nil, 209, showPacket('sergio', { x = 110, y = 110, z = 9 }))
local npcMarker = controller.minimapMarker
requireValue(controller.attachedWidget and #impostor.attachments == 0 and #sergio.attachments == 1 and
    controller.attachedWidget.label.text == 'Sergio Rocket' and npcMarker.centered.x == 103 and
    state.spectatorMultifloor == false,
    'NPC scan did not require isNpc() and derive the local name')

sergio.position = { x = 105, y = 106, z = 9 }
state.events[environment.Creature].onPositionChange(sergio)
requireValue(npcMarker.centered.x == 105 and npcMarker.centered.y == 106,
    'NPC movement did not refresh the temporary marker')

local beforeDisappear = controller.attachedWidget
sergio.removed = true
state.spectators = { impostor }
state.events[environment.Creature].onDisappear(sergio)
requireValue(beforeDisappear.destroyed and sergio.detachCount == 1 and controller.edgeWidget and
    npcMarker.centered.x == 110, 'NPC disappearance retained stale object authority')
sergio.removed = false
state.spectators = { sergio }
state.events[environment.Creature].onAppear(sergio)
requireValue(controller.attachedWidget and npcMarker.centered.x == 105,
    'NPC appearance did not re-resolve by local name')

local activeWidget, activeMarker = controller.attachedWidget, controller.minimapMarker
state.callbacks[209](nil, 209, clearPacket)
state.callbacks[209](nil, 209, clearPacket)
requireValue(activeWidget.destroyed and activeMarker.destroyed and not controller.target and
    not existingPlayerFlag.destroyed, 'clear was not idempotent or removed an existing player flag')

state.callbacks[209](nil, 209, showPacket('globe'))
local logoutWidget, logoutMarker = controller.attachedWidget or controller.edgeWidget, controller.minimapMarker
controller:onGameEnd()
requireValue(logoutWidget.destroyed and logoutMarker.destroyed and not controller.target,
    'logout did not clean guidance state')
state.callbacks[209](nil, 209, showPacket('araci'))
requireValue(controller.target, 'reconnect did not accept a new show packet')
local terminateWidget = controller.attachedWidget or controller.edgeWidget
controller:onTerminate()
controller:onTerminate()
requireValue(terminateWidget.destroyed and not controller.target and not existingPlayerFlag.destroyed,
    'termination cleanup was not safe and idempotent')
state.callbacks[209](nil, 209, showPacket('sergio'))
state.events[environment.Creature].onAppear()
requireValue(not controller.target, 'stale callbacks recreated guidance after termination')

print('Xibat guidance tests passed')
