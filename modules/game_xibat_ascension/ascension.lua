local ASCENSION_OPCODE = modules.game_xibat_core.XibatOpcode.Ascension
local REQUEST_TIMEOUT = 5000
local MAX_CATEGORIES = 13
local MAX_PASSIVES = 10

local iconPaths = {
    crystal_elemental_resist = '/game_xibat_ascension/images/passives/crystal_elemental_resist',
    crystal_health_regen = '/game_xibat_ascension/images/passives/crystal_health_regen',
    crystal_max_health = '/game_xibat_ascension/images/passives/crystal_max_health',
    crystal_physical_resist = '/game_xibat_ascension/images/passives/crystal_physical_resist',
    player_elemental_resist = '/game_xibat_ascension/images/passives/player_elemental_resist',
    player_physical_resist = '/game_xibat_ascension/images/passives/player_physical_resist',
    raid_start_level = '/game_xibat_ascension/images/passives/raid_start_level',
    turret_elemental_damage = '/game_xibat_ascension/images/passives/turret_elemental_damage',
    turret_physical_damage = '/game_xibat_ascension/images/passives/turret_physical_damage',
}

local resultMessages = {
    category_complete = 'That path is already complete.',
    invalid_milestone = 'That milestone is no longer available.',
    not_enough_points = 'You do not have enough Ascension Points.',
    state_changed = 'Your Ascension progress changed. The board has been refreshed.',
}

xibatAscensionController = Controller:new()
xibatAscensionController:setUI('ascension')

local function isIntegerInRange(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge and
        value == math.floor(value) and value >= minimum and value <= maximum
end

local function isText(value, maximum)
    return type(value) == 'string' and value ~= '' and #value <= maximum and not value:find('%c')
end

local function hasExactFields(value, required, optional)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do
        if not required[field] and not (optional and optional[field]) then return false end
    end
    for field in pairs(required) do if value[field] == nil then return false end end
    return true
end

local progressFields = {
    level = true, levelExperience = true, levelExperienceRequired = true, levelProgress = true,
    availablePoints = true, totalSpentPoints = true, spentPoints = true,
}
local categoryFields = { id = true, name = true, spentPoints = true, maxPoints = true, passives = true }
local passiveFields = { name = true, cost = true, unlockPoints = true, raidLevel = true, previewItems = true }
local passiveOptionalFields = { icon = true }
local itemFields = { clientId = true, name = true, count = true }

local function validateProgress(progress)
    if not hasExactFields(progress, progressFields) or not isIntegerInRange(progress.level, 1, 100000) or
        not isIntegerInRange(progress.levelExperience, 0, 2147483647) or
        not isIntegerInRange(progress.levelExperienceRequired, 1, 2147483647) or
        progress.levelExperience > progress.levelExperienceRequired or type(progress.levelProgress) ~= 'number' or
        progress.levelProgress < 0 or progress.levelProgress > 1 or
        not isIntegerInRange(progress.availablePoints, 0, 2147483647) or
        not isIntegerInRange(progress.totalSpentPoints, 0, 2147483647) or type(progress.spentPoints) ~= 'table' then
        return false
    end
    return true
end

local function validateView(payload)
    if not hasExactFields(payload, { action = true, body = true }) or payload.action ~= 'ascensionView' or
        not hasExactFields(payload.body, { progress = true, categories = true }) or
        not validateProgress(payload.body.progress) or type(payload.body.categories) ~= 'table' or
        #payload.body.categories ~= MAX_CATEGORIES then return nil end
    local seen = {}
    for _, category in ipairs(payload.body.categories) do
        if not hasExactFields(category, categoryFields) or not isIntegerInRange(category.id, 1, MAX_CATEGORIES) or
            seen[category.id] or not isText(category.name, 64) or
            not isIntegerInRange(category.spentPoints, 0, 1000) or
            not isIntegerInRange(category.maxPoints, 1, 1000) or category.spentPoints > category.maxPoints or
            type(category.passives) ~= 'table' or #category.passives ~= MAX_PASSIVES then return nil end
        seen[category.id] = true
        local cumulative = 0
        for _, passive in ipairs(category.passives) do
            if not hasExactFields(passive, passiveFields, passiveOptionalFields) or not isText(passive.name, 128) or
                not isIntegerInRange(passive.cost, 1, 30) or
                not isIntegerInRange(passive.unlockPoints, 1, 1000) or passive.unlockPoints <= cumulative or
                not isIntegerInRange(passive.raidLevel, 1, 1000) or type(passive.previewItems) ~= 'table' or
                #passive.previewItems > 4 or (passive.icon and not iconPaths[passive.icon]) then return nil end
            cumulative = passive.unlockPoints
            for _, item in ipairs(passive.previewItems) do
                if not hasExactFields(item, itemFields) or not isIntegerInRange(item.clientId, 1, 65535) or
                    not isText(item.name, 128) or not isIntegerInRange(item.count, 1, 65535) then return nil end
            end
        end
        if cumulative ~= category.maxPoints or payload.body.progress.spentPoints[tostring(category.id)] ~= category.spentPoints then
            return nil
        end
    end
    return payload.body
end

local function validateResult(payload)
    local bodyFields = { operation = true, requestId = true, ok = true, code = true, state = true }
    if not hasExactFields(payload, { action = true, body = true }) or payload.action ~= 'ascensionResult' or
        not hasExactFields(payload.body, bodyFields) then return nil end
    local body, state = payload.body, payload.body.state
    if (body.operation ~= 'spend' and body.operation ~= 'reset') or
        not isIntegerInRange(body.requestId, 1, 2147483647) or type(body.ok) ~= 'boolean' or
        type(body.code) ~= 'string' or type(state) ~= 'table' then return nil end
    local required = {
        level = true, levelExperience = true, levelExperienceRequired = true, levelProgress = true,
        availablePoints = true, totalSpentPoints = true,
    }
    if body.operation == 'spend' then required.categoryId = true required.spentPoints = true else required.reset = true end
    if not hasExactFields(state, required) then return nil end
    if not isIntegerInRange(state.level, 1, 100000) or
        not isIntegerInRange(state.levelExperience, 0, 2147483647) or
        not isIntegerInRange(state.levelExperienceRequired, 1, 2147483647) or
        state.levelExperience > state.levelExperienceRequired or type(state.levelProgress) ~= 'number' or
        state.levelProgress < 0 or state.levelProgress > 1 or
        not isIntegerInRange(state.availablePoints, 0, 2147483647) or
        not isIntegerInRange(state.totalSpentPoints, 0, 2147483647) then return nil end
    if body.operation == 'spend' and (not isIntegerInRange(state.categoryId, 1, MAX_CATEGORIES) or
        not isIntegerInRange(state.spentPoints, 0, 1000)) then return nil end
    if body.operation == 'reset' and state.reset ~= true then return nil end
    return body
end

function xibatAscensionController:requestOpen()
    if g_game.isOnline() then g_game.getProtocolGame():sendExtendedJSONOpcode(ASCENSION_OPCODE, { action = 'open' }) end
end

function xibatAscensionController:toggle()
    if self.ui:isVisible() then self:close() else self:requestOpen() end
end

function xibatAscensionController:close()
    self.ui:hide()
    if self.button then self.button:setOn(false) end
end

function xibatAscensionController:destroyPrompt()
    if self.resetPrompt then
        self.resetPrompt:destroy()
        self.resetPrompt = nil
    end
end

function xibatAscensionController:sendMutation(request)
    if self.pendingRequest then return end
    self.nextRequestId = self.nextRequestId % 2147483647 + 1
    request.requestId = self.nextRequestId
    self.pendingRequest = { operation = request.action, requestId = request.requestId }
    g_game.getProtocolGame():sendExtendedJSONOpcode(ASCENSION_OPCODE, request)
    self.pendingEvent = self:scheduleEvent(function()
        self.pendingEvent = nil
        self.pendingRequest = nil
        if self.ui:isVisible() then self.ui.message:setText(tr('The Ascension request timed out.')) end
        self:renderCategory()
    end, REQUEST_TIMEOUT)
    self:renderCategory()
end

function xibatAscensionController:updateHeader()
    local progress = self.snapshot.progress
    self.ui.level:setText(tr('Ascension Level %d', progress.level))
    self.ui.points:setText(tr('%d points available | %d invested', progress.availablePoints, progress.totalSpentPoints))
    self.ui.experience:setValue(progress.levelProgress * 100, 0, 100)
    self.ui.experience:setText(tr('%d / %d experience', progress.levelExperience, progress.levelExperienceRequired))
    self.ui.reset:setEnabled(progress.totalSpentPoints > 0 and not self.pendingRequest)
end

function xibatAscensionController:selectCategory(categoryId)
    self.selectedCategoryId = categoryId
    for _, button in ipairs(self.categoryButtons) do
        button:setBackgroundColor(button.categoryId == categoryId and '#566b73' or '#00000000')
    end
    self:renderCategory()
end

function xibatAscensionController:renderCategory()
    if not self.snapshot then return end
    local category
    for _, candidate in ipairs(self.snapshot.categories) do
        if candidate.id == self.selectedCategoryId then category = candidate break end
    end
    if not category then category = self.snapshot.categories[1] self.selectedCategoryId = category.id end
    self.ui.nodes:destroyChildren()
    self.ui.categoryTitle:setText(category.name)
    self.ui.categoryProgress:setText(tr('%d / %d points invested', category.spentPoints, category.maxPoints))
    for _, passive in ipairs(category.passives) do
        local card = g_ui.createWidget('AscensionNodeCard', self.ui.nodes)
        if not card then
            self.ui.message:setText(tr('The Ascension milestone board could not be rendered.'))
            return
        end
        local unlocked = category.spentPoints >= passive.unlockPoints
        local nextMilestone = category.spentPoints < passive.unlockPoints and
            category.spentPoints == passive.unlockPoints - passive.cost
        if passive.icon then
            card.icon:setImageSource(iconPaths[passive.icon])
            card.item:hide()
        elseif passive.previewItems[1] then
            card.item:show()
            card.item:setItemId(passive.previewItems[1].clientId)
            card.item:setItemCount(passive.previewItems[1].count)
            card.icon:hide()
        else
            card.icon:hide()
            card.item:hide()
        end
        card.name:setText(passive.name)
        card.name:setTooltip(passive.name)
        card.requirement:setText(tr('Raid level %d', passive.raidLevel))
        card.status:setText(unlocked and tr('UNLOCKED') or tr('%d points\nrequired', passive.unlockPoints))
        card.status:setColor(unlocked and '#79c68b' or nextMilestone and '#e4b95e' or '#7e8b91')
        card:setOpacity((unlocked or nextMilestone) and 1 or 0.55)
        card.spend:setText(unlocked and tr('Unlocked') or tr('Spend %d', passive.cost))
        card.spend:setEnabled(nextMilestone and self.snapshot.progress.availablePoints >= passive.cost and not self.pendingRequest)
        card.spend.onClick = function()
            self:sendMutation({ action = 'spend', categoryId = category.id, points = passive.cost,
                expectedSpentPoints = category.spentPoints })
        end
    end
    self:updateHeader()
end

function xibatAscensionController:renderView(snapshot)
    self.snapshot = snapshot
    self.categoryButtons = {}
    self.ui.categoryRail:destroyChildren()
    for _, category in ipairs(snapshot.categories) do
        local button = g_ui.createWidget('AscensionCategoryButton', self.ui.categoryRail)
        button.categoryId = category.id
        button:setText(category.name)
        button.onClick = function() self:selectCategory(category.id) end
        table.insert(self.categoryButtons, button)
    end
    self.ui.message:setText(tr('Milestones unlock in order. Rewards apply automatically.'))
    self:selectCategory(self.selectedCategoryId or snapshot.categories[1].id)
    self.ui:show()
    self.ui:raise()
    self.ui:focus()
    if self.button then self.button:setOn(true) end
end

function xibatAscensionController:applyResult(result)
    if not self.pendingRequest or result.operation ~= self.pendingRequest.operation or
        result.requestId ~= self.pendingRequest.requestId then return end
    if self.pendingEvent then self:removeEvent(self.pendingEvent) self.pendingEvent = nil end
    self.pendingRequest = nil
    if not self.snapshot then return end
    local state = result.state
    for _, field in ipairs({ 'level', 'levelExperience', 'levelExperienceRequired', 'levelProgress',
        'availablePoints', 'totalSpentPoints' }) do
        self.snapshot.progress[field] = state[field]
    end
    if result.ok then
        if result.operation == 'reset' then
            for _, category in ipairs(self.snapshot.categories) do
                category.spentPoints = 0
                self.snapshot.progress.spentPoints[tostring(category.id)] = 0
            end
        else
            for _, category in ipairs(self.snapshot.categories) do
                if category.id == state.categoryId then category.spentPoints = state.spentPoints break end
            end
            self.snapshot.progress.spentPoints[tostring(state.categoryId)] = state.spentPoints
        end
        self.ui.message:setText(result.operation == 'reset' and tr('Ascension Points reset.') or tr('Milestone unlocked.'))
    else
        self.ui.message:setText(tr(resultMessages[result.code] or 'The Ascension request was rejected.'))
        if result.code == 'state_changed' then self:requestOpen() return end
    end
    self:renderCategory()
end

function xibatAscensionController:onOpcode(_, _, payload)
    local snapshot = validateView(payload)
    if snapshot then self:renderView(snapshot) return end
    local result = validateResult(payload)
    if result then self:applyResult(result) end
end

function xibatAscensionController:confirmReset()
    if not self.snapshot or self.snapshot.progress.totalSpentPoints == 0 or self.pendingRequest then return end
    self:destroyPrompt()
    local function cancel() self:destroyPrompt() end
    local function confirm() cancel() self:sendMutation({ action = 'reset' }) end
    self.resetPrompt = displayGeneralBox(tr('Reset Ascension Points'),
        tr('Return all invested Ascension Points? Your Ascension level and earned experience will remain.'), {
            { text = tr('Reset'), callback = confirm }, { text = tr('Cancel'), callback = cancel },
        }, confirm, cancel)
end

function xibatAscensionController:onInit()
    self.nextRequestId = 0
    self.categoryButtons = {}
    self.ui.categoryRail:destroyChildren()
    self.ui.nodes:destroyChildren()
    self.ui:hide()
    self.ui.reset.onClick = function() self:confirmReset() end
    self:registerExtendedJSONOpcode(ASCENSION_OPCODE, function(...) self:onOpcode(...) end)
    self:bindKeyDown('Ctrl+H', function() self:toggle() end)
    self.button = modules.client_topmenu.addRightGameToggleButton('xibatAscension', tr('Ascension (Ctrl+H)'),
        '/images/topbuttons/skills', function() self:toggle() end, false)
    self.button:setOn(false)
end

function xibatAscensionController:onGameStart() self:close() end
function xibatAscensionController:onGameEnd()
    self:destroyPrompt()
    self.snapshot = nil
    self.pendingRequest = nil
    self.pendingEvent = nil
    self:close()
end
function xibatAscensionController:onTerminate()
    self:destroyPrompt()
    self:close()
    if self.button then self.button:destroy() self.button = nil end
end
