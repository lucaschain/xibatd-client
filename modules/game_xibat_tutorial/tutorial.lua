local TUTORIAL_OPCODE = modules.game_xibat_core.XibatOpcode.Tutorial
local PROTOCOL_VERSION = 1

local topics = {
    {
        id = 'Raids',
        title = 'Raid Operations',
        steps = {
            { image = '/game_xibat_tutorial/images/raids/1', text = 'Click the globe to start the raid' },
            { image = '/game_xibat_tutorial/images/raids/2', text = 'Defeat the monster waves to complete the challenge' },
            { image = '/game_xibat_tutorial/images/raids/3', text = 'Use the turret rune on the desired location to create a turret' },
            { image = '/game_xibat_tutorial/images/raids/4', text = 'Click the turret to view more options' },
        },
    },
    {
        id = 'Forge',
        title = 'Rune Forge',
        steps = {
            { image = '/game_xibat_tutorial/images/forge/1', text = 'Use the turret rune on the forge to open the upgrades page' },
            { image = '/game_xibat_tutorial/images/forge/2', text = 'You can choose two branches of a rune to upgrade it' },
            { image = '/game_xibat_tutorial/images/forge/3', text = 'Mix powders to craft upgrade materials' },
        },
    },
    {
        id = 'Ascension',
        title = 'Ascension',
        steps = {
            { image = '/game_xibat_tutorial/images/ascension/1', text = 'Defeat monster waves to gain Ascension experience and spend ascension points on your passive tree.' },
        },
    },
}

local topicsById = {}
for _, topic in ipairs(topics) do topicsById[topic.id] = topic end

xibatTutorialController = Controller:new()
xibatTutorialController:setUI('tutorial')

local function hasExactFields(value, required)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do if not required[field] then return false end end
    for field in pairs(required) do if value[field] == nil then return false end end
    return true
end

local function validateOpen(payload)
    if not hasExactFields(payload, { version = true, action = true, body = true }) or
        payload.version ~= PROTOCOL_VERSION or payload.action ~= 'open' or
        not hasExactFields(payload.body, { topic = true, forceOpen = true }) or
        not topicsById[payload.body.topic] or type(payload.body.forceOpen) ~= 'boolean' then return nil end
    return payload.body
end

local function seenKey(topicId)
    return 'xiba-help-already-saw-topic-' .. topicId
end

function xibatTutorialController:close()
    self.ui:hide()
    if self.button then self.button:setOn(false) end
end

function xibatTutorialController:render()
    local topic = topicsById[self.topicId]
    local step = topic and topic.steps[self.step]
    if not step or not g_resources.fileExists(step.image .. '.png') then return false end
    self.ui.topicTitle:setText(topic.title)
    self.ui.stepCounter:setText(tr('LESSON %d OF %d', self.step, #topic.steps))
    self.ui.screenshot:setImageSource(step.image)
    self.ui.description:setText(step.text)
    self.ui.progress:setValue(self.step / #topic.steps * 100, 0, 100)
    self.ui.previous:setEnabled(self.step > 1)
    self.ui.next:setVisible(self.step < #topic.steps)
    self.ui.close:setVisible(self.step == #topic.steps)
    for _, button in ipairs(self.topicButtons) do
        button:setBackgroundColor(button.topicId == self.topicId and '#566b73' or '#00000000')
    end
    return true
end

function xibatTutorialController:setStep(topicId, stepIndex)
    local topic = topicsById[topicId]
    local step = topic and topic.steps[stepIndex]
    if not step or not g_resources.fileExists(step.image .. '.png') then return false end
    self.topicId = topicId
    self.step = stepIndex
    return self:render()
end

function xibatTutorialController:open(topicId, markSeen)
    if not topicsById[topicId] then return false end
    if not self:setStep(topicId, 1) then return false end
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
    if self.button then self.button:setOn(true) end
    if markSeen then g_settings.set(seenKey(topicId), true) end
    return true
end

function xibatTutorialController:selectTopic(topicId)
    self:open(topicId, false)
end

function xibatTutorialController:previousStep()
    if self.step > 1 then self:setStep(self.topicId, self.step - 1) end
end

function xibatTutorialController:nextStep()
    local topic = topicsById[self.topicId]
    if topic and self.step < #topic.steps then self:setStep(self.topicId, self.step + 1) end
end

function xibatTutorialController:toggle()
    if self.ui:isVisible() then self:close() else self:open(self.topicId or topics[1].id, false) end
end

function xibatTutorialController:onOpcode(_, _, payload)
    local request = validateOpen(payload)
    if not request then return end
    if not request.forceOpen and g_settings.getBoolean(seenKey(request.topic), false) then return end
    self:open(request.topic, not request.forceOpen)
end

function xibatTutorialController:updateLayout(size)
    local width = math.max(300, math.min(720, size.width - 10))
    local height = math.max(300, math.min(600, size.height - 10))
    self.ui:setSize({ width = width, height = height })
    self.ui.screenshot:setHeight(math.max(60, height - 228))
    local buttonWidth = math.max(65, math.floor((width - 78) / #topics))
    for _, button in ipairs(self.topicButtons) do button:setWidth(buttonWidth) end
end

function xibatTutorialController:onInit()
    self.topicId = topics[1].id
    self.step = 1
    self.topicButtons = {}
    self.ui.topicRail:destroyChildren()
    self.ui:hide()
    for _, topic in ipairs(topics) do
        local button = g_ui.createWidget('XibatTutorialTopicButton', self.ui.topicRail)
        if button then
            button.topicId = topic.id
            button:setText(topic.title)
            button.onClick = function() self:selectTopic(topic.id) end
            table.insert(self.topicButtons, button)
        end
    end
    local parent = self.ui:getParent()
    self:updateLayout(parent:getSize())
    self:registerUIEvents(parent, { onGeometryChange = function()
        self:updateLayout(parent:getSize())
    end })
    self.ui.previous.onClick = function() self:previousStep() end
    self.ui.next.onClick = function() self:nextStep() end
    self.ui.close.onClick = function() self:close() end
    self:registerExtendedJSONOpcode(TUTORIAL_OPCODE, function(...) self:onOpcode(...) end)
    self.button = modules.client_topmenu.addRightGameToggleButton('xibatTutorial', tr('Xiba Tutorials'),
        '/images/topbuttons/modulemanager', function() self:toggle() end, false)
    self.button:setOn(false)
end

function xibatTutorialController:onGameStart() self:close() end
function xibatTutorialController:onGameEnd()
    self:close()
    self.topicId = topics[1].id
    self.step = 1
end
function xibatTutorialController:onTerminate()
    self:close()
    if self.button then self.button:destroy() self.button = nil end
end
