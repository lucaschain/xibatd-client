local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function loadModule(path, environment)
    setmetatable(environment, { __index = _G })
    local chunk = assert(loadfile(root .. '/' .. path))
    setfenv(chunk, environment)
    chunk()
end

local state = {
    callbacks = {},
    sent = nil,
    prompt = nil,
    soul = 50,
}

local function makeWidget()
    local widget = { visible = true, enabled = true }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
    function widget:setText(text) self.text = text end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    return widget
end

local ui = makeWidget()
for _, id in ipairs({
    'name', 'levelBadge', 'levelCurrent', 'damageCurrent', 'speedCurrent', 'rangeCurrent',
    'levelNext', 'damageNext', 'speedNext', 'rangeNext', 'soulBalance', 'upgradeButton', 'sellButton',
}) do
    ui[id] = makeWidget()
end

local environment = {
    modules = {
        game_xibat_core = {
            XibatOpcode = { Turret = 202 },
        },
    },
    Controller = {},
    g_game = {},
    tr = function(text, ...)
        if select('#', ...) > 0 then
            return string.format(text, ...)
        end
        return text
    end,
}

function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    return controller
end

function environment.g_game.getLocalPlayer()
    return {
        getSoul = function()
            return state.soul
        end,
    }
end

function environment.g_game.getProtocolGame()
    return {
        sendExtendedJSONOpcode = function(_, opcode, payload)
            state.sent = { opcode = opcode, payload = payload }
        end,
    }
end

function environment.displayGeneralBox(_, _, buttons)
    local prompt = makeWidget()
    prompt.buttons = buttons
    state.prompt = prompt
    return prompt
end

loadModule('modules/game_xibat_turret/turret_inspector.lua', environment)
local controller = environment.turretInspectorController
controller.ui = ui
controller:onInit()
requireValue(state.callbacks[202], 'turret opcode callback was not registered')

local details = {
    currentLevel = 1,
    nextLevel = 2,
    name = 'Death Turret',
    key = '37,12,7',
    itemId = 26382,
    currentAttackSpeed = 0.77,
    nextAttackSpeed = 0.91,
    soulRequiredForUpgrade = 100,
    currentRange = 2,
    nextRange = 3,
    sellPrice = 24,
    currentDamageMin = 12,
    nextDamageMin = 70,
    currentDamageMax = 12,
    nextDamageMax = 70,
}

local invalid = {}
for key, value in pairs(details) do invalid[key] = value end
invalid.key = '../stale'
local invalidOk = pcall(state.callbacks[202], nil, 202, invalid)
requireValue(invalidOk and not ui.visible and not controller.currentDetails,
    'malformed turret details escaped or changed UI state')

state.callbacks[202](nil, 202, details)
requireValue(ui.visible and controller.currentDetails.key == details.key and ui.name.text == details.name,
    'valid turret details did not open the inspector')
requireValue(not ui.upgradeButton.enabled and ui.sellButton.enabled and ui.damageCurrent.text == '12 - 12',
    'turret affordability or current stats rendered incorrectly')

local maxLevelDetails = {}
for key, value in pairs(details) do maxLevelDetails[key] = value end
maxLevelDetails.currentLevel = 6
maxLevelDetails.nextLevel = 6
state.callbacks[202](nil, 202, maxLevelDetails)
requireValue(not ui.upgradeButton.enabled and ui.upgradeButton.text == 'Maximum Level' and
    ui.levelNext.text == 'MAX', 'maximum-level turret rendered as upgradeable')

state.soul = 100
state.callbacks[202](nil, 202, details)
ui.upgradeButton.onClick()
requireValue(state.sent and state.sent.opcode == 202 and state.sent.payload.action == 'upgrade' and
    state.sent.payload.key == details.key and not ui.visible and not controller.currentDetails,
    'turret upgrade request did not preserve the server contract')

state.sent = nil
state.callbacks[202](nil, 202, details)
ui.sellButton.onClick()
requireValue(state.prompt and #state.prompt.buttons == 2 and not state.sent,
    'turret sale did not require confirmation')
state.prompt.buttons[1].callback()
requireValue(state.sent and state.sent.payload.action == 'sell' and state.sent.payload.key == details.key and
    not ui.visible and not controller.currentDetails,
    'turret sale request did not preserve the server contract')

state.callbacks[202](nil, 202, details)
ui.sellButton.onClick()
local stalePrompt = state.prompt
controller:onGameEnd()
requireValue(stalePrompt.destroyed and not ui.visible and not controller.currentDetails,
    'game end retained turret state or its confirmation prompt')

print('Xibat turret inspector tests passed')
