XibatShopContract = {}

local VERSION = 1
local MAX_HISTORY = 50
local OFFER_ID = 'philosopher-outfit'
local MESSAGE_CODES = {
    ok = true,
    pending = true,
    already_owned = true,
    insufficient_points = true,
    unavailable = true,
}

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge and
        value == math.floor(value) and value >= minimum and value <= maximum
end

local function text(value, maximum)
    return type(value) == 'string' and value ~= '' and #value <= maximum and not value:find('%c')
end

local function exact(value, required, optional)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do
        if not required[field] and not (optional and optional[field]) then return false end
    end
    for field in pairs(required) do if value[field] == nil then return false end end
    return true
end

local function array(value, minimum, maximum)
    if type(value) ~= 'table' or #value < minimum or #value > maximum then return false end
    local count = 0
    for key in pairs(value) do
        if not integer(key, 1, #value) then return false end
        count = count + 1
    end
    return count == #value
end

function XibatShopContract.fetchRequest()
    return { version = VERSION, action = 'fetch' }
end

function XibatShopContract.descriptionRequest(offerId)
    if offerId ~= OFFER_ID then return nil end
    return { version = VERSION, action = 'getDescription', offerId = offerId }
end

function XibatShopContract.purchaseRequest(requestId, catalogRevision, offerId)
    if not integer(requestId, 1, 2147483647) or not integer(catalogRevision, 1, 2147483647) or
        offerId ~= OFFER_ID then return nil end
    return {
        version = VERSION,
        action = 'purchase',
        requestId = requestId,
        catalogRevision = catalogRevision,
        offerId = offerId,
    }
end

function XibatShopContract.historyRequest()
    return { version = VERSION, action = 'history' }
end

function XibatShopContract.validate(payload)
    if not exact(payload, { version = true, action = true, body = true }) or payload.version ~= VERSION or
        type(payload.action) ~= 'string' then return nil end
    local body = payload.body
    if payload.action == 'fetchBase' then
        if not exact(body, { catalogRevision = true, categories = true }) or
            not integer(body.catalogRevision, 1, 2147483647) or not array(body.categories, 1, 1) then return nil end
        local category = body.categories[1]
        if not exact(category, { categoryId = true, name = true }) or category.categoryId ~= 'outfits' or
            not text(category.name, 32) then return nil end
    elseif payload.action == 'fetchOffers' then
        if not exact(body, { catalogRevision = true, offers = true }) or
            not integer(body.catalogRevision, 1, 2147483647) or not array(body.offers, 1, 1) then return nil end
        local offer = body.offers[1]
        if not exact(offer, {
            offerId = true, categoryId = true, type = true, title = true, cost = true,
            looktypes = true, addons = true, owned = true,
        }) or offer.offerId ~= OFFER_ID or offer.categoryId ~= 'outfits' or offer.type ~= 'outfit' or
            not text(offer.title, 100) or not integer(offer.cost, 1, 2147483647) or
            not array(offer.looktypes, 2, 2) or
            not integer(offer.looktypes[1], 1, 65535) or not integer(offer.looktypes[2], 1, 65535) or
            not integer(offer.addons, 0, 3) or type(offer.owned) ~= 'boolean' then return nil end
    elseif payload.action == 'fetchDescription' then
        if not exact(body, { offerId = true, description = true }) or body.offerId ~= OFFER_ID or
            not text(body.description, 512) then return nil end
    elseif payload.action == 'points' then
        if not exact(body, { points = true }) or not integer(body.points, 0, 2147483647) then return nil end
    elseif payload.action == 'history' then
        if not exact(body, { entries = true }) or not array(body.entries, 0, MAX_HISTORY) then return nil end
        for _, entry in ipairs(body.entries) do
            if not exact(entry, { date = true, title = true, cost = true }) or not text(entry.date, 32) or
                not text(entry.title, 100) or not integer(entry.cost, 0, 2147483647) then return nil end
        end
    elseif payload.action == 'msg' then
        local base = { ok = true, code = true }
        local optional = { requestId = true, offerId = true }
        if not exact(body, base, optional) or type(body.ok) ~= 'boolean' or not MESSAGE_CODES[body.code] then return nil end
        if body.requestId ~= nil and not integer(body.requestId, 1, 2147483647) then return nil end
        if body.offerId ~= nil and body.offerId ~= OFFER_ID then return nil end
        if (body.requestId == nil) ~= (body.offerId == nil) then return nil end
        if body.ok ~= (body.code == 'ok') then return nil end
        if body.requestId == nil and body.code ~= 'unavailable' then return nil end
    else
        return nil
    end
    return { action = payload.action, body = body }
end
