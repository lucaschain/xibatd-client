local GUIDANCE_OPCODE = modules.game_xibat_core.XibatOpcode.Guidance
local PROTOCOL_VERSION = 1
local EDGE_INSET = 12
local TARGET_GAP = 8
local MINIMAP_ICON = '/images/game/minimap/flag18'

local targetMetadata = {
    sergio = { kind = 'npc', name = 'Sergio Rocket', label = 'Talk to Sergio Rocket' },
    nicolai = { kind = 'npc', name = 'Nicolai F', label = 'Get a free turret rune from Nicolai F' },
    raidSelector = { kind = 'tile', label = 'Use the Raid Selector' },
    globe = { kind = 'tile', label = 'Use the Raid Globe to start the wave' },
    araci = { kind = 'npc', name = 'Araci', label = 'Talk to Araci' },
}

xibatGuidanceController = Controller:new()

local function log(message)
    g_logger.warning('[XibatGuidance] ' .. message)
end

local function hasExactFields(value, required)
    if type(value) ~= 'table' then return false end
    for field in pairs(value) do
        if not required[field] then return false end
    end
    for field in pairs(required) do
        if value[field] == nil then return false end
    end
    return true
end

local function isInteger(value, minimum, maximum)
    return type(value) == 'number' and value == math.floor(value) and value >= minimum and value <= maximum
end

local function validatePosition(position)
    return hasExactFields(position, { x = true, y = true, z = true }) and
        isInteger(position.x, 0, 65535) and isInteger(position.y, 0, 65535) and
        isInteger(position.z, 0, 15)
end

local function validatePayload(payload)
    if type(payload) ~= 'table' or payload.version ~= PROTOCOL_VERSION then return nil end
    if payload.action == 'clear' then
        if not hasExactFields(payload, { version = true, action = true }) then return nil end
        return { action = 'clear' }
    end

    if payload.action ~= 'show' or
        not hasExactFields(payload, { version = true, action = true, body = true }) then return nil end
    local body = payload.body
    if not hasExactFields(body, { target = true, position = true }) or
        not targetMetadata[body.target] or not validatePosition(body.position) then return nil end

    return { action = 'show', target = body.target, position = body.position }
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
    self:destroyWidget('edgeWidget')
    self:destroyWidget('minimapMarker')
    self.lastRenderLog = nil
    self.target = nil
end

function xibatGuidanceController:resolveCreature()
    local target = self.target
    if not target or target.kind ~= 'npc' then return nil end

    local panel = modules.game_interface.getMapPanel()
    for _, creature in ipairs(panel:getSpectators(false) or {}) do
        if not creature:isRemoved() and creature:isNpc() and creature:getName() == target.name then return creature end
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

function xibatGuidanceController:showNearby(panel, targetPosition)
    if targetPosition.z ~= panel:getCameraPosition().z or not panel:isInRange(targetPosition) then return false end
    local dimension = panel:getVisibleDimension()
    if not dimension or dimension.width < 1 or dimension.height < 1 then return false end

    local widget = self:getBanner(panel)
    if not widget then return false end
    widget.label:setText(self.target.label)

    local rect = panel:getRect()
    local camera = panel:getCameraPosition()
    local tileWidth = rect.width / dimension.width
    local tileHeight = rect.height / dimension.height
    local x = rect.x + rect.width / 2 + (targetPosition.x - camera.x) * tileWidth - widget:getWidth() / 2
    local y = rect.y + rect.height / 2 + (targetPosition.y - camera.y) * tileHeight -
        tileHeight - widget:getHeight() - TARGET_GAP
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
        log(string.format('render deferred target=%s player=%s panel=%s', self.target.target,
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

    local nearby = self:showNearby(panel, targetPosition)
    local mode = nearby and 'nearby' or
        (self:showEdge(panel, playerPosition, targetPosition) and 'edge' or 'none')
    local renderLog = string.format('%s:%s:%d:%d:%d:%s', self.target.target, mode,
        targetPosition.x, targetPosition.y, targetPosition.z,
        widgetAlive(self.minimapMarker) and 'marker' or 'no-marker')
    if self.lastRenderLog ~= renderLog then
        self.lastRenderLog = renderLog
        log(string.format('render target=%s mode=%s position=%d,%d,%d minimap=%s', self.target.target, mode,
            targetPosition.x, targetPosition.y, targetPosition.z,
            widgetAlive(self.minimapMarker) and 'ready' or 'missing'))
    end
    self.refreshing = false
end

function xibatGuidanceController:onOpcode(_, _, payload)
    log(string.format('opcode received terminated=%s type=%s version=%s action=%s', tostring(self.terminated),
        type(payload), tostring(type(payload) == 'table' and payload.version or nil),
        tostring(type(payload) == 'table' and payload.action or nil)))
    if self.terminated then return end
    local request = validatePayload(payload)
    if not request then
        log('opcode rejected by strict validation')
        return
    end

    if request.action == 'clear' then
        log('clear accepted')
        self:cleanup()
        return
    end

    self:cleanup()
    local metadata = targetMetadata[request.target]
    self.target = {
        target = request.target,
        kind = metadata.kind,
        label = metadata.label,
        name = metadata.name,
        position = { x = request.position.x, y = request.position.y, z = request.position.z },
    }
    log(string.format('show accepted target=%s position=%d,%d,%d online=%s', request.target,
        request.position.x, request.position.y, request.position.z, tostring(g_game.isOnline())))
    if not self.gameReady then
        log('render deferred until game start')
        return
    end
    self:createMinimapMarker(self.target.position, self.target.label)
    self:refresh()
end

function xibatGuidanceController:onInit()
    self.terminated = false
    self.gameReady = false
    log(string.format('initializing opcode=%d online=%s', GUIDANCE_OPCODE, tostring(g_game.isOnline())))
    g_ui.importStyle('guidance.otui')
    self:registerExtendedJSONOpcode(GUIDANCE_OPCODE, function(...) self:onOpcode(...) end)
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
    log(string.format('game start target=%s', self.target and self.target.target or 'none'))
    self.gameReady = true
    if self.target and not widgetAlive(self.minimapMarker) then
        self:createMinimapMarker(self.target.position, self.target.label)
    end
    self:refresh()
end

function xibatGuidanceController:onGameEnd()
    log(string.format('game end target=%s', self.target and self.target.target or 'none'))
    self.gameReady = false
    self:cleanup()
end

function xibatGuidanceController:onTerminate()
    log(string.format('terminating target=%s', self.target and self.target.target or 'none'))
    self.terminated = true
    self:cleanup()
end
