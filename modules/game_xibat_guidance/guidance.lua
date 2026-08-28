local EDGE_INSET = 12
local TARGET_GAP = 8
local SMOOTH_REFRESH_INTERVAL = 16
local MINIMAP_ICON = '/images/game/minimap/flag18'

xibatGuidanceController = Controller:new()

local function log(message)
    g_logger.warning('[XibatGuidance] ' .. message)
end

local function widgetAlive(widget)
    return widget and not widget:isDestroyed()
end

local function samePosition(left, right)
    return left and right and left.x == right.x and left.y == right.y and left.z == right.z
end

local function floorSuffix(playerPosition, targetPosition)
    if not playerPosition or playerPosition.z == targetPosition.z then return '' end
    local floors = math.abs(targetPosition.z - playerPosition.z)
    local direction = targetPosition.z < playerPosition.z and 'up' or 'down'
    return string.format('\n%d floor%s %s', floors, floors == 1 and '' or 's', direction)
end

local function compassDirection(dx, dy)
    local horizontal = dx < 0 and 'W' or (dx > 0 and 'E' or '')
    local vertical = dy < 0 and 'N' or (dy > 0 and 'S' or '')
    if math.abs(dx) > math.abs(dy) * 2 then return horizontal end
    if math.abs(dy) > math.abs(dx) * 2 then return vertical end
    return vertical .. horizontal
end

function xibatGuidanceController:destroyWidget(field)
    local widget = self[field]
    self[field] = nil
    if widgetAlive(widget) then widget:destroy() end
end

function xibatGuidanceController:cleanup()
    if self.refreshEvent then
        self:removeEvent(self.refreshEvent)
        self.refreshEvent = nil
    end
    self:destroyWidget('edgeWidget')
    self:destroyWidget('minimapMarker')
    self.lastRenderLog = nil
    self.target = nil
end

function xibatGuidanceController:startSmoothRefresh()
    if self.refreshEvent or not self.gameReady or not self.target then return end
    self.refreshEvent = self:cycleEvent(function() self:refresh() end, SMOOTH_REFRESH_INTERVAL,
        'xibatGuidanceSmoothRefresh')
end

function xibatGuidanceController:resolveCreature()
    local target = self.target
    if not target or target.kind ~= 'creature' then return nil end

    local panel = modules.game_interface.getMapPanel()
    for _, creature in ipairs(panel:getSpectators(false) or {}) do
        if not creature:isRemoved() and creature:isNpc() and creature:getName() == target.creatureName then return creature end
    end
    return nil
end

function xibatGuidanceController:createMinimapMarker(position, label)
    local minimap = modules.game_minimap.getMiniMapUi()
    if not minimap or minimap:isDestroyed() then
        log('minimap unavailable')
        return
    end
    local marker = g_ui.createWidget('MinimapFlag')
    if not marker then
        log('failed to create minimap marker')
        return
    end
    minimap:insertChild(1, marker)
    marker.pos = { x = position.x, y = position.y, z = position.z }
    marker.temporary = true
    marker:setIcon(MINIMAP_ICON)
    marker:setTooltip(label)
    minimap:centerInPosition(marker, marker.pos)
    self.minimapMarker = marker
end

function xibatGuidanceController:getBanner(panel)
    local widget = self.edgeWidget
    if not widgetAlive(widget) then
        widget = g_ui.createWidget('XibatGuidanceEdge', panel)
        if not widget then return nil end
        self.edgeWidget = widget
    end
    return widget
end

function xibatGuidanceController:showNearby(panel, targetPosition, creature)
    if targetPosition.z ~= panel:getCameraPosition().z or not panel:isInRange(targetPosition) then return false end
    local anchor = creature and panel:getCreaturePositionPoint(creature) or panel:getMapPositionPoint(targetPosition)
    if not anchor or anchor.x < 0 or anchor.y < 0 then return false end

    local widget = self:getBanner(panel)
    if not widget then return false end
    widget.label:setText(self.target.label)

    local rect = panel:getRect()
    local x = anchor.x - widget:getWidth() / 2
    local y = anchor.y - widget:getHeight() - TARGET_GAP
    x = math.max(rect.x + EDGE_INSET, math.min(x, rect.x + rect.width - widget:getWidth() - EDGE_INSET))
    y = math.max(rect.y + EDGE_INSET, math.min(y, rect.y + rect.height - widget:getHeight() - EDGE_INSET))
    widget:setPosition({ x = math.floor(x), y = math.floor(y) })
    return true
end

function xibatGuidanceController:showEdge(panel, playerPosition, targetPosition)
    local widget = self:getBanner(panel)
    if not widget then return false end

    local dx = targetPosition.x - playerPosition.x
    local dy = targetPosition.y - playerPosition.y
    if dx == 0 and dy == 0 then dy = targetPosition.z < playerPosition.z and -1 or 1 end
    widget.label:setText(string.format('[%s] %s%s', compassDirection(dx, dy), self.target.label,
        floorSuffix(playerPosition, targetPosition)))

    local rect = panel:getRect()
    local halfWidth = math.max(1, rect.width / 2 - widget:getWidth() / 2 - EDGE_INSET)
    local halfHeight = math.max(1, rect.height / 2 - widget:getHeight() / 2 - EDGE_INSET)
    local scale = math.min(halfWidth / math.max(math.abs(dx), 0.001),
        halfHeight / math.max(math.abs(dy), 0.001))
    local x = rect.x + rect.width / 2 + dx * scale - widget:getWidth() / 2
    local y = rect.y + rect.height / 2 + dy * scale - widget:getHeight() / 2
    x = math.max(rect.x + EDGE_INSET, math.min(x, rect.x + rect.width - widget:getWidth() - EDGE_INSET))
    y = math.max(rect.y + EDGE_INSET, math.min(y, rect.y + rect.height - widget:getHeight() - EDGE_INSET))
    widget:setPosition({ x = math.floor(x), y = math.floor(y) })
    return true
end

function xibatGuidanceController:refresh()
    if self.terminated or not self.gameReady or self.refreshing or not self.target or not g_game.isOnline() then return end
    self.refreshing = true

    local player = g_game.getLocalPlayer()
    local panel = modules.game_interface.getMapPanel()
    if not player or not panel or panel:isDestroyed() then
        log(string.format('render deferred cue=%s player=%s panel=%s', self.target.id,
            player and 'ready' or 'missing', panel and not panel:isDestroyed() and 'ready' or 'missing'))
        self.refreshing = false
        return
    end

    local creature = self:resolveCreature()
    local targetPosition = creature and creature:getPosition() or self.target.position
    local playerPosition = player:getPosition()
    if widgetAlive(self.minimapMarker) and not samePosition(self.minimapMarker.pos, targetPosition) then
        self.minimapMarker.pos = { x = targetPosition.x, y = targetPosition.y, z = targetPosition.z }
        local minimap = modules.game_minimap.getMiniMapUi()
        if minimap and not minimap:isDestroyed() then minimap:centerInPosition(self.minimapMarker, self.minimapMarker.pos) end
    end

    local nearby = self:showNearby(panel, targetPosition, creature)
    local mode = nearby and 'nearby' or
        (self:showEdge(panel, playerPosition, targetPosition) and 'edge' or 'none')
    local renderLog = string.format('%s:%s:%d:%d:%d:%s', self.target.id, mode,
        targetPosition.x, targetPosition.y, targetPosition.z,
        widgetAlive(self.minimapMarker) and 'marker' or 'no-marker')
    if self.lastRenderLog ~= renderLog then
        self.lastRenderLog = renderLog
        log(string.format('render cue=%s mode=%s position=%d,%d,%d minimap=%s', self.target.id, mode,
            targetPosition.x, targetPosition.y, targetPosition.z,
            widgetAlive(self.minimapMarker) and 'ready' or 'missing'))
    end
    self.refreshing = false
end

function xibatGuidanceController:setQuestCue(cue)
    if self.terminated or type(cue) ~= 'table' then return end
    self:cleanup()
    self.target = {
        id = cue.id,
        kind = cue.kind,
        label = cue.label,
        creatureName = cue.creatureName,
        position = { x = cue.position.x, y = cue.position.y, z = cue.position.z },
    }
    log(string.format('quest cue accepted id=%s position=%d,%d,%d online=%s', cue.id,
        cue.position.x, cue.position.y, cue.position.z, tostring(g_game.isOnline())))
    if not self.gameReady then
        log('render deferred until game start')
        return
    end
    self:createMinimapMarker(self.target.position, self.target.label)
    self:startSmoothRefresh()
    self:refresh()
end

function xibatGuidanceController:clearQuestCue()
    self:cleanup()
end

function xibatGuidanceController:onInit()
    self.terminated = false
    self.gameReady = false
    log(string.format('initializing quest renderer online=%s', tostring(g_game.isOnline())))
    g_ui.importStyle('guidance.otui')
    local refresh = function() self:refresh() end
    self:registerEvents(LocalPlayer, { onPositionChange = refresh })
    self:registerEvents(Creature, {
        onAppear = refresh,
        onDisappear = refresh,
        onPositionChange = refresh,
    })
    self:registerEvents(UIMap, { onZoomChange = refresh })
    local panel = modules.game_interface.getMapPanel()
    if panel then self:registerEvents(panel, { onGeometryChange = refresh }) end
end

function xibatGuidanceController:onGameStart()
    log(string.format('game start cue=%s', self.target and self.target.id or 'none'))
    self.gameReady = true
    if self.target and not widgetAlive(self.minimapMarker) then
        self:createMinimapMarker(self.target.position, self.target.label)
    end
    self:startSmoothRefresh()
    self:refresh()
end

function xibatGuidanceController:onGameEnd()
    log(string.format('game end cue=%s', self.target and self.target.id or 'none'))
    self.gameReady = false
    self:cleanup()
end

function xibatGuidanceController:onTerminate()
    log(string.format('terminating cue=%s', self.target and self.target.id or 'none'))
    self.terminated = true
    self:cleanup()
end
