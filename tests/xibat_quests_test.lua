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

local state = { callbacks = {}, guidance = {}, logs = {} }
local function makeWidget(kind)
    local widget = { kind = kind, children = {}, visible = true, size = { width = 800, height = 600 } }
    function widget:isDestroyed() return self.destroyed == true end
    function widget:destroy() self.destroyed = true end
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:isVisible() return self.visible end
    function widget:raise() end
    function widget:focus() end
    function widget:setOn(value) self.on = value end
    function widget:setText(value) self.text = value end
    function widget:setColor(value) self.color = value end
    function widget:setVisible(value) self.visible = value end
    function widget:setValue(value) self.value = value end
    function widget:setSize(value) self.size = value end
    function widget:setWidth(value) self.width = value end
    function widget:setPosition(value) self.position = value end
    function widget:getSize() return self.size end
    function widget:getParent() return self.parent end
    function widget:insertChild(_, child) table.insert(self.children, child) end
    if kind == 'XibatQuestCard' then
        for _, id in ipairs({ 'title', 'status', 'objective', 'progress', 'progressText' }) do widget[id] = makeWidget(id) end
    elseif kind == 'XibatQuestTracker' then
        for _, id in ipairs({ 'title', 'status', 'objective', 'progress', 'progressText' }) do widget[id] = makeWidget(id) end
    end
    return widget
end

local parent = makeWidget('root')
parent.size = { width = 640, height = 360 }
local ui = makeWidget('journal')
ui.parent = parent
for _, id in ipairs({ 'questList', 'summary', 'emptyState' }) do ui[id] = makeWidget(id) end
local mapPanel = makeWidget('map')
function mapPanel:getRect() return { x = 10, y = 20, width = 500, height = 320 } end

local guidance = {}
function guidance:setQuestCue(cue) state.guidance.cue = cue state.guidance.setCount = (state.guidance.setCount or 0) + 1 end
function guidance:clearQuestCue() state.guidance.cue = nil state.guidance.clearCount = (state.guidance.clearCount or 0) + 1 end
local legacyQuestLog = {}
function legacyQuestLog:setNativeQuestSnapshot(snapshot) state.legacySnapshot = snapshot end
local environment = {
    modules = {
        game_xibat_core = { XibatOpcode = { QuestJournal = 210 } },
        game_xibat_guidance = { xibatGuidanceController = guidance },
        game_questlog = { questLogController = legacyQuestLog },
        game_interface = { getMapPanel = function() return mapPanel end },
        client_topmenu = {},
    },
    Controller = {}, g_ui = {}, g_logger = {}, tr = function(text) return text end,
    g_game = {
        isOnline = function() return true end,
        getProtocolGame = function()
            return {
                sendExtendedJSONOpcode = function(_, opcode, payload)
                    state.syncRequest = { opcode = opcode, payload = payload }
                end,
            }
        end,
    },
}
function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:registerUIEvents(_, events) state.uiEvents = events end
    function controller:registerEvents(_, events) state.mapEvents = events end
    return controller
end
function environment.g_ui.createWidget(kind, owner)
    local widget = makeWidget(kind)
    if owner then table.insert(owner.children, widget) end
    return widget
end
function environment.g_logger.warning(message) table.insert(state.logs, message) end
function environment.modules.client_topmenu.addRightGameToggleButton(_, _, _, callback)
    local button = makeWidget('button')
    button.callback = callback
    return button
end

local function cue(kind)
    return {
        kind = kind or 'position', label = 'Reach the east gate',
        position = { x = 32000, y = 32100, z = 7 },
        creatureName = kind == 'creature' and 'Gate Warden' or '',
    }
end
local function stage(id, current, total, completed, stageCue)
    return {
        id = id, objective = 'Reach the east gate', completed = completed or false,
        progress = { current = current or 0, total = total or 1 }, cue = stageCue == nil and cue() or stageCue,
    }
end
local function quest(id, current, completed, stages)
    return {
        id = id, title = id == 'arrival' and 'First Watch' or 'Second Quest', completed = completed or false,
        currentStageId = current or 'reach_gate', stages = stages or { stage('reach_gate') },
    }
end
local function snapshot(revision, quests, active)
    return { version = 1, type = 'snapshot', revision = revision, quests = quests, active = active }
end
local function active(id, stageId) return { questId = id, stageId = stageId or 'reach_gate' } end

loadModule('modules/game_xibat_quests/quests.lua', environment)
local controller = environment.xibatQuestController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[210] and controller.uiName == 'quests' and not ui.visible and
    ui.size.width == 628 and ui.size.height == 348 and not controller.button,
    'quest module did not initialize opcode and its hidden compatibility view')

local valid = snapshot(7, { quest('arrival', 'reach_gate') }, active('arrival'))
state.callbacks[210](nil, 210, valid)
requireValue(controller.revision == 7 and #controller.quests == 1 and #controller.cards == 1 and
    controller.cards[1].title.text == 'First Watch' and
    controller.cards[1].objective.text == 'Reach the east gate' and
    controller.cards[1].progressText.text == '0 / 1' and not controller.tracker and
    state.legacySnapshot and state.legacySnapshot.revision == 7 and
    state.guidance.cue and state.guidance.cue.id == 'arrival:reach_gate' and
    state.guidance.cue.label == 'Reach the east gate',
    'valid snapshot did not atomically render journal and normalized active cue')
controller:onGameStart()
requireValue(controller.tracker and controller.tracker.title.text == 'First Watch' and
    controller.tracker.objective.text == 'Reach the east gate' and controller.tracker.position.x == 206 and
    state.syncRequest and state.syncRequest.opcode == 210 and state.syncRequest.payload.version == 1 and
    state.syncRequest.payload.action == 'sync',
    'game-start deferral did not create the compact active tracker')

local tooManyQuests = {}
for index = 1, 65 do table.insert(tooManyQuests, quest('quest.' .. index)) end
local tooManyStages = {}
for index = 1, 33 do table.insert(tooManyStages, stage('stage.' .. index)) end
local invalid = {
    nil,
    {},
    { version = 2, type = 'snapshot', revision = 8, quests = {}, active = false },
    { version = 1, type = 'snapshot', revision = 8, quests = {}, active = false, extra = true },
    snapshot(8, { quest('Arrival') }, false),
    snapshot(8, { quest(string.rep('a', 65)) }, false),
    snapshot(8, { quest('arrival', 'missing') }, false),
    snapshot(8, { quest('arrival', 'reach_gate', false, { stage('reach_gate', 2, 1) }) }, active('arrival')),
    snapshot(8, { quest('arrival', 'reach_gate', false, { stage('reach_gate', 0, 1, false, {
        kind = 'npc', label = 'Bad kind', position = { x = 1, y = 2, z = 7 }, creatureName = 'Npc',
    }) }) }, active('arrival')),
    snapshot(8, { quest('arrival'), quest('arrival') }, active('arrival')),
    snapshot(8, { quest('arrival') }, active('arrival', 'other')),
    snapshot(8, tooManyQuests, false),
    snapshot(8, { quest('arrival', 'stage.1', false, tooManyStages) }, false),
    snapshot(8, { quest('arrival', 'reach_gate', false, {
        { id = 'reach_gate', objective = string.rep('x', 321), completed = false,
            progress = { current = 0, total = 1 }, cue = false },
    }) }, false),
    { version = 1, type = 'delta', baseRevision = 6, revision = 7, upsert = {}, remove = {}, active = false },
    { version = 1, type = 'delta', baseRevision = 7, revision = 9, upsert = {}, remove = {}, active = false },
    { version = 1, type = 'delta', baseRevision = 7, revision = 8.5, upsert = {}, remove = {}, active = false },
}
for _, payload in ipairs(invalid) do
    local ok = pcall(state.callbacks[210], nil, 210, payload)
    requireValue(ok and controller.revision == 7 and controller.quests[1].id == 'arrival',
        'invalid packet escaped or partially changed committed state')
end

local completedQuest = quest('arrival', '', true, { stage('reach_gate', 1, 1, true, false) })
local nextQuest = quest('second', 'reach_gate')
local delta = {
    version = 1, type = 'delta', baseRevision = 7, revision = 8,
    upsert = { completedQuest, nextQuest }, remove = {}, active = active('arrival'),
}
state.callbacks[210](nil, 210, delta)
requireValue(controller.revision == 8 and #controller.quests == 2 and
    controller.cards[1].status.text == 'COMPLETED' and controller.cards[1].progressText.text == 'Complete' and
    controller.tracker.title.text == 'First Watch' and controller.tracker.status.text == 'COMPLETED' and
    controller.tracker.progressText.text == 'Complete' and not state.guidance.cue,
    'valid delta did not preserve order or show completion in journal and tracker')

state.callbacks[210](nil, 210, {
    version = 1, type = 'delta', baseRevision = 8, revision = 9,
    upsert = {}, remove = {}, active = active('second'),
})
requireValue(controller.tracker.title.text == 'Second Quest' and
    controller.tracker.status.text == 'ACTIVE' and state.guidance.cue.id == 'second:reach_gate',
    'active switch did not select exactly one tracker and guidance cue')

state.callbacks[210](nil, 210, {
    version = 1, type = 'delta', baseRevision = 9, revision = 10,
    upsert = {}, remove = { 'arrival', 'second' }, active = false,
})
requireValue(controller.revision == 10 and #controller.quests == 0 and ui.emptyState.visible and
    not controller.tracker and not state.guidance.cue,
    'removal delta did not clear journal, tracker, and guidance')

parent.size = { width = 360, height = 700 }
state.uiEvents.onGeometryChange()
requireValue(ui.size.width == 348 and ui.size.height == 620, 'journal did not respond to portrait geometry')
controller:onGameEnd()
controller:onGameEnd()
requireValue(not controller.hasSnapshot and #controller.quests == 0 and not controller.tracker and
    not state.legacySnapshot, 'game-end cleanup was not idempotent')
controller:onTerminate()
controller:onTerminate()
state.callbacks[210](nil, 210, valid)
requireValue(not controller.hasSnapshot, 'termination accepted stale packets')

print('Xibat quest journal tests passed')
