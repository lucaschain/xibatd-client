local QUEST_OPCODE = modules.game_xibat_core.XibatOpcode.QuestJournal
local PROTOCOL_VERSION = 1
local MAX_REVISION = 2147483647
local MAX_QUESTS = 64
local MAX_STAGES_PER_QUEST = 32
local MAX_TOTAL_STAGES = 512
local MAX_DELTA_UPSERTS = 32
local MAX_DELTA_REMOVALS = 64
local MAX_ID_BYTES = 64
local MAX_TITLE_BYTES = 96
local MAX_OBJECTIVE_BYTES = 320
local MAX_CUE_LABEL_BYTES = 160
local MAX_CREATURE_NAME_BYTES = 64
local MAX_PROGRESS = 1000000000
local PRESENTATION_SETTINGS = 'xibatQuestPresentation'

-- Opcode 210 v1 accepts exact-field JSON snapshots and deltas. Deltas replace whole quests and
-- must advance the committed revision by one. `active` and each stage `cue` are either false or
-- exact records; an active reference names either the current incomplete stage or a completed stage
-- retained in the tracker. Only an incomplete stage with a cue drives world guidance.
-- Stable quest/stage IDs are lowercase ASCII identifiers and are never inferred from display text.

xibatQuestController = Controller:new()
xibatQuestController:setUI('quests')

local function log(message)
    g_logger.warning('[XibatQuests] ' .. message)
end

local function characterKey()
    local name = g_game.getCharacterName and g_game.getCharacterName() or ''
    return string.lower(name or '')
end

local function presentationSettings()
    local settings = g_settings.getNode(PRESENTATION_SETTINGS) or {}
    settings.characters = settings.characters or {}
    local key = characterKey()
    settings.characters[key] = settings.characters[key] or { tracked = {} }
    settings.characters[key].tracked = settings.characters[key].tracked or {}
    return settings, settings.characters[key]
end

local function hasExactFields(value, required)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do if not required[field] then return false end end
    for field in pairs(required) do if value[field] == nil then return false end end
    return true
end

local function isInteger(value, minimum, maximum)
    return type(value) == 'number' and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isArray(value, maximum)
    if type(value) ~= 'table' or #value > maximum then return false end
    local count = 0
    for key in pairs(value) do
        if not isInteger(key, 1, maximum) then return false end
        count = count + 1
    end
    return count == #value
end

local function validId(value, allowEmpty)
    if type(value) ~= 'string' or #value > MAX_ID_BYTES then return false end
    if value == '' then return allowEmpty == true end
    return value:match('^[a-z0-9][a-z0-9_.:%-]*$') ~= nil
end

local function validText(value, maximum, allowEmpty)
    return type(value) == 'string' and #value <= maximum and (allowEmpty or #value > 0) and
        not value:find('[%z\1-\8\11\12\14-\31\127]')
end

local function validatePosition(value)
    return hasExactFields(value, { x = true, y = true, z = true }) and
        isInteger(value.x, 0, 65535) and isInteger(value.y, 0, 65535) and isInteger(value.z, 0, 15)
end

local function validateCue(value)
    if value == false then return false end
    if not hasExactFields(value, {
        kind = true, label = true, position = true, creatureName = true,
    }) or (value.kind ~= 'position' and value.kind ~= 'creature') or
        not validText(value.label, MAX_CUE_LABEL_BYTES) or not validatePosition(value.position) or
        not validText(value.creatureName, MAX_CREATURE_NAME_BYTES, value.kind == 'position') or
        (value.kind == 'position' and value.creatureName ~= '') then return nil end

    return {
        kind = value.kind,
        label = value.label,
        creatureName = value.creatureName,
        position = { x = value.position.x, y = value.position.y, z = value.position.z },
    }
end

local function validateStage(value)
    if not hasExactFields(value, {
        id = true, objective = true, completed = true, progress = true, cue = true,
    }) or not validId(value.id) or not validText(value.objective, MAX_OBJECTIVE_BYTES) or
        type(value.completed) ~= 'boolean' or
        not hasExactFields(value.progress, { current = true, total = true }) or
        not isInteger(value.progress.current, 0, MAX_PROGRESS) or
        not isInteger(value.progress.total, 0, MAX_PROGRESS) or
        value.progress.current > value.progress.total then return nil end
    local cue = validateCue(value.cue)
    if cue == nil then return nil end
    return {
        id = value.id,
        objective = value.objective,
        completed = value.completed,
        progress = { current = value.progress.current, total = value.progress.total },
        cue = cue,
    }
end

local function validateQuest(value)
    if not hasExactFields(value, {
        id = true, title = true, completed = true, currentStageId = true, stages = true,
    }) or not validId(value.id) or not validText(value.title, MAX_TITLE_BYTES) or
        type(value.completed) ~= 'boolean' or not validId(value.currentStageId, true) or
        not isArray(value.stages, MAX_STAGES_PER_QUEST) or #value.stages == 0 then return nil end

    local quest = {
        id = value.id,
        title = value.title,
        completed = value.completed,
        currentStageId = value.currentStageId,
        stages = {},
        stagesById = {},
    }
    for _, rawStage in ipairs(value.stages) do
        local stage = validateStage(rawStage)
        if not stage or quest.stagesById[stage.id] then return nil end
        table.insert(quest.stages, stage)
        quest.stagesById[stage.id] = stage
    end
    if quest.completed then
        if quest.currentStageId ~= '' then return nil end
    else
        local current = quest.stagesById[quest.currentStageId]
        if not current or current.completed then return nil end
    end
    return quest
end

local function validateActive(value, questsById)
    if value == false then return false end
    if not hasExactFields(value, { questId = true, stageId = true }) or
        not validId(value.questId) or not validId(value.stageId) then return nil end
    local quest = questsById[value.questId]
    local stage = quest and quest.stagesById[value.stageId]
    if not quest or not stage then return nil end
    if quest.completed then
        if not stage.completed then return nil end
    elseif quest.currentStageId ~= value.stageId or stage.completed then
        return nil
    end
    return { questId = value.questId, stageId = value.stageId }
end

local function validateQuestArray(value, maximum)
    if not isArray(value, maximum) then return nil end
    local quests, byId, stageCount = {}, {}, 0
    for _, rawQuest in ipairs(value) do
        local quest = validateQuest(rawQuest)
        if not quest or byId[quest.id] then return nil end
        stageCount = stageCount + #quest.stages
        if stageCount > MAX_TOTAL_STAGES then return nil end
        table.insert(quests, quest)
        byId[quest.id] = quest
    end
    return quests, byId
end

local function validateSnapshot(payload)
    if not hasExactFields(payload, {
        version = true, type = true, revision = true, quests = true, active = true,
    }) or payload.version ~= PROTOCOL_VERSION or payload.type ~= 'snapshot' or
        not isInteger(payload.revision, 0, MAX_REVISION) then return nil end
    local quests, byId = validateQuestArray(payload.quests, MAX_QUESTS)
    if not quests then return nil end
    local active = validateActive(payload.active, byId)
    if active == nil then return nil end
    return { revision = payload.revision, quests = quests, questsById = byId, active = active }
end

local function validateDelta(controller, payload)
    if not hasExactFields(payload, {
        version = true, type = true, baseRevision = true, revision = true,
        upsert = true, remove = true, active = true,
    }) or payload.version ~= PROTOCOL_VERSION or payload.type ~= 'delta' or
        not controller.hasSnapshot or not isInteger(payload.baseRevision, 0, MAX_REVISION) or
        not isInteger(payload.revision, 0, MAX_REVISION) or
        payload.baseRevision ~= controller.revision or payload.revision ~= payload.baseRevision + 1 then return nil end
    local upserts, upsertsById = validateQuestArray(payload.upsert, MAX_DELTA_UPSERTS)
    if not upserts or not isArray(payload.remove, MAX_DELTA_REMOVALS) then return nil end
    local removed = {}
    for _, id in ipairs(payload.remove) do
        if not validId(id) or removed[id] or upsertsById[id] then return nil end
        removed[id] = true
    end

    local quests, byId = {}, {}
    for _, oldQuest in ipairs(controller.quests) do
        if not removed[oldQuest.id] then
            local quest = upsertsById[oldQuest.id] or oldQuest
            table.insert(quests, quest)
            byId[quest.id] = quest
            upsertsById[oldQuest.id] = nil
        end
    end
    for _, quest in ipairs(upserts) do
        if upsertsById[quest.id] then
            table.insert(quests, quest)
            byId[quest.id] = quest
        end
    end
    if #quests > MAX_QUESTS then return nil end
    local stageCount = 0
    for _, quest in ipairs(quests) do stageCount = stageCount + #quest.stages end
    if stageCount > MAX_TOTAL_STAGES then return nil end
    local active = validateActive(payload.active, byId)
    if active == nil then return nil end
    return { revision = payload.revision, quests = quests, questsById = byId, active = active }
end

local function currentStage(quest)
    if not quest then return nil end
    if quest.currentStageId ~= '' then return quest.stagesById[quest.currentStageId] end
    return quest.stages[#quest.stages]
end

local function progressText(stage)
    if not stage then return '' end
    return string.format('%d / %d', stage.progress.current, stage.progress.total)
end

local function setProgress(widget, stage, completed)
    local total = stage and stage.progress.total or 0
    local current = stage and stage.progress.current or 0
    local percent = completed and 100 or (total > 0 and current / total * 100 or 0)
    widget:setValue(percent, 0, 100)
end

function xibatQuestController:destroyTracker()
    local tracker = self.tracker
    self.tracker = nil
    self.trackerKey = nil
    if tracker and not tracker:isDestroyed() then tracker:destroy() end
end

function xibatQuestController:isQuestTracked(questId)
    local _, character = presentationSettings()
    local tracked = character.tracked[questId]
    if tracked ~= nil then return tracked == true end
    return self.active ~= false and self.active.questId == questId
end

function xibatQuestController:setQuestTracked(questId, tracked)
    if type(questId) ~= 'string' or not self.questsById[questId] then return end
    local settings, character = presentationSettings()
    character.tracked[questId] = tracked == true
    g_settings.setNode(PRESENTATION_SETTINGS, settings)
    if tracked and self.active ~= false and self.active.questId == questId then
        self.dismissedTrackerKey = nil
    end
    self:renderTracker()
    self:updateGuidance()
end

function xibatQuestController:onTrackerMoved(widget)
    local panel = modules.game_interface.getMapPanel()
    if not widget or not panel or panel:isDestroyed() then return end
    local position = widget:getPosition()
    local rect = panel:getRect()
    local settings, character = presentationSettings()
    character.trackerPosition = { x = position.x - rect.x, y = position.y - rect.y }
    g_settings.setNode(PRESENTATION_SETTINGS, settings)
end

function xibatQuestController:dismissTracker()
    if self.active == false then return end
    self.dismissedTrackerKey = self.active.questId .. ':' .. self.active.stageId
    self:destroyTracker()
end

function xibatQuestController:clearCards()
    if self.ui and self.ui.questList then self.ui.questList:destroyChildren() end
    self.cards = {}
end

function xibatQuestController:activeQuestAndStage()
    if self.active == false then return nil, nil end
    local quest = self.questsById[self.active.questId]
    return quest, quest and quest.stagesById[self.active.stageId] or nil
end

function xibatQuestController:renderJournal()
    self:clearCards()
    local completed = 0
    for _, quest in ipairs(self.quests) do
        local stage = currentStage(quest)
        local card = g_ui.createWidget('XibatQuestCard', self.ui.questList)
        if card then
            card.title:setText(quest.title)
            card.status:setText(quest.completed and 'COMPLETED' or 'IN PROGRESS')
            card.status:setColor(quest.completed and '#74be92' or '#8fa6af')
            card.objective:setText(stage.objective)
            card.progressText:setText(quest.completed and 'Complete' or progressText(stage))
            setProgress(card.progress, stage, quest.completed)
            table.insert(self.cards, card)
        end
        if quest.completed then completed = completed + 1 end
    end
    self.ui.summary:setText(string.format('%d quests  |  %d completed', #self.quests, completed))
    self.ui.emptyState:setVisible(#self.quests == 0)
end

function xibatQuestController:renderTracker()
    self:destroyTracker()
    if not self.gameReady then return end
    local quest, stage = self:activeQuestAndStage()
    if not quest or not stage then return end
    local trackerKey = self.active.questId .. ':' .. self.active.stageId
    if not self:isQuestTracked(quest.id) or self.dismissedTrackerKey == trackerKey then return end
    local panel = modules.game_interface.getMapPanel()
    if not panel or panel:isDestroyed() then return end
    local tracker = g_ui.createWidget('XibatQuestTracker', panel)
    if not tracker then return end
    tracker.closeButton.onClick = function() self:dismissTracker() return true end
    tracker.onDragLeave = function(widget) self:onTrackerMoved(widget) end
    tracker.title:setText(quest.title)
    tracker.objective:setText(stage.objective)
    tracker.status:setText(quest.completed and 'COMPLETED' or 'ACTIVE')
    tracker.status:setColor(quest.completed and '#74be92' or '#7fc5a0')
    tracker.progressText:setText(quest.completed and 'Complete' or progressText(stage))
    setProgress(tracker.progress, stage, quest.completed)
    local rect = panel:getRect()
    local width = math.max(220, math.min(292, rect.width - 24))
    tracker:setWidth(width)
    local _, character = presentationSettings()
    local position = character.trackerPosition
    if position and type(position.x) == 'number' and type(position.y) == 'number' then
        tracker:setPosition({ x = rect.x + position.x, y = rect.y + position.y })
        tracker:bindRectToParent()
    else
        tracker:setPosition({ x = rect.x + rect.width - width - 12, y = rect.y + 12 })
    end
    self.trackerKey = trackerKey
    self.tracker = tracker
end

function xibatQuestController:updateGuidance()
    local quest, stage = self:activeQuestAndStage()
    if quest and self:isQuestTracked(quest.id) and not quest.completed and stage and stage.cue ~= false then
        local cue = stage.cue
        modules.game_xibat_guidance.xibatGuidanceController:setQuestCue({
            id = self.active.questId .. ':' .. self.active.stageId,
            kind = cue.kind,
            label = cue.label,
            creatureName = cue.creatureName,
            position = cue.position,
        })
    else
        modules.game_xibat_guidance.xibatGuidanceController:clearQuestCue()
    end
end

function xibatQuestController:commit(state)
    self.revision = state.revision
    self.hasSnapshot = true
    self.quests = state.quests
    self.questsById = state.questsById
    self.active = state.active
    local questLog = modules.game_questlog and modules.game_questlog.questLogController
    if questLog and questLog.setNativeQuestSnapshot then questLog:setNativeQuestSnapshot(state) end
    self:renderJournal()
    self:renderTracker()
    self:updateGuidance()
end

function xibatQuestController:onOpcode(_, _, payload)
    if self.terminated or type(payload) ~= 'table' then return end
    local state
    if payload.type == 'snapshot' then
        state = validateSnapshot(payload)
    elseif payload.type == 'delta' then
        state = validateDelta(self, payload)
    end
    if not state then
        log('opcode 210 v1 payload rejected')
        return
    end
    self:commit(state)
end

function xibatQuestController:updateLayout(size)
    self.ui:setSize({
        width = math.max(320, math.min(640, size.width - 12)),
        height = math.max(300, math.min(620, size.height - 12)),
    })
end

function xibatQuestController:close()
    self.ui:hide()
    if self.button then self.button:setOn(false) end
end

function xibatQuestController:toggle()
    if self.ui:isVisible() then
        self:close()
    else
        self.ui:show()
        self.ui:raise()
        self.ui:focus()
        if self.button then self.button:setOn(true) end
    end
end

function xibatQuestController:reset()
    self.hasSnapshot = false
    self.revision = nil
    self.quests = {}
    self.questsById = {}
    self.active = false
    self.dismissedTrackerKey = nil
    self.trackerKey = nil
    local questLog = modules.game_questlog and modules.game_questlog.questLogController
    if questLog and questLog.setNativeQuestSnapshot then questLog:setNativeQuestSnapshot(nil) end
    self:renderJournal()
    self:destroyTracker()
    modules.game_xibat_guidance.xibatGuidanceController:clearQuestCue()
end

function xibatQuestController:onInit()
    self.terminated = false
    self.gameReady = false
    self.cards = {}
    self.quests = {}
    self.questsById = {}
    self.active = false
    self.dismissedTrackerKey = nil
    self.trackerKey = nil
    if self.ui.previewTracker then self.ui.previewTracker:destroy() end
    self.ui:hide()
    self:renderJournal()
    local parent = self.ui:getParent()
    self:updateLayout(parent:getSize())
    self:registerUIEvents(parent, { onGeometryChange = function() self:updateLayout(parent:getSize()) end })
    local panel = modules.game_interface.getMapPanel()
    if panel then self:registerEvents(panel, { onGeometryChange = function() self:renderTracker() end }) end
    self:registerExtendedJSONOpcode(QUEST_OPCODE, function(...) self:onOpcode(...) end)
end

function xibatQuestController:onGameStart()
    self.gameReady = true
    self:renderTracker()
    self:updateGuidance()
    if g_game.isOnline() then
        g_game.getProtocolGame():sendExtendedJSONOpcode(QUEST_OPCODE, { version = PROTOCOL_VERSION, action = 'sync' })
    end
end

function xibatQuestController:onGameEnd()
    self.gameReady = false
    self:close()
    self:reset()
end

function xibatQuestController:onTerminate()
    if self.terminated then return end
    self.terminated = true
    self.gameReady = false
    self:close()
    self:destroyTracker()
    modules.game_xibat_guidance.xibatGuidanceController:clearQuestCue()
    if self.button then self.button:destroy() self.button = nil end
end
