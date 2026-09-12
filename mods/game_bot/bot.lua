botWindow = nil
botButton = nil
contentsPanel = nil

local checkEvent = nil

local botStorage = {}
local botStorageFile = nil
local botWebSockets = {}
local botMessages = nil
local botTabs = nil
local botExecutor = nil

local enableButton = nil
local executeEvent = nil
local statusLabel = nil
local copyFilesRecursively

local BOT_CONFIG = "nExBot"
local BOT_REVISION = "xibat-3"

function init()
  dofile("executor")

  g_ui.importStyle("ui/basic.otui")
  g_ui.importStyle("ui/panels.otui")
  g_ui.importStyle("ui/config.otui")
  g_ui.importStyle("ui/icons.otui")
  g_ui.importStyle("ui/container.otui")

  connect(g_game, {
    onGameStart = online,
    onGameEnd = offline,
  })

  initCallbacks()

  botButton = modules.game_mainpanel.addToggleButton('botButton', tr('Bot'), '/images/options/bot', toggle, false, 99999)
  botButton:setOn(false)
  botButton:show()

  botWindow = g_ui.loadUI('bot', modules.game_interface.getLeftPanel())
  botWindow:setup()

  -- Hide unwanted miniwindow buttons
  local toggleFilterButton = botWindow:recursiveGetChildById('toggleFilterButton')
  if toggleFilterButton then
    toggleFilterButton:setVisible(false)
  end
  
  local contextMenuButton = botWindow:recursiveGetChildById('contextMenuButton')
  if contextMenuButton then
    contextMenuButton:setVisible(false)
  end
  
  local newWindowButton = botWindow:recursiveGetChildById('newWindowButton')
  if newWindowButton then
    newWindowButton:setVisible(false)
  end
  
  -- Position lockButton where toggleFilterButton would be (to the left of minimize button)
  local lockButton = botWindow:recursiveGetChildById('lockButton')
  local minimizeButton = botWindow:recursiveGetChildById('minimizeButton')
  
  if lockButton and minimizeButton then
    lockButton:setVisible(true)
    lockButton:breakAnchors()
    lockButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
    lockButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
    lockButton:setMarginRight(7)  -- Same margin as toggleFilterButton would have
    lockButton:setMarginTop(0)
    lockButton:setSize({width = 12, height = 12})
  end

  contentsPanel = botWindow.contentsPanel
  enableButton = contentsPanel.enableButton
  statusLabel = contentsPanel.statusLabel
  botMessages = contentsPanel.messages
  botTabs = contentsPanel.botTabs
  botTabs:setContentWidget(contentsPanel.botPanel)

  createDefaultConfig()

  enableButton.onClick = function()
    if g_game.isOnline() then
      refresh()
    else
      statusLabel:setOn(true)
      statusLabel:setText("Status: login to enable bot")
    end
  end

  if g_game.isOnline() then
    clear()
    online()
  end
end

function terminate()
  save()
  clear()

  disconnect(g_game, {
    onGameStart = online,
    onGameEnd = offline,
  })

  terminateCallbacks()
  botWindow:destroy()
  botButton:destroy()
end

function clear()
  botExecutor = nil
  removeEvent(checkEvent)

  -- optimization, callback is not used when not needed
  g_game.enableTileThingLuaCallback(false)

  botTabs:clearTabs()
  botTabs:setOn(false)
  botTabs:setHeight(0)

  botMessages:destroyChildren()
  botMessages:updateLayout()

  for i, socket in pairs(botWebSockets) do
    HTTP.cancel(i)
    botWebSockets[i] = nil
  end

  for i, widget in pairs(g_ui.getRootWidget():getChildren()) do
    if widget.botWidget then
      widget:destroy()
    end
  end
  for i, widget in pairs(modules.game_interface.gameMapPanel:getChildren()) do
    if widget.botWidget then
      widget:destroy()
    end
  end
  for _, widget in pairs({modules.game_interface.getRightPanel(), modules.game_interface.getLeftPanel()}) do
    for i, child in pairs(widget:getChildren()) do
      if child.botWidget then
        child:destroy()
      end
    end
  end

  local gameMapPanel = modules.game_interface.getMapPanel()
  if gameMapPanel then
    gameMapPanel:unlockVisibleFloor()
  end

  if g_sounds then
    g_sounds.getChannel(SoundChannels.Bot):stop()
  end
end

local function updateBotTabsHeight()
  botTabs:updateLayout()
  local layout = botTabs:getLayout()
  if not botTabs:isOn() or not (layout and layout:isUIGridLayout()) then
    botTabs:setHeight(0)
    return
  end

  local lines = layout:getNumLines()
  if lines <= 0 then
    botTabs:setHeight(0)
    return
  end

  botTabs:setHeight(lines * layout:getCellSize().height)
end

function getConfigName()
  return BOT_CONFIG
end

function createDefaultConfig()
  if not g_resources.directoryExists("/bot") then
    g_resources.makeDir("/bot")
    if not g_resources.directoryExists("/bot") then return end
  end
  local targetDir = "/bot/" .. BOT_CONFIG
  local revisionFile = targetDir .. "/xibat-revision"
  if not g_resources.directoryExists(targetDir) then
    g_resources.makeDir(targetDir)
    if not g_resources.directoryExists(targetDir) then
      return onError("Can't create directory: " .. targetDir)
    end
  end
  local installedRevision = g_resources.fileExists(revisionFile) and g_resources.readFileContents(revisionFile) or ""
  if installedRevision:gsub("%s+$", "") ~= BOT_REVISION then
    copyFilesRecursively("default_configs/" .. BOT_CONFIG, targetDir)
  end
end

function refresh()
  if not g_game.isOnline() then return end
  save()
  clear()

  createDefaultConfig()
  if not g_resources.directoryExists("/bot/" .. BOT_CONFIG) then
    statusLabel:setOn(true)
    statusLabel:setText("nExBot is missing from " .. g_resources.getWriteDir() .. "bot/")
    return
  end

  -- select active config based on settings
  local settings = g_settings.getNode('bot') or {}
  local index = g_game.getCharacterName() .. "_" .. g_game.getClientVersion()
  if settings[index] == nil then
    settings[index] = {
      enabled=false,
      config=BOT_CONFIG,
      botRevision=BOT_REVISION
    }
  elseif settings[index].config ~= BOT_CONFIG or settings[index].botRevision ~= BOT_REVISION then
    settings[index].enabled = false
    settings[index].config = BOT_CONFIG
    settings[index].botRevision = BOT_REVISION
    g_settings.setNode('bot', settings)
    g_settings.save()
  end

  enableButton.onClick = nil
  enableButton:setOn(settings[index].enabled)

  enableButton.onClick = function()
    settings[index].enabled = not settings[index].enabled
    g_settings.setNode('bot', settings)
    g_settings.save()
    refresh()
  end

  if not g_game.isOnline() or not settings[index].enabled then
    statusLabel:setOn(true)
    statusLabel:setText("Status: disabled\nPress off button to enable")
    analyzerButton = modules.game_mainpanel.getButton("botAnalyzersButton")
    if analyzerButton then
      analyzerButton:destroy()
    end
    return
  end

  local configName = BOT_CONFIG

  -- storage
  botStorage = {}

  local path = "/bot/" .. configName .. "/storage/"
  if not g_resources.directoryExists(path) then
    g_resources.makeDir(path)
  end

  botStorageFile = path.."profile_" .. g_settings.getNumber('profile') .. ".json"
  if g_resources.fileExists(botStorageFile) then
    local status, result = pcall(function()
      return json.decode(g_resources.readFileContents(botStorageFile))
    end)
    if not status then
      return onError("Error while reading storage (" .. botStorageFile .. "). To fix this problem you can delete storage.json. Details: " .. result)
    end
    botStorage = result
  end

  -- run script
  local status, result = pcall(function()
    return executeBot(configName, botStorage, botTabs, message, save, refresh, botWebSockets) end
  )
  if not status then
    return onError(result)
  end

  updateBotTabsHeight()
  statusLabel:setOn(false)
  botExecutor = result
  check()
end

function save()
  if not botExecutor then
    return
  end

  local settings = g_settings.getNode('bot') or {}
  local index = g_game.getCharacterName() .. "_" .. g_game.getClientVersion()
  if settings[index] == nil then
    return
  end

  local status, result = pcall(function()
    return json.encode(botStorage, 2)
  end)
  if not status then
    return onError("Error while saving bot storage. Storage won't be saved. Details: " .. result)
  end

  if result:len() > 100 * 1024 * 1024 then
    return onError("Storage file is too big, above 100MB, it won't be saved")
  end

  g_resources.writeFileContents(botStorageFile, result)
end

function onMiniWindowClose()
  botButton:setOn(false)
end

function toggle()
  if botButton:isOn() then
    botWindow:close()
    botButton:setOn(false)
  else
    botWindow:open()
    botButton:setOn(true)

    modules.game_interface.checkAndOpenLeftPanel()
  end
end

function online()
  botWindow:setupOnStart()
  if not (modules.client_profiles and modules.client_profiles.ChangedProfile) then
    scheduleEvent(refresh, 20)
  end
end

function offline()
  save()
  clear()
end

function onError(message)
  statusLabel:setOn(true)
  statusLabel:setText("Error:\n" .. message)
  g_logger.error("[BOT] " .. message)
end

copyFilesRecursively = function(sourcePath, targetPath)
    local files = g_resources.listDirectoryFiles(sourcePath, true, false, false)
    for _, file in ipairs(files) do
        local baseName = file:split("/")
        baseName = baseName[#baseName]
        local targetFilePath = targetPath .. "/" .. baseName
        if g_resources.directoryExists(file) then
            g_resources.makeDir(targetFilePath)
            if not g_resources.directoryExists(targetFilePath) then
                return onError("Can't create directory: " .. targetFilePath)
            end
            copyFilesRecursively(file, targetFilePath)
        else
            local contents = g_resources.fileExists(file) and g_resources.readFileContents(file) or ""
            if contents:len() > 0 then
                g_resources.writeFileContents(targetFilePath, contents)
            end
        end
    end
end

-- Executor
function message(category, msg)
  local widget = g_ui.createWidget('BotLabel', botMessages)
  widget.added = g_clock.millis()
  if category == 'error' then
    widget:setText(msg)
    widget:setColor("red")
    g_logger.error("[BOT] " .. msg)
  elseif category == 'warn' then
    widget:setText(msg)
    widget:setColor("yellow")
    g_logger.warning("[BOT] " .. msg)
  elseif category == 'info' then
    widget:setText(msg)
    widget:setColor("white")
    g_logger.info("[BOT] " .. msg)
  end

  if botMessages:getChildCount() > 5 then
    botMessages:getFirstChild():destroy()
  end
end

function check()
  removeEvent(checkEvent)
  if not botExecutor then
    return
  end

  checkEvent = scheduleEvent(check, 10)

  local status, result = pcall(function()
    return botExecutor.script()
  end)
  if not status then
    botExecutor = nil -- critical
    return onError(result)
  end

  -- remove old messages
  local widget = botMessages:getFirstChild()
  if widget and widget.added + 5000 < g_clock.millis() then
    widget:destroy()
  end
end

-- Callbacks
function initCallbacks()
  connect(rootWidget, {
    onKeyDown = botKeyDown,
    onKeyUp = botKeyUp,
    onKeyPress = botKeyPress
  })

  connect(g_game, {
    onTalk = botOnTalk,
    onTextMessage = botOnTextMessage,
    onLoginAdvice = botOnLoginAdvice,
    onUse = botOnUse,
    onUseWith = botOnUseWith,
    onChannelList = botChannelList,
    onOpenChannel = botOpenChannel,
    onCloseChannel = botCloseChannel,
    onChannelEvent = botChannelEvent,
    onImbuementWindow = botImbuementWindow,
    onModalDialog = botModalDialog,
    onAttackingCreatureChange = botAttackingCreatureChange,
    onAddItem = botContainerAddItem,
    onRemoveItem = botContainerRemoveItem,
    onEditText = botGameEditText,
    onSpellCooldown = botSpellCooldown,
    onSpellGroupCooldown = botGroupSpellCooldown
  })

  connect(Tile, {
    onAddThing = botAddThing,
    onRemoveThing = botRemoveThing
  })

  connect(Creature, {
    onAppear = botCreatureAppear,
    onDisappear = botCreatureDisappear,
    onPositionChange = botCreaturePositionChange,
    onHealthPercentChange = botCraetureHealthPercentChange,
    onTurn = botCreatureTurn,
    onWalk = botCreatureWalk,
  })

  connect(LocalPlayer, {
    onPositionChange = botCreaturePositionChange,
    onHealthPercentChange = botCraetureHealthPercentChange,
    onTurn = botCreatureTurn,
    onWalk = botCreatureWalk,
    onManaChange = botManaChange,
    onStatesChange = botStatesChange,
    onInventoryChange = botInventoryChange
  })

  connect(Container, {
    onOpen = botContainerOpen,
    onClose = botContainerClose,
    onUpdateItem = botContainerUpdateItem,
    onAddItem = botContainerAddItem,
    onRemoveItem = botContainerRemoveItem,
  })

  connect(g_map, {
    onMissle = botOnMissle,
    onAnimatedText = botOnAnimatedText,
    onStaticText = botOnStaticText
  })
end

function terminateCallbacks()
  disconnect(rootWidget, {
    onKeyDown = botKeyDown,
    onKeyUp = botKeyUp,
    onKeyPress = botKeyPress
  })

  disconnect(g_game, {
    onTalk = botOnTalk,
    onTextMessage = botOnTextMessage,
    onLoginAdvice = botOnLoginAdvice,
    onUse = botOnUse,
    onUseWith = botOnUseWith,
    onChannelList = botChannelList,
    onOpenChannel = botOpenChannel,
    onCloseChannel = botCloseChannel,
    onChannelEvent = botChannelEvent,
    onImbuementWindow = botImbuementWindow,
    onModalDialog = botModalDialog,
    onAttackingCreatureChange = botAttackingCreatureChange,
    onEditText = botGameEditText,
    onSpellCooldown = botSpellCooldown,
    onSpellGroupCooldown = botGroupSpellCooldown
  })

  disconnect(Tile, {
    onAddThing = botAddThing,
    onRemoveThing = botRemoveThing
  })

  disconnect(Creature, {
    onAppear = botCreatureAppear,
    onDisappear = botCreatureDisappear,
    onPositionChange = botCreaturePositionChange,
    onHealthPercentChange = botCraetureHealthPercentChange,
    onTurn = botCreatureTurn,
    onWalk = botCreatureWalk,
  })

  disconnect(LocalPlayer, {
    onPositionChange = botCreaturePositionChange,
    onHealthPercentChange = botCraetureHealthPercentChange,
    onTurn = botCreatureTurn,
    onWalk = botCreatureWalk,
    onManaChange = botManaChange,
    onStatesChange = botStatesChange,
    onInventoryChange = botInventoryChange
  })

  disconnect(Container, {
    onOpen = botContainerOpen,
    onClose = botContainerClose,
    onUpdateItem = botContainerUpdateItem,
    onAddItem = botContainerAddItem,
    onRemoveItem = botContainerRemoveItem
  })

  disconnect(g_map, {
    onMissle = botOnMissle,
    onAnimatedText = botOnAnimatedText,
    onStaticText = botOnStaticText
  })
end

function safeBotCall(func)
  local status, result = pcall(func)
  if not status then
    onError(result)
  end
end

function botKeyDown(widget, keyCode, keyboardModifiers)
  if botExecutor == nil then return false end
  if keyCode == KeyUnknown then return end
  safeBotCall(function() botExecutor.callbacks.onKeyDown(keyCode, keyboardModifiers) end)
end

function botKeyUp(widget, keyCode, keyboardModifiers)
  if botExecutor == nil then return false end
  if keyCode == KeyUnknown then return end
  safeBotCall(function() botExecutor.callbacks.onKeyUp(keyCode, keyboardModifiers) end)
end

function botKeyPress(widget, keyCode, keyboardModifiers, autoRepeatTicks)
  if botExecutor == nil then return false end
  if keyCode == KeyUnknown then return end
  safeBotCall(function() botExecutor.callbacks.onKeyPress(keyCode, keyboardModifiers, autoRepeatTicks) end)
end

function botOnTalk(name, level, mode, text, channelId, pos)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onTalk(name, level, mode, text, channelId, pos) end)
end

function botOnTextMessage(mode, text)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onTextMessage(mode, text) end)
end

function botOnLoginAdvice(message)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onLoginAdvice(message) end)
end

function botAddThing(tile, thing)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onAddThing(tile, thing) end)
end

function botRemoveThing(tile, thing)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onRemoveThing(tile, thing) end)
end

function botCreatureAppear(creature)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onCreatureAppear(creature) end)
end

function botCreatureDisappear(creature)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onCreatureDisappear(creature) end)
end

function botCreaturePositionChange(creature, newPos, oldPos)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onCreaturePositionChange(creature, newPos, oldPos) end)
end

function botCraetureHealthPercentChange(creature, healthPercent)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onCreatureHealthPercentChange(creature, healthPercent) end)
end

function botOnUse(pos, itemId, stackPos, subType)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onUse(pos, itemId, stackPos, subType) end)
end

function botOnUseWith(pos, itemId, target, subType)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onUseWith(pos, itemId, target, subType) end)
end

function botContainerOpen(container, previousContainer)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onContainerOpen(container, previousContainer) end)
end

function botContainerClose(container)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onContainerClose(container) end)
end

function botContainerUpdateItem(container, slot, item, oldItem)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onContainerUpdateItem(container, slot, item, oldItem) end)
end

function botOnMissle(missle)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onMissle(missle) end)
end

function botOnAnimatedText(thing, text)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onAnimatedText(thing, text) end)
end

function botOnStaticText(thing, text)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onStaticText(thing, text) end)
end

function botChannelList(channels)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onChannelList(channels) end)
end

function botOpenChannel(channelId, name)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onOpenChannel(channelId, name) end)
end

function botCloseChannel(channelId)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onCloseChannel(channelId) end)
end

function botChannelEvent(channelId, name, event)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onChannelEvent(channelId, name, event) end)
end

function botCreatureTurn(creature, direction)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onTurn(creature, direction) end)
end

function botCreatureWalk(creature, oldPos, newPos)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onWalk(creature, oldPos, newPos) end)
end

function botImbuementWindow(itemId, slots, activeSlots, imbuements, needItems)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onImbuementWindow(itemId, slots, activeSlots, imbuements, needItems) end)
end

function botModalDialog(id, title, message, buttons, enterButton, escapeButton, choices, priority)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onModalDialog(id, title, message, buttons, enterButton, escapeButton, choices, priority) end)
end

function botGameEditText(id, itemId, maxLength, text, writer, time)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onGameEditText(id, itemId, maxLength, text, writer, time) end)
end

function botAttackingCreatureChange(creature, oldCreature)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onAttackingCreatureChange(creature,oldCreature) end)
end

function botManaChange(player, mana, maxMana, oldMana, oldMaxMana)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onManaChange(player, mana, maxMana, oldMana, oldMaxMana) end)
end

function botStatesChange(player, states, oldStates)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onStatesChange(player, states, oldStates) end)
end

function botContainerAddItem(container, slot, item, oldItem)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onAddItem(container, slot, item, oldItem) end)
end

function botContainerRemoveItem(container, slot, item)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onRemoveItem(container, slot, item) end)
end

function botSpellCooldown(iconId, duration)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onSpellCooldown(iconId, duration) end)
end

function botGroupSpellCooldown(iconId, duration)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onGroupSpellCooldown(iconId, duration) end)
end

function botInventoryChange(player, slot, item, oldItem)
  if botExecutor == nil then return false end
  safeBotCall(function() botExecutor.callbacks.onInventoryChange(player, slot, item, oldItem) end)
end
