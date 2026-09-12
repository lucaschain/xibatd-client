local root = arg[1] or '.'
local function requireValue(value, message) if not value then error(message, 2) end end
local state = { callbacks = {}, sent = {}, hooks = {} }
local environment = {
    Controller = {}, modules = {
        game_interface = {}, game_textmessage = { displayFailureMessage = function() end },
        game_xibat_core = { XibatOpcode = { SupplyStash = 211 } },
    },
    g_ui = { importStyle = function() end }, g_game = { isOnline = function() return true end },
    g_keyboard = {}, g_logger = { info = function() end },
    tr = function(value) return value end, table = table, math = math,
}
function environment.table.clear(value) for key in pairs(value) do value[key] = nil end end
setmetatable(environment, { __index = _G })
function environment.Controller:new()
    local controller = {}
    function controller:registerExtendedJSONOpcode(opcode, callback) state.callbacks[opcode] = callback end
    function controller:sendExtendedJSONOpcode(opcode, payload) table.insert(state.sent, { opcode = opcode, payload = payload }) end
    return controller
end
function environment.modules.game_interface.addMenuHook(category, name, callback, condition)
    state.hooks[category] = { name = name, callback = callback, condition = condition }
end
function environment.modules.game_interface.removeMenuHook(category) state.hooks[category] = nil end

local chunk = assert(loadfile(root .. '/modules/game_stash/game_stash.lua'))
setfenv(chunk, environment)
chunk()
environment.stashController:onInit()
requireValue(state.callbacks[211] and state.hooks.xibatSupplyStash, 'stash protocol or context action was not registered')
for _, payload in ipairs({ {}, { version = 2, action = 'open', body = { items = {} } },
    { version = 1, action = 'unknown', body = { items = {} } },
    { version = 1, action = 'open', body = { code = 'ok', items = { { itemId = 1, serverId = 1, amount = 1 } } } },
    { version = 1, action = 'open', body = { items = { { itemId = 1, serverId = 1, name = 'powder', amount = 0 } } } },
}) do
    requireValue(pcall(state.callbacks[211], nil, 211, payload), 'invalid stash payload escaped validation')
end
requireValue(pcall(state.callbacks[211], nil, 211, {
    version = 1, action = 'result', body = { code = 'ok', items = {} },
}), 'a drop result attempted to open a closed stash window')
local thing = {}
function thing:getPosition() return { x = 65535, y = 2, z = 0 } end
function thing:getCount() return 37 end
state.hooks.xibatSupplyStash.callback(nil, thing)
local request = state.sent[1]
requireValue(request and request.opcode == 211 and request.payload.version == 1 and request.payload.action == 'stow' and
    request.payload.body.count == 37 and request.payload.body.position.x == 65535,
    'stash deposit did not send the bounded versioned request')
environment.stashController:onTerminate()
requireValue(state.hooks.xibatSupplyStash == nil, 'stash context action was not removed')
print('Xibat stash tests passed')
