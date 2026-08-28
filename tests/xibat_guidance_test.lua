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
requireValue(not moduleSource:match('autoWalk') and not moduleSource:match('walkTo') and
    not moduleSource:match('attachWidget') and not moduleSource:match('setRotation'),
    'guidance must not walk, attach widgets, or rotate them')
requireValue(not moduleSource:match('registerExtendedJSONOpcode') and not moduleSource:match('targetMetadata'),
    'guidance must be a normalized quest-cue renderer, not an opcode/content owner')

local interfaceFile = assert(io.open(root .. '/modules/game_interface/interface.otmod', 'rb'))
local interfaceSource = interfaceFile:read('*a')
interfaceFile:close()
requireValue(interfaceSource:match('%- game_xibat_tutorial%s*\n%s*%- game_xibat_guidance%s*\n%s*%- game_xibat_quests'),
    'Field Manual, guidance renderer, and quest controller load order is incorrect')

local state = { created = {}, visible = true, logs = {}, mapProjection = { x = 274, y = 180 } }
local function makeWidget(kind)
    local widget = { kind = kind, children = {}, width = 176, height = 38 }
    function widget:isDestroyed() return self.destroyed == true end
    function widget:destroy() self.destroyed = true end
    function widget:setText(text) self.text = text end
    function widget:setIcon(icon) self.icon = icon end
    function widget:setTooltip(text) self.tooltip = text end
    function widget:setPosition(position) self.position = position end
    function widget:getWidth() return self.width end
    function widget:getHeight() return self.height end
    function widget:insertChild(index, child) table.insert(self.children, index, child) end
    if kind == 'XibatGuidanceEdge' then widget.label = makeWidget('label') end
    table.insert(state.created, widget)
    return widget
end

local player = { position = { x = 100, y = 100, z = 7 } }
function player:getPosition() return self.position end
local panel = makeWidget('map')
panel.width, panel.height = 400, 300
function panel:getRect() return { x = 20, y = 30, width = self.width, height = self.height } end
function panel:isInRange() return state.visible end
function panel:getCameraPosition() return player.position end
function panel:getMapPositionPoint() return state.mapProjection end
function panel:getCreaturePositionPoint(creature) return creature.projection end
function panel:getSpectators(multifloor) state.multifloor = multifloor return state.spectators or {} end
local minimap = makeWidget('minimap')
local existingFlag = makeWidget('existingFlag')
table.insert(minimap.children, existingFlag)
function minimap:centerInPosition(marker, position) marker.centered = position end

local environment = {
    modules = {
        game_interface = { getMapPanel = function() return panel end },
        game_minimap = { getMiniMapUi = function() return minimap end },
    },
    Controller = {}, Creature = {}, LocalPlayer = {}, UIMap = {}, g_ui = {}, g_game = {}, g_logger = {},
}
function environment.Controller:new()
    local controller = {}
    function controller:registerEvents(actor, events) state.events = state.events or {} state.events[actor] = events end
    function controller:cycleEvent(callback, delay) state.refresh = callback state.delay = delay return callback end
    function controller:removeEvent(event) if state.refresh == event then state.refresh = nil end end
    return controller
end
function environment.g_ui.importStyle(path) state.style = path end
function environment.g_ui.createWidget(kind, parent)
    local widget = makeWidget(kind)
    if parent then parent:insertChild(1, widget) end
    return widget
end
function environment.g_game.isOnline() return true end
function environment.g_game.getLocalPlayer() return player end
function environment.g_logger.warning(message) table.insert(state.logs, message) end

loadModule('modules/game_xibat_guidance/guidance.lua', environment)
local controller = environment.xibatGuidanceController
controller:onInit()
local cue = {
    id = 'arrival:meet_scout', kind = 'position', label = 'Meet the scout', creatureName = '',
    position = { x = 102, y = 100, z = 7 },
}
controller:setQuestCue(cue)
requireValue(controller.target and not controller.edgeWidget and not controller.minimapMarker,
    'cue rendered before game start')
controller:onGameStart()
requireValue(controller.edgeWidget and controller.edgeWidget.label.text == 'Meet the scout' and
    controller.minimapMarker and minimap.children[1] == controller.minimapMarker and
    not existingFlag.destroyed and state.delay == 16 and state.refresh,
    'deferred cue did not use projection, owned marker, and one 16ms refresh')

state.visible = false
state.events[environment.UIMap].onZoomChange()
requireValue(controller.edgeWidget.label.text == '[E] Meet the scout', 'edge compass cue was not rendered')
local oldWidget, oldMarker = controller.edgeWidget, controller.minimapMarker
controller:clearQuestCue()
controller:clearQuestCue()
requireValue(oldWidget.destroyed and oldMarker.destroyed and not state.refresh and not existingFlag.destroyed,
    'cue cleanup was not idempotent or violated minimap ownership')

local npc = { position = { x = 104, y = 103, z = 7 }, projection = { x = 330, y = 190 } }
function npc:isRemoved() return false end
function npc:isNpc() return true end
function npc:getName() return 'Scout Elian' end
function npc:getPosition() return self.position end
state.spectators = { npc }
state.visible = true
controller:setQuestCue({
    id = 'arrival:meet_scout', kind = 'creature', label = 'Speak with Elian', creatureName = 'Scout Elian',
    position = { x = 110, y = 110, z = 7 },
})
requireValue(controller.edgeWidget.label.text == 'Speak with Elian' and
    controller.minimapMarker.centered.x == 104 and state.multifloor == false,
    'creature cue did not use native creature projection and NPC resolution')
local terminateWidget = controller.edgeWidget
controller:onTerminate()
controller:onTerminate()
controller:setQuestCue(cue)
requireValue(terminateWidget.destroyed and not controller.target and not existingFlag.destroyed,
    'termination was not idempotent or accepted a stale cue')

print('Xibat guidance tests passed')
