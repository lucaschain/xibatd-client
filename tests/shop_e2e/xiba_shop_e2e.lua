local config = dofile('/shop-e2e-config.lua')
local events = {}
local loginCount = 0
local finished = false
local duplicateAcknowledged = false
local originalShopMessage = modules.game_shop.onGameShopMsg

local function cancelEvents()
    for _, event in ipairs(events) do removeEvent(event) end
    events = {}
end

local function later(callback, delay)
    local event = scheduleEvent(callback, delay)
    events[#events + 1] = event
    return event
end

local function finish(status, message)
    if finished then return end
    finished = true
    cancelEvents()
    g_resources.writeFileContents('/shop-e2e-result.txt', status .. '\n' .. message .. '\n')
    later(function() g_app.exit() end, 100)
end

local function fail(message)
    finish('FAIL', message)
end

local function waitFor(predicate, success, description, attempts)
    attempts = attempts or 0
    if finished then return end
    local ok, result = pcall(predicate)
    if ok and result then
        success(result)
    elseif attempts >= 200 then
        fail('Timed out waiting for ' .. description .. (ok and '' or ': ' .. tostring(result)))
    else
        later(function() waitFor(predicate, success, description, attempts + 1) end, 100)
    end
end

local function shopView()
    local shop = g_ui.getRootWidget():recursiveGetChildById('shopWindow')
    if not shop then return nil end
    local offers = shop:getChildById('offers')
    local details = offers and offers:getChildById('offerDetails')
    local offersList = offers and offers:getChildById('offersList')
    local offer = offersList and offersList:getChildren()[1]
    local balance = shop:getChildById('balance')
    local description = details and details:getChildById('description')
    local descriptionLabel = description and description:getChildren()[1]
    if not details or not offer or not balance or not descriptionLabel then return nil end
    return {
        shop = shop,
        offer = offer,
        details = details,
        balance = balance:getChildById('value'):getText(),
        name = details:getChildById('name'):getText(),
        price = details:getChildById('price'):getText(),
        buy = details:getChildById('buyButton'),
        outfit = details:getChildById('imagePanel'):getChildById('outfit'),
        description = descriptionLabel:getText(),
    }
end

local function assertInitialView(view)
    if view.balance ~= '800' then return fail('Initial balance was ' .. tostring(view.balance)) end
    if view.name ~= 'Philosopher Outfit' then return fail('Unexpected offer title: ' .. tostring(view.name)) end
    if view.price ~= '500' then return fail('Unexpected offer price: ' .. tostring(view.price)) end
    if not view.buy:isEnabled() or view.buy:getText() ~= 'Buy' then return fail('Initial purchase button was not enabled') end
    if not view.outfit:isExplicitlyVisible() then return fail('Outfit preview was not enabled for rendering') end
    local creature = view.outfit:getCreature()
    local outfit = creature and creature:getOutfit()
    if not outfit or outfit.type ~= 873 or outfit.addons ~= 3 then
        return fail('Outfit preview did not contain male looktype 873 with addon mask 3')
    end
    if not view.description:find('both addons', 1, true) then return fail('Offer description did not render') end

    modules.game_shop.onOfferBuy(view.buy)
    modules.game_shop.buyConfirmed()
    waitFor(function()
        local updated = shopView()
        return updated and updated.balance == '300' and updated.buy:getText() == 'Owned' and updated
    end, function()
        g_game.safeLogout()
    end, 'the purchased ownership state')
end

local function assertReconnectView(view)
    if view.balance ~= '300' or view.buy:getText() ~= 'Owned' or view.buy:isEnabled() then
        return fail('Reconnect did not preserve the authoritative owned state')
    end
    modules.game_shop.showHistory()
    waitFor(function()
        local history = view.shop:getChildById('history'):getChildById('list')
        return history and history:getChildCount() == 1
    end, function()
        modules.game_shop.onGameShopMsg = function(data)
            if data.requestId == 1 and data.offerId == 'philosopher-outfit' and
                not data.ok and data.code == 'already_owned' then
                duplicateAcknowledged = true
            end
            return originalShopMessage(data)
        end
        local protocol = g_game.getProtocolGame()
        protocol:sendExtendedJSONOpcode(modules.game_xibat_core.XibatOpcode.Shop, {
            version = 2,
            action = 'purchase',
            requestId = 1,
            catalogRevision = 1,
            offerId = 'philosopher-outfit',
        })
        waitFor(function() return duplicateAcknowledged end, function()
            finish('PASS', 'Authenticated Shop purchase, reconnect, history, and duplicate request completed')
        end, 'the duplicate purchase acknowledgement')
    end, 'the persisted Shop history')
end

local function onGameStart()
    loginCount = loginCount + 1
    modules.game_shop.show()
    waitFor(function()
        local view = shopView()
        return view and view.description ~= 'Loading description...' and view
    end, loginCount == 1 and assertInitialView or assertReconnectView, 'the Shop projection')
end

local function loginCharacter()
    waitFor(function()
        if g_game.isOnline() then return 'online' end
        if CharacterList and CharacterList.isVisible() then return 'character-list' end
        return nil
    end, function(state)
        if state == 'character-list' then CharacterList.doLogin() end
    end, 'the synthetic character list')
end

local function onGameEnd()
    if loginCount == 1 and not finished then later(loginCharacter, 500) end
end

function init()
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    later(function()
        local root = g_ui.getRootWidget()
        local account = root:recursiveGetChildById('accountNameTextEdit')
        local password = root:recursiveGetChildById('accountPasswordTextEdit')
        local host = root:recursiveGetChildById('serverHostTextEdit')
        local port = root:recursiveGetChildById('serverPortTextEdit')
        local client = root:recursiveGetChildById('clientComboBox')
        if not account or not password or not host or not port or not client then
            return fail('Login form was unavailable')
        end
        account:setText(config.account)
        password:setText(config.password)
        host:setText(config.host)
        port:setText(config.loginPort)
        client:setCurrentOption(1098)
        EnterGame.doLogin()
        loginCharacter()
    end, 100)
    later(function() fail('Global Shop smoke timeout') end, 60000)
end

function terminate()
    modules.game_shop.onGameShopMsg = originalShopMessage
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    cancelEvents()
end
