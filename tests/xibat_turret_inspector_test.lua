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

local state = { callbacks = {}, sent = {}, soul = 50, events = {}, tiles = {}, widgets = {} }

local function makeWidget()
    local widget = { visible = true, enabled = true, destroyed = false }
    function widget:hide() self.visible = false end
    function widget:show() self.visible = true end
    function widget:raise() end
    function widget:focus() end
    function widget:destroy() self.destroyed = true end
    function widget:isDestroyed() return self.destroyed end
    function widget:setText(text) self.text = text end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setId(id) self.id = id end
    function widget:setPhantom(value) self.phantom = value end
    function widget:setFocusable(value) self.focusable = value end
    function widget:setDraggable(value) self.draggable = value end
    return widget
end

local function makeTile()
    local tile = { attached = {}, foreign = makeWidget() }
    table.insert(tile.attached, tile.foreign)
    function tile:attachWidget(widget) table.insert(self.attached, widget) end
    function tile:detachWidget(widget)
        for index, attached in ipairs(self.attached) do
            if attached == widget then table.remove(self.attached, index) return true end
        end
        return false
    end
    return tile
end

local ui = makeWidget()
ui.descendants = {}
function ui:recursiveGetChildById(id) return self.descendants[id] or self[id] end
for _, id in ipairs({ 'name', 'levelBadge', 'soulBalance', 'statusMessage', 'upgradeButton', 'sellButton' }) do
    ui[id] = makeWidget()
end
for _, id in ipairs({
    'levelCurrent', 'damageCurrent', 'speedCurrent', 'rangeCurrent',
    'levelNext', 'damageNext', 'speedNext', 'rangeNext',
}) do ui.descendants[id] = makeWidget() end

local environment = {
    modules = { game_xibat_core = { XibatOpcode = { Turret = 202 } } },
    Controller = {}, g_game = {}, g_map = {}, g_ui = {}, LocalPlayer = {},
    tr = function(text, ...) return string.format(text, ...) end,
}

function environment.Controller:new()
    local controller = {}
    function controller:setUI(name) self.uiName = name end
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:registerEvents(actor, events) state.events[actor] = events end
    return controller
end

function environment.g_game.getLocalPlayer()
    return { getSoul = function() return state.soul end }
end

function environment.g_game.getProtocolGame()
    return { sendExtendedJSONOpcode = function(_, opcode, payload)
        table.insert(state.sent, { opcode = opcode, payload = payload })
    end }
end

function environment.g_map.getTile(position)
    return state.tiles[string.format('%d,%d,%d', position.x, position.y, position.z)]
end

function environment.g_ui.createWidget(style)
    local widget = makeWidget()
    widget.style = style
    table.insert(state.widgets, widget)
    return widget
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
controller:onGameStart()
requireValue(state.callbacks[202], 'turret opcode callback was not registered')
requireValue(#state.sent == 1 and state.sent[1].payload.version == 2 and state.sent[1].payload.action == 'sync' and
    state.sent[1].payload.body == nil, 'game start did not send the exact v2 sync')

local function envelope(action, body) return { version = 2, action = action, body = body } end
local details = {
    token = 'opaque:turret/42', position = { x = 37, y = 12, z = 7 }, stateRevision = 8,
    currentLevel = 1, nextLevel = 2, name = 'Death Turret', itemId = 26382,
    currentAttackSpeed = 0.77, nextAttackSpeed = 0.91, nextUpgradeCost = 100,
    currentRange = 2, nextRange = 3, sellPrice = 24, currentDamageMin = 12,
    nextDamageMin = 70, currentDamageMax = 12, nextDamageMax = 70,
}

local invalid = envelope('openInspector', {})
for key, value in pairs(details) do invalid.body[key] = value end
invalid.body.extra = true
local invalidOk = pcall(state.callbacks[202], nil, 202, invalid)
requireValue(invalidOk and not ui.visible and not controller.currentDetails,
    'openInspector accepted an unknown field or changed UI state')

state.callbacks[202](nil, 202, envelope('openInspector', details))
requireValue(ui.visible and controller.currentDetails.token == details.token and ui.name.text == details.name,
    'valid openInspector did not open the inspector')
requireValue(not ui.upgradeButton.enabled and ui.sellButton.enabled and
    ui.descendants.damageCurrent.text == '12 - 12',
    'initial affordability or stats rendered incorrectly')

state.soul = 100
state.events[environment.LocalPlayer].onSoulChange(nil, 100, 50)
requireValue(ui.upgradeButton.enabled and ui.soulBalance.text == 'Available soul: 100',
    'live soul did not refresh inspector affordability')
ui.upgradeButton.onClick()
local upgrade = state.sent[#state.sent].payload
requireValue(upgrade.version == 2 and upgrade.action == 'upgrade' and upgrade.body.token == details.token and
    upgrade.body.expectedStateRevision == 8 and upgrade.body.requestId == 1 and ui.visible and
    not ui.upgradeButton.enabled and not ui.sellButton.enabled, 'upgrade was not correlated or remained actionable')

state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'upgrade', requestId = 999, token = details.token, stateRevision = 8, ok = true, code = 'ok',
}))
requireValue(ui.visible and controller.pendingRequest, 'stale success closed or cleared the pending inspector')
state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'upgrade', requestId = 1, token = details.token, stateRevision = 8,
    ok = false, code = 'not_enough_soul', extra = true,
}))
requireValue(controller.pendingRequest, 'mutationResult accepted an unknown field')
state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'upgrade', requestId = 1, token = details.token, stateRevision = 8,
    ok = false, code = 'not_enough_soul',
}))
requireValue(ui.visible and not controller.pendingRequest and ui.upgradeButton.enabled and
    ui.statusMessage.text == 'You do not have enough soul.', 'matching failure lost context or controls')

ui.upgradeButton.onClick()
requireValue(state.sent[#state.sent].payload.body.requestId == 2 and ui.visible, 'request IDs did not advance')
state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'upgrade', requestId = 2, token = details.token, stateRevision = 9, ok = true, code = 'ok',
}))
requireValue(not ui.visible and not controller.currentDetails and not controller.pendingRequest,
    'matching confirmed success did not close the inspector')

state.callbacks[202](nil, 202, envelope('openInspector', details))
ui.sellButton.onClick()
requireValue(state.prompt and #state.prompt.buttons == 2, 'sale did not require confirmation')
state.prompt.buttons[1].callback()
local sale = state.sent[#state.sent].payload
requireValue(sale.action == 'sell' and sale.body.requestId == 3 and sale.body.token == details.token and
    ui.visible and not ui.sellButton.enabled, 'sale request was not correlated or retained pending context')
state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'sell', requestId = 3, token = 'different-token', stateRevision = 8, ok = true, code = 'ok',
}))
requireValue(ui.visible and controller.pendingRequest, 'result for a different token closed the sale')
state.callbacks[202](nil, 202, envelope('mutationResult', {
    operation = 'sell', requestId = 3, token = details.token, stateRevision = 8,
    ok = false, code = 'out_of_range',
}))
requireValue(ui.visible and ui.sellButton.enabled and ui.statusMessage.text == 'Move closer to manage that turret.',
    'sale failure lost inspector context')
controller:close()

local tileA, tileB = makeTile(), makeTile()
state.tiles['37,12,7'], state.tiles['38,12,7'] = tileA, tileB
state.soul = 100
state.callbacks[202](nil, 202, envelope('upgradeProjection', {
    mode = 'full', revision = 3, entries = {
        { token = 'a', position = { x = 37, y = 12, z = 7 }, stateRevision = 1, nextUpgradeCost = 100 },
        { token = 'b', position = { x = 38, y = 12, z = 7 }, stateRevision = 2 },
    },
}))
requireValue(#tileA.attached == 2 and #tileB.attached == 1 and tileA.attached[2].phantom and
    tileA.attached[2].focusable == false and tileA.attached[2].draggable == false,
    'full projection did not attach only the affordable non-max badge as a passive widget')
local originalBadge = tileA.attached[2]
state.events[environment.LocalPlayer].onSoulChange(nil, 100, 100)
requireValue(tileA.attached[2] == originalBadge and not originalBadge.destroyed,
    'unchanged affordability recreated the turret badge')
local revisionBeforeInvalidProjection = controller.projectionRevision
state.callbacks[202](nil, 202, envelope('upgradeProjection', {
    mode = 'full', revision = 4, entries = { unexpected = true },
}))
requireValue(controller.projectionRevision == revisionBeforeInvalidProjection and #tileA.attached == 2,
    'projection accepted a non-array entries table')

state.soul = 99
state.events[environment.LocalPlayer].onSoulChange(nil, 99, 100)
requireValue(#tileA.attached == 1 and tileA.attached[1] == tileA.foreign,
    'soul reconciliation removed a foreign widget or retained an unaffordable badge')
state.soul = 200
state.events[environment.LocalPlayer].onSoulChange(nil, 200, 99)
requireValue(#tileA.attached == 2, 'affordable badge did not return after live soul change')

state.callbacks[202](nil, 202, envelope('upgradeProjection', {
    mode = 'delta', baseRevision = 3, revision = 4,
    upsert = { { token = 'b', position = { x = 38, y = 12, z = 7 }, stateRevision = 3, nextUpgradeCost = 150 } },
    remove = { 'a' },
}))
requireValue(#tileA.attached == 1 and tileA.attached[1] == tileA.foreign and #tileB.attached == 2,
    'delta projection did not reconcile removals and upserts')

local replacementTile = makeTile()
state.tiles['38,12,7'] = replacementTile
state.events[environment.g_game].onMapDescription()
requireValue(#tileB.attached == 1 and tileB.attached[1] == tileB.foreign and #replacementTile.attached == 2,
    'map reload did not move the module-owned indicator to the loaded tile')

local sentBeforeGap = #state.sent
state.callbacks[202](nil, 202, envelope('upgradeProjection', {
    mode = 'delta', baseRevision = 2, revision = 5, upsert = {}, remove = {},
}))
requireValue(#state.sent == sentBeforeGap + 1 and state.sent[#state.sent].payload.action == 'sync' and
    controller.projectionRevision == 4, 'projection revision gap did not preserve state and request sync')

state.callbacks[202](nil, 202, envelope('openInspector', details))
ui.sellButton.onClick()
local stalePrompt = state.prompt
controller:onGameEnd()
requireValue(stalePrompt.destroyed and not ui.visible and not controller.currentDetails and
    #replacementTile.attached == 1 and replacementTile.attached[1] == replacementTile.foreign and
    next(controller.projectionEntries) == nil, 'game end leaked state, prompt, or owned indicator')
controller:onGameEnd()
controller:onTerminate()
requireValue(#replacementTile.attached == 1 and replacementTile.attached[1] == replacementTile.foreign,
    'repeated cleanup touched a foreign tile widget')

print('Xibat turret inspector tests passed')
