local GAME_SHOP_CODE = modules.game_xibat_core.XibatOpcode.Shop
local REQUEST_TIMEOUT = 5000

local categories = {}
local offers = {}
local history = {}

local gameShopWindow = nil
local selected = nil
local selectedOffer = nil
local msgWindow = nil

local premiumPoints = 0
local premiumSecondPoints = -1
local catalogRevision = nil
local nextRequestId = 0
local pendingRequest = nil
local pendingEvent = nil
local refreshRequired = false
local refreshEvent = nil
local offerDescription = nil
local descriptionPending = false
local refreshShop

local CATEGORY_NONE = -1
local CATEGORY_PREMIUM = 0
local CATEGORY_ITEM = 1
local CATEGORY_BLESSING = 2
local CATEGORY_OUTFIT = 3
local CATEGORY_MOUNT = 4
local CATEGORY_EXTRAS = 5

local searchResultCategoryId = "Search Results"
gameShopController = Controller:new()

function init()
    gameShopController:init()
end

function terminate()
    gameShopController:terminate()
end

function gameShopController:onInit()
    self:registerExtendedJSONOpcode(GAME_SHOP_CODE, onExtendedOpcode)
end

function gameShopController:onGameStart()
    create()
end

function gameShopController:onGameEnd()
    destroy()
end

local function sendRequest(payload)
    gameShopController:sendExtendedJSONOpcode(GAME_SHOP_CODE, payload)
end

function onExtendedOpcode(_, _, payload)
    if not gameShopWindow then return false end
    local response = XibatShopContract.validate(payload)
    if not response then return false end
    local action, data = response.action, response.body

    if action == "fetchBase" then
        onGameShopFetchBase(data)
    elseif action == "fetchOffers" then
        onGameShopFetchOffers(data)
    elseif action == "fetchDescription" then
        onGameShopFetchDescription(data)
    elseif action == "points" then
        onGameShopUpdatePoints(data)
    elseif action == "history" then
        onGameShopUpdateHistory(data)
    elseif action == "msg" then
        onGameShopMsg(data)
    end
    return true
end

function create()
    if gameShopWindow then
        return
    end
    gameShopWindow = g_ui.displayUI("game_shop")
    gameShopWindow:getChildById("categoriesList"):destroyChildren()
    gameShopWindow:getChildById("offers"):getChildById("offersList"):destroyChildren()
    gameShopWindow:getChildById("offers"):getChildById("offerDetails"):
        getChildById("description"):destroyChildren()
    gameShopWindow:getChildById("history"):getChildById("list"):destroyChildren()
    gameShopWindow:hide()

    local protocolGame = g_game.getProtocolGame()
    if protocolGame then
        protocolGame:sendExtendedJSONOpcode(GAME_SHOP_CODE, XibatShopContract.fetchRequest())
    end
end

function destroy()
    if gameShopWindow then
        gameShopWindow:destroy()
        gameShopWindow = nil
    end

    if msgWindow then
        msgWindow:destroy()
        msgWindow = nil
    end

    selected = nil
    selectedOffer = nil
    categories = {}
    offers = {}
    history = {}
    premiumPoints = 0
    premiumSecondPoints = -1
    catalogRevision = nil
    pendingRequest = nil
    refreshRequired = false
    if refreshEvent then gameShopController:removeEvent(refreshEvent) refreshEvent = nil end
    offerDescription = nil
    descriptionPending = false
    if pendingEvent then gameShopController:removeEvent(pendingEvent) pendingEvent = nil end
end

function onGameShopFetchBase(data)
    categories = {}
    offers = {}
    catalogRevision = data.catalogRevision
    selected = nil
    selectedOffer = nil
    offerDescription = nil
    descriptionPending = false
    gameShopWindow:getChildById("categoriesList"):destroyChildren()
    for i = 1, #data.categories do
        addCategory({
            title = data.categories[i].name,
            parent = nil,
            iconId = 8,
            categoryId = CATEGORY_OUTFIT,
            serverCategoryId = data.categories[i].categoryId,
        })
    end
end

function show()
    if not gameShopWindow then
        return
    end

    hideHistory()
    gameShopWindow:show()
    gameShopWindow:raise()
    gameShopWindow:focus()
    if refreshRequired then refreshShop() end
end

function hide()
    if gameShopWindow then
        gameShopWindow:hide()
    end
end

function showHistory()
    sendRequest(XibatShopContract.historyRequest())
    deselect()
    gameShopWindow:getChildById("offers"):hide()
    gameShopWindow:getChildById("history"):show()
end

function hideHistory()
    gameShopWindow:getChildById("offers"):show()
    gameShopWindow:getChildById("history"):hide()
end

local entriesPerPage = 25
local currentPage = 1
local totalPages = 1

function updateHistory()
    local historyPanel = gameShopWindow:getChildById("history")
    local historyList = historyPanel:getChildById("list")
    historyList:destroyChildren()

    local index = ((currentPage - 1) * entriesPerPage) + 1
    for i = index, math.min(#history, index + entriesPerPage - 1) do
        local widget = g_ui.createWidget("HistoryWidget", historyList)
        widget:getChildById("date"):setText(history[i].date)
        widget:getChildById("price"):setText((history[i].price > 0 and "+" or "") .. comma_value(history[i].price))
        widget:getChildById("price"):setOn(history[i].price > 0)
        widget:getChildById("coin"):setOn(history[i].isSecondPrice)
        widget:getChildById("description"):setText(history[i].name)
    end

    historyPanel:getChildById("pageLabel"):setText("Page " .. currentPage .. "/" .. totalPages)
end

function onGameShopUpdateHistory(data)
    currentPage = 1
    history = {}
    for _, entry in ipairs(data.entries) do
        table.insert(history, {
            date = entry.date,
            price = -entry.cost,
            isSecondPrice = false,
            name = entry.title,
            count = 1,
        })
    end
    totalPages = math.max(1, math.ceil(#history / entriesPerPage))

    local historyPanel = gameShopWindow:getChildById("history")
    updateHistory()
    historyPanel:getChildById("nextPageButton"):setVisible(totalPages > 1)
end

function prevPage()
    if currentPage == 1 then
        return true
    end

    currentPage = currentPage - 1

    local historyPanel = gameShopWindow:getChildById("history")
    updateHistory()

    historyPanel:getChildById("nextPageButton"):setVisible(currentPage < totalPages)
    historyPanel:getChildById("prevPageButton"):setVisible(currentPage > 1)
end

function nextPage()
    if currentPage == totalPages then
        return true
    end

    currentPage = currentPage + 1

    local historyPanel = gameShopWindow:getChildById("history")
    updateHistory()

    historyPanel:getChildById("nextPageButton"):setVisible(currentPage < totalPages)
    historyPanel:getChildById("prevPageButton"):setVisible(currentPage > 1)
end

function deselect()
    if selected then
        selected:getChildById("button"):setChecked(false)
        local arrow = selected:getChildById("selectArrow")
        if arrow then
            arrow:hide()
        end

        if not selected:getChildById("subCategories") then
            selected = selected:getParent():getParent()
            selected:getChildById("expandArrow"):show()
        end

        selected:setHeight(22)
        selected:getChildById("subCategories"):hide()
    end
end

function comma_value(n)
    local left, num, right = string.match(n, "^([^%d]*%d)(%d*)(.-)$")
    return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

function onGameShopFetchOffers(data)
    if data.catalogRevision ~= catalogRevision then return end
    local categoryName = categories['Outfits'] and 'Outfits' or next(categories)
    if not categoryName then return end
    offers[categoryName] = {}
    for _, offer in ipairs(data.offers) do
        table.insert(offers[categoryName], {
            offerId = offer.offerId,
            parent = categoryName,
            name = offer.title,
            id = offer.looktype,
            price = offer.cost,
            isSecondPrice = false,
            count = 1,
            addons = offer.addons,
            owned = offer.owned,
            categoryId = CATEGORY_OUTFIT,
        })
    end
    if refreshRequired then
        refreshRequired = false
        pendingRequest = nil
        if refreshEvent then gameShopController:removeEvent(refreshEvent) refreshEvent = nil end
    end
    if not selected then
        local first = gameShopWindow:getChildById("categoriesList"):getChildren()[1]
        if first then select(first:getChildById("button")) end
    end
end

function addCategory(data)
    categories[data.title] = data
    local categoriesList = gameShopWindow:getChildById("categoriesList")
    local category
    if data.parent then
        local parentPanel = categoriesList:getChildById(data.parent)
        category = g_ui.createWidget("ShopSubCategory", parentPanel:getChildById("subCategories"))
        parentPanel:getChildById("expandArrow"):show()
    else
        category = g_ui.createWidget("ShopCategory", categoriesList)
    end

    category:setId(data.title)
    category:getChildById("button"):setIconClip(data.iconId * 13 .. " 0 13 13")
    category:getChildById("name"):setText(data.title)
end

function onGameShopUpdatePoints(data)
    premiumPoints = data.points
    premiumSecondPoints = -1
    local pointsWidget = gameShopWindow:getChildById("balance"):getChildById("value")
    pointsWidget:setText(comma_value(premiumPoints))

    local balanceSecondWidget = gameShopWindow:getChildById("balanceSecond")
    balanceSecondWidget:hide()
    balanceSecondWidget:setWidth(1)
    balanceSecondWidget:setMarginLeft(0)
    if selectedOffer then updateDescription(selectedOffer) end
end

function select(self, ignoreSearch)
    hideHistory()
    if not ignoreSearch then
        eraseSearchResults()
    end

    local selfParent = self:getParent()
    local panel = selfParent:getChildById("subCategories")
    if panel then
        deselect()
        selected = selfParent

        if panel:getChildCount() > 0 then
            panel:show()
            selfParent:setHeight((panel:getChildCount() + 1) * 22)
            selfParent:getChildById("expandArrow"):hide()
            select(panel:getChildren()[1]:getChildById("button"))
        else
            self:setChecked(true)
        end
    else
        if selected then
            selected:getChildById("button"):setChecked(false)

            local arrow = selected:getChildById("selectArrow")
            if arrow then
                arrow:hide()
            end
        end

        selected = selfParent

        self:setChecked(true)
        selfParent:getChildById("selectArrow"):show()
    end

    showOffers(selfParent:getId())
end

function selectOffer(self)
    if selectedOffer then
        selectedOffer:setChecked(false)
    end

    self:setChecked(true)
    selectedOffer = self
    
    if not selectedOffer.categoryId then
        selectedOffer.categoryId = selected:getId()
    end

    updateDescription(self)
end

function showOffers(id)
    local offersCache = offers[id]
    if not offersCache then
        return
    end

    local currentOutfit = g_game.getLocalPlayer():getOutfit()
    local offersPanel = gameShopWindow:getChildById("offers")
    local offersList = offersPanel:getChildById("offersList")
    offersList:destroyChildren()

    for i = 1, #offersCache do
        local widget = offersList:getChildById(offersCache[i].name)
        local price = offersCache[i].price
        if widget then
            local additionalPriceWidget = widget:getChildById("additionalPrice")
            additionalPriceWidget:getChildById("coin"):setOn(offersCache[i].isSecondPrice)
            additionalPriceWidget:getChildById("value"):setText(comma_value(price))
            additionalPriceWidget:show()

            local additionalCountWidget = widget:getChildById("additionalCount")
            additionalCountWidget:setText(offersCache[i].count .. "x")
            additionalCountWidget:show()

            widget:getChildById("count"):show()
            widget.additionalPriceValue = price
            widget.additionalIsSecondPrice = isSecondPrice
            widget.additionalCountValue = offersCache[i].count

            if i == 2 then
                selectOffer(widget)
            end
        else
            local widget = g_ui.createWidget("OfferWidget", offersList)
            local priceWidget = widget:getChildById("price")
            priceWidget:getChildById("coin"):setOn(offersCache[i].isSecondPrice)
            priceWidget:getChildById("value"):setText(comma_value(price))

            widget:getChildById("name"):setText(offersCache[i].name)
            widget:getChildById("count"):setText(offersCache[i].count .. "x")
            widget:setId(offersCache[i].name)
            widget.data = offersCache[i]
            widget.categoryId = id

            local imagePanel = widget:getChildById("imagePanel")
            local image = imagePanel:getChildById("image")
            local categoryId = offersCache[i].categoryId
            local item = imagePanel:getChildById("item")
            local outfit = imagePanel:getChildById("outfit")
            local mount = imagePanel:getChildById("mount")

            if type(offersCache[i].id) == "string" then
                image:show()
                image:setImageSource("/game_shop/images/" .. offersCache[i].id)
            elseif type(offersCache[i].id) == "number" then
                widget.offerCategoryId = categoryId
                if categoryId == CATEGORY_ITEM then
                    item:show()
                    item:setItemId(offersCache[i].id)
                    widget:getChildById("count"):show()
                elseif categoryId == CATEGORY_OUTFIT then
                    currentOutfit.type = offersCache[i].id
                    currentOutfit.addons = offersCache[i].addons
                    outfit:show()
                    outfit:setOutfit(currentOutfit)
                elseif categoryId == CATEGORY_MOUNT then
                    mount:show()
                    mount:setOutfit({type = offersCache[i].id})
                elseif categoryId == CATEGORY_EXTRAS then
                    item:show()
                    item:setItemId(offersCache[i].id)
                end
            end

            if i == 1 then
                selectOffer(widget)
            end
        end
    end
end

function updateDescription(self)
    local offersPanel = gameShopWindow:getChildById("offers")
    local offerDetails = offersPanel:getChildById("offerDetails")
    offerDetails:show()
    offerDetails:getChildById("name"):setText(self.data.name)

    local descriptionPanel = offerDetails:getChildById("description")
    local widget = descriptionPanel:getChildren()[1]
    if not widget then
        widget = g_ui.createWidget("OfferDescriptionLabel", descriptionPanel)
    end

    widget:setText(offerDescription or tr('Loading description...'))
    if not offerDescription and not descriptionPending then
        descriptionPending = true
        sendRequest(XibatShopContract.descriptionRequest(self.data.offerId))
    end

    local buyButton = offerDetails:getChildById("buyButton")
    local priceWidget = offerDetails:getChildById("price")
    local additionalBuyButton = offerDetails:getChildById("additionalBuyButton")
    local additionalPriceWidget = offerDetails:getChildById("additionalPrice")

    priceWidget:setOn(self.data.isSecondPrice)
    priceWidget:setText(comma_value(self.data.price))

    local globalPoints = self.data.isSecondPrice and premiumSecondPoints or premiumPoints
    priceWidget:setEnabled(not self.data.owned and self.data.price <= globalPoints)
    buyButton:setEnabled(not self.data.owned and self.data.price <= globalPoints and
        not pendingRequest and not refreshRequired)

    if self.additionalPriceValue and self.additionalCountValue then
        buyButton:setText("Buy " .. self.data.count)

        additionalPriceWidget:setEnabled(self.additionalPriceValue <= globalPoints)
        additionalBuyButton:setText("Buy " .. self.additionalCountValue)
        additionalBuyButton:show()
        additionalBuyButton:setEnabled(self.additionalPriceValue <= globalPoints)
        additionalBuyButton.price = self.additionalPriceValue
        additionalBuyButton.count = self.additionalCountValue
        buyButton.secondPrice = self.data.secondPrice
        buyButton.price = self.data.price
        buyButton.count = self.data.count

        additionalPriceWidget:setOn(self.data.isSecondPrice)
        additionalPriceWidget:setText(comma_value(self.additionalPriceValue))
        additionalPriceWidget:show()
    else
        additionalBuyButton:hide()

        buyButton.secondPrice = nil
        buyButton.price = nil
        buyButton.count = nil

        buyButton:setText(self.data.owned and "Owned" or
            (pendingRequest or refreshRequired) and "Pending" or "Buy")
        additionalPriceWidget:hide()
    end

    local currentOutfit = g_game.getLocalPlayer():getOutfit()
    local imagePanel = offerDetails:getChildById("imagePanel")
    local image = imagePanel:getChildById("image")
    local item = imagePanel:getChildById("item")
    local outfit = imagePanel:getChildById("outfit")
    local mount = imagePanel:getChildById("mount")
    image:hide()
    item:hide()
    outfit:hide()
    mount:hide()
    if type(self.data.id) == "string" then
        image:show()
        image:setImageSource("/game_shop/images/" .. self.data.id)
    elseif type(self.data.id) == "number" then
        local categoryId = self.offerCategoryId or self.data.offerCategoryId
        if table.contains({CATEGORY_ITEM, CATEGORY_EXTRAS}, categoryId) then
            item:show()
            item:setItemId(self.data.id)
        elseif categoryId == CATEGORY_OUTFIT then
            currentOutfit.type = self.data.id
            currentOutfit.addons = self.data.addons
            outfit:show()
            outfit:setOutfit(currentOutfit)
        elseif categoryId == CATEGORY_MOUNT then
            mount:show()
            mount:setOutfit({type = self.data.id})
        end
    end
end

function onGameShopFetchDescription(data)
    if not selectedOffer then
        return
    end
    
    if selectedOffer.data.offerId ~= data.offerId then
        return
    end

    offerDescription = data.description
    descriptionPending = false

    local offersPanel = gameShopWindow:getChildById("offers")
    local offerDetails = offersPanel:getChildById("offerDetails")
    local descriptionPanel = offerDetails:getChildById("description")
    local widget = descriptionPanel:getChildren()[1]
    if not widget then
        widget = g_ui.createWidget("OfferDescriptionLabel", descriptionPanel)
    end
    widget:setText(data.description)
end

refreshShop = function()
    refreshRequired = true
    sendRequest(XibatShopContract.fetchRequest())
    if refreshEvent then gameShopController:removeEvent(refreshEvent) end
    refreshEvent = gameShopController:scheduleEvent(function()
        refreshEvent = nil
        if refreshRequired then
            displayErrorBox(tr('Store'), tr('The store state could not be refreshed. Reopen the store to retry.'))
        end
    end, REQUEST_TIMEOUT)
end

function onOfferBuy(self)
    if not selectedOffer or selectedOffer.data.owned or pendingRequest or refreshRequired then
        displayInfoBox("Error", "Something went wrong, make sure to select category and offer.")
        return
    end

    hide()

    local title = "Purchase Confirmation"
    local msg = "Do you want to buy " .. selectedOffer.data.name .. " for " ..
        comma_value(selectedOffer.data.price) .. " points?"
    msgWindow = displayGeneralBox(title, msg, {
        {text = "Yes", callback = buyConfirmed},
        {text = "No", callback = buyCanceled},
        anchor = AnchorHorizontalCenter
    }, buyConfirmed, buyCanceled)
end

function buyConfirmed()
    if not selectedOffer or selectedOffer.data.owned or pendingRequest or refreshRequired or not catalogRevision then
        if msgWindow then msgWindow:destroy() msgWindow = nil end
        return
    end

    local offer = selectedOffer.data
    nextRequestId = nextRequestId % 2147483647 + 1
    pendingRequest = {requestId = nextRequestId, offerId = offer.offerId}
    sendRequest(XibatShopContract.purchaseRequest(nextRequestId, catalogRevision, offer.offerId))
    if pendingEvent then gameShopController:removeEvent(pendingEvent) end
    pendingEvent = gameShopController:scheduleEvent(function()
        pendingEvent = nil
        if not pendingRequest then return end
        show()
        if selectedOffer then updateDescription(selectedOffer) end
        refreshShop()
        displayErrorBox(tr('Store'), tr('The purchase response timed out. Reopen the store to refresh its state.'))
    end, REQUEST_TIMEOUT)
    msgWindow:destroy()
    msgWindow = nil
    if selectedOffer then updateDescription(selectedOffer) end
end

function buyCanceled()
    msgWindow:destroy()
    msgWindow = nil
    show()
end

function onGameShopMsg(data)
    if data.requestId then
        if not pendingRequest or data.requestId ~= pendingRequest.requestId or data.offerId ~= pendingRequest.offerId then
            return
        end
        pendingRequest = nil
        if pendingEvent then gameShopController:removeEvent(pendingEvent) pendingEvent = nil end
    elseif pendingRequest and not refreshRequired then
        return
    end

    local messages = {
        ok = tr('The Philosopher Outfit was added to your character.'),
        already_owned = tr('This character already owns the Philosopher Outfit.'),
        insufficient_points = tr('You do not have enough premium points.'),
        pending = tr('The purchase is being finalized. Reopen the store to refresh its state.'),
        unavailable = tr('The store is temporarily unavailable.'),
    }
    local message = messages[data.code] or tr('The store could not complete this request.')
    if data.ok or data.code == 'already_owned' then
        for _, categoryOffers in pairs(offers) do
            for _, offer in ipairs(categoryOffers) do
                if offer.offerId == data.offerId then offer.owned = true end
            end
        end
        if selectedOffer then updateDescription(selectedOffer) end
        refreshShop()
        displayInfoBox(tr('Store'), message)
    else
        if selectedOffer then updateDescription(selectedOffer) end
        if data.requestId then refreshShop() end
        displayErrorBox(tr('Store'), message)
    end
end

function toggle()
    if not gameShopWindow then
        return
    end

    if gameShopWindow:isVisible() then
        return hide()
    end

    show()
end

function onTypeSearch(self)
    gameShopWindow:getChildById("searchButton"):setEnabled(#self:getText() > 2)
end

function eraseSearchResults()
    local widget = gameShopWindow:getChildById("categoriesList"):getChildById(searchResultCategoryId)
    if widget then
        if selected == widget then
            selected = nil
        end
        widget:destroy()
    end
end

function onSearch()
    local searchTextEdit = gameShopWindow:getChildById("searchTextEdit")
    local text = searchTextEdit:getText()

    if #text < 3 then
        return
    end

    eraseSearchResults()
    addCategory(
        {
            title = searchResultCategoryId,
            iconId = 7,
            categoryId = CATEGORY_NONE
        }
    )

    offers[searchResultCategoryId] = {}
    local results = {}
    local searchTerm = text:lower()

    for categoryId, offerData in pairs(offers) do
        if categoryId ~= searchResultCategoryId then
            for _, offer in pairs(offerData) do
                if string.find(offer.name:lower(), searchTerm) then
                    local offerCopy = table.copy(offer)
                    offerCopy.originalCategory = categoryId
                    offerCopy.offerCategoryId = offer.categoryId
                    table.insert(results, offerCopy)
                end
            end
        end
    end

    for _, offer in ipairs(results) do
        table.insert(offers[searchResultCategoryId], offer)
    end

    local children = gameShopWindow:getChildById("categoriesList"):getChildren()
    select(children[#children]:getChildById("button"), true)
    searchTextEdit:clearText()
end
