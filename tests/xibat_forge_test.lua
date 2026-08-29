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

local state = { callbacks = {}, sent = {}, prompt = nil, events = {}, nextEvent = 1 }

local function makeWidget()
    local widget = { visible = true, enabled = true, children = {} }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
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
    function widget:setId(id) self.id = id if self.parent then self.parent[id] = self end end
    return widget
end

local ui = makeWidget()
for _, id in ipairs({
    'branches', 'name', 'preview', 'branchSummary', 'levelSummary', 'statusMessage', 'resetButton',
}) do
    ui[id] = makeWidget()
end

local environment = {
    modules = { game_xibat_core = { XibatOpcode = { Forge = 206 } } },
    Controller = {},
    g_game = {},
    g_ui = {},
    tr = function(text, ...)
        return string.format(text, ...)
    end,
}

function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:scheduleEvent(callback)
        local event = state.nextEvent
        state.nextEvent = event + 1
        state.events[event] = callback
        return event
    end
    function controller:removeEvent(event) state.events[event] = nil end
    return controller
end

function environment.g_game.getProtocolGame()
    return {
        sendExtendedJSONOpcode = function(_, opcode, payload)
            table.insert(state.sent, { opcode = opcode, payload = payload })
        end,
    }
end

function environment.g_ui.createWidget(style, parent)
    local widget = makeWidget()
    widget.parent = parent
    if style == 'XibatForgeBranchCard' then
        for _, id in ipairs({ 'preview', 'name', 'level', 'progress', 'status', 'description', 'costs', 'upgradeButton' }) do
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

local function makeBranch(branchId, level, unlocked)
    local branch = {
        branchId = branchId,
        name = 'Branch ' .. branchId,
        turretClientId = 1100 + branchId,
        unlocked = unlocked,
        level = level,
        maxLevel = 4,
    }
    if level < branch.maxLevel then
        branch.nextUpgrade = {
            description = 'Next effect ' .. branchId,
            cost = { { clientId = 3000 + branchId, name = 'Powder ' .. branchId, amount = branchId } },
        }
    end
    return branch
end

local function makeSnapshot(level1, level2, level3, operation, requestId, sessionActive)
    local active = (level1 > 0 and 1 or 0) + (level2 > 0 and 1 or 0) + (level3 > 0 and 1 or 0)
    local function unlocked(level) return active < 2 or level > 0 end
    return {
        action = 'openForgeView',
        body = {
            name = 'Death Turret',
            turretId = 9,
            turretClientId = 1100,
            currentLevel = level1 * 100 + level2 * 10 + level3,
            maxActiveBranches = 2,
            sessionActive = sessionActive ~= false,
            branches = {
                makeBranch(3, level3, unlocked(level3)),
                makeBranch(1, level1, unlocked(level1)),
                makeBranch(2, level2, unlocked(level2)),
            },
            result = { operation = operation or 'open', requestId = requestId or 0, ok = true, code = 'ok' },
        },
    }
end

loadModule('modules/game_xibat_forge/forge.lua', environment)
local controller = environment.xibatForgeController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[206], 'forge opcode callback was not registered')

local invalid = makeSnapshot(0, 0, 0)
invalid.body.extra = true
local invalidOk = pcall(state.callbacks[206], nil, 206, invalid)
requireValue(invalidOk and not ui.visible and not controller.snapshot,
    'malformed forge snapshot escaped or changed UI state')

state.callbacks[206](nil, 206, makeSnapshot(0, 0, 0))
requireValue(ui.visible and controller.snapshot and #ui.branches.children == 3 and
    ui.branches.children[1].branchId == 1 and ui.branches.children[2].branchId == 2 and
    ui.branches.children[3].branchId == 3 and ui.preview.itemId == 1100,
    'valid forge snapshot was not normalized and rendered')
local firstCard = ui.branches.children[1]
requireValue(firstCard.upgradeButton.enabled and firstCard.costs.children[1].itemId == 3001 and
    firstCard.costs.children[1].itemCount == 1, 'forge branch action or cost rendered incorrectly')

firstCard.upgradeButton.onClick()
firstCard.upgradeButton.onClick()
requireValue(#state.sent == 1 and state.sent[1].opcode == 206 and state.sent[1].payload.action == 'upgrade' and
    state.sent[1].payload.requestId == 1 and state.sent[1].payload.branchId == 1 and
    state.sent[1].payload.turretId == 9 and state.sent[1].payload.currentLevel == 0 and
    controller.pendingRequest.operation == 'upgrade',
    'forge upgrade did not send one exact request')

state.callbacks[206](nil, 206, {
    action = 'forgeResult',
    body = { operation = 'upgrade', requestId = 1, ok = false, code = 'not_enough_material' },
})
requireValue(not controller.pendingRequest and ui.branches.children[1].upgradeButton.enabled and
    ui.statusMessage.text == 'You do not have enough material.',
    'forge rejection did not restore actionable state')

ui.branches.children[1].upgradeButton.onClick()
local pendingEvent = controller.pendingEvent
state.callbacks[206](nil, 206, { action = 'openForgeView', body = {} })
requireValue(controller.pendingRequest and state.events[pendingEvent],
    'malformed forge response silently cleared the pending request')
state.events[pendingEvent]()
requireValue(not ui.visible and not controller.pendingRequest,
    'forge request timeout retained a permanently pending window')
state.callbacks[206](nil, 206, makeSnapshot(1, 0, 0, 'upgrade', 2))
requireValue(not ui.visible and not controller.snapshot,
    'stale forge success reopened a window closed after its request')

state.callbacks[206](nil, 206, makeSnapshot(1, 1, 0))
local lockedCard = ui.branches.children[3]
requireValue(not lockedCard.upgradeButton.enabled and lockedCard.upgradeButton.text == 'Two Branch Limit',
    'third forge branch was not locked after two active choices')

ui.resetButton.onClick()
requireValue(state.prompt and #state.prompt.buttons == 2 and not controller.pendingRequest,
    'forge reset did not require confirmation')
state.prompt.buttons[1].callback()
local resetRequest = state.sent[#state.sent]
requireValue(resetRequest.payload.action == 'reset' and resetRequest.payload.turretId == 9 and
    resetRequest.payload.requestId == 3 and resetRequest.payload.currentLevel == 110 and
    controller.pendingRequest.operation == 'reset',
    'forge reset did not preserve the server contract')

state.callbacks[206](nil, 206, makeSnapshot(1, 0, 0, 'reset', 3))
ui.resetButton.onClick()
local stalePrompt = state.prompt
controller:onGameEnd()
requireValue(stalePrompt.destroyed and not ui.visible and not controller.snapshot and
    #ui.branches.children == 0, 'game end retained forge state or reset confirmation')

print('Xibat forge tests passed')
