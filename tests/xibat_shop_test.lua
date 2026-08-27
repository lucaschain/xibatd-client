local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then error(message, 2) end
end

local environment = {}
setmetatable(environment, { __index = _G })
local chunk = assert(loadfile(root .. '/modules/game_shop/xibat_shop_contract.lua'))
setfenv(chunk, environment)
chunk()
local contract = environment.XibatShopContract

local function fieldCount(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function valid(action, body)
    return contract.validate({ version = 2, action = action, body = body })
end

local fetch = contract.fetchRequest()
requireValue(fetch.version == 2 and fetch.action == 'fetch' and fieldCount(fetch) == 2,
    'Shop fetch request was not versioned')
local description = contract.descriptionRequest('philosopher-outfit')
requireValue(description.offerId == 'philosopher-outfit' and contract.descriptionRequest('other') == nil,
    'Shop description request accepted the wrong offer')
local purchase = contract.purchaseRequest(7, 1, 'philosopher-outfit')
requireValue(purchase.requestId == 7 and purchase.catalogRevision == 1 and purchase.offerId == 'philosopher-outfit',
    'Shop purchase request omitted its correlation or catalog identity')
requireValue(contract.purchaseRequest(0, 1, 'philosopher-outfit') == nil and
    contract.purchaseRequest(1, 0, 'philosopher-outfit') == nil and
    contract.purchaseRequest(1, 1, 'other') == nil, 'Shop purchase request accepted invalid identity fields')

requireValue(valid('fetchBase', {
    catalogRevision = 1,
    categories = { { categoryId = 'outfits', name = 'Outfits' } },
}), 'valid Shop category response was rejected')
requireValue(valid('fetchOffers', {
    catalogRevision = 1,
    offers = { {
        offerId = 'philosopher-outfit', categoryId = 'outfits', type = 'outfit',
        title = 'Philosopher Outfit', cost = 500, looktypes = { 873, 874 }, looktype = 873,
        addons = 3, owned = false,
    } },
}), 'valid Shop offer response was rejected')
requireValue(valid('fetchDescription', {
    offerId = 'philosopher-outfit', description = 'A complete outfit.',
}), 'valid Shop description response was rejected')
requireValue(valid('points', { points = 500 }), 'valid Shop points response was rejected')
requireValue(valid('history', {
    entries = { { date = '2026-08-27 12:00:00', title = 'Philosopher Outfit', cost = 500 } },
}), 'valid Shop history response was rejected')
requireValue(valid('msg', {
    requestId = 7, ok = true, code = 'ok', offerId = 'philosopher-outfit',
}), 'valid correlated Shop result was rejected')
requireValue(valid('msg', { ok = false, code = 'unavailable' }),
    'valid uncorrelated Shop availability result was rejected')

local malformed = {
    { version = 1, action = 'points', body = { points = 1 } },
    { version = 2, action = 'points', body = { points = -1 } },
    { version = 2, action = 'points', body = { points = 1, extra = true } },
    { version = 2, action = 'fetchOffers', body = { catalogRevision = 1, offers = {} } },
    { version = 2, action = 'fetchOffers', body = {
        catalogRevision = 1,
        offers = { {
            offerId = 'philosopher-outfit', categoryId = 'outfits', type = 'outfit',
            title = 'Philosopher Outfit', cost = 500,
            looktypes = { 873, 874, extra = 999 }, looktype = 873, addons = 3, owned = false,
        } },
    } },
    { version = 2, action = 'history', body = { entries = { extra = true } } },
    { version = 2, action = 'msg', body = { requestId = 7, ok = true, code = 'ok' } },
    { version = 2, action = 'msg', body = {
        requestId = 7, ok = false, code = 'ok', offerId = 'philosopher-outfit',
    } },
    { version = 2, action = 'msg', body = { ok = false, code = 'unknown' } },
    { version = 2, action = 'msg', body = { ok = true, code = 'ok' } },
    { version = 2, action = 'msg', body = { ok = false, code = 'pending' } },
}
for _, payload in ipairs(malformed) do
    requireValue(contract.validate(payload) == nil, 'malformed Shop response was accepted')
end

local tooMuchHistory = {}
for i = 1, 51 do
    tooMuchHistory[i] = { date = '2026-08-27', title = 'Philosopher Outfit', cost = 500 }
end
requireValue(not valid('history', { entries = tooMuchHistory }), 'oversized Shop history was accepted')

local runtime = { callbacks = {}, sent = {}, removed = {}, nextEvent = 16 }
local runtimeEnvironment = {
    modules = { game_xibat_core = { XibatOpcode = { Shop = 201 } } },
    Controller = {},
    g_game = {},
}
setmetatable(runtimeEnvironment, { __index = _G })
function runtimeEnvironment.Controller:new()
    local controller = {}
    function controller:init() self:onInit() end
    function controller:terminate() self:onGameEnd() end
    function controller:registerExtendedJSONOpcode(opcode, callback) runtime.callbacks[opcode] = callback end
    function controller:sendExtendedJSONOpcode(opcode, payload)
        runtime.sent[#runtime.sent + 1] = { opcode = opcode, payload = payload }
    end
    function controller:scheduleEvent(callback)
        runtime.nextEvent = runtime.nextEvent + 1
        runtime.scheduled = callback
        return runtime.nextEvent
    end
    function controller:removeEvent(event)
        runtime.removed[#runtime.removed + 1] = event
    end
    return controller
end
runtimeEnvironment.XibatShopContract = contract
runtimeEnvironment.displayInfoBox = function() end
runtimeEnvironment.displayErrorBox = function() end
runtimeEnvironment.tr = function(value) return value end
local gameShopChunk = assert(loadfile(root .. '/modules/game_shop/game_shop.lua'))
setfenv(gameShopChunk, runtimeEnvironment)
gameShopChunk()
runtimeEnvironment.init()
requireValue(runtime.callbacks[201], 'Shop JSON opcode lifecycle was not registered through Controller')
runtimeEnvironment.updateDescription = function() end

local function setUpvalue(callback, name, value)
    for index = 1, 50 do
        local current = debug.getupvalue(callback, index)
        if not current then break end
        if current == name then debug.setupvalue(callback, index, value) return true end
    end
    return false
end

local offerWidget = { data = {
    offerId = 'philosopher-outfit', name = 'Philosopher Outfit', price = 500, owned = false,
} }
local prompt = { destroy = function(self) self.destroyed = true end }
requireValue(setUpvalue(runtimeEnvironment.buyConfirmed, 'selectedOffer', offerWidget) and
    setUpvalue(runtimeEnvironment.buyConfirmed, 'catalogRevision', 1) and
    setUpvalue(runtimeEnvironment.buyConfirmed, 'msgWindow', prompt), 'Shop purchase fixture could not set state')
runtimeEnvironment.buyConfirmed()
runtimeEnvironment.buyConfirmed()
requireValue(#runtime.sent == 1 and runtime.sent[1].opcode == 201 and
    runtime.sent[1].payload.action == 'purchase' and runtime.sent[1].payload.requestId == 1 and
    runtime.sent[1].payload.catalogRevision == 1 and runtime.sent[1].payload.offerId == 'philosopher-outfit',
    'Shop confirmation did not emit one exact correlated purchase')

runtimeEnvironment.onGameShopMsg({ requestId = 2, offerId = 'philosopher-outfit', ok = true, code = 'ok' })
runtimeEnvironment.buyConfirmed()
requireValue(#runtime.sent == 1, 'stale Shop result cleared the active purchase')
runtimeEnvironment.onGameShopMsg({ requestId = 1, offerId = 'philosopher-outfit', ok = false, code = 'pending' })
requireValue(#runtime.sent == 2 and runtime.sent[2].payload.action == 'fetch',
    'pending Shop result did not request authoritative refresh')
requireValue(setUpvalue(runtimeEnvironment.buyConfirmed, 'msgWindow', prompt), 'Shop fixture could not restore prompt')
runtimeEnvironment.buyConfirmed()
requireValue(#runtime.sent == 2, 'Shop refresh fence allowed a duplicate purchase')
runtimeEnvironment.destroy()
requireValue(#runtime.removed >= 2, 'Shop logout did not cancel purchase and refresh timeouts')

print('Xibat Shop tests passed')
