local GUIDANCE_OPCODE = modules.game_xibat_core.XibatOpcode.Guidance
local PROTOCOL_VERSION = 1
local ARROW_INSET = 12
local MINIMAP_ICON = '/images/game/minimap/flag18'

local targetMetadata = {
    sergio = { kind = 'npc', name = 'Sergio Rocket', label = 'Sergio Rocket' },
    nicolai = { kind = 'npc', name = 'Nicolai F', label = 'Nicolai F' },
    raidSelector = { kind = 'tile', label = 'Raid Selector' },
    globe = { kind = 'tile', label = 'Raid Globe' },
    araci = { kind = 'npc', name = 'Araci', label = 'Araci' },
}

xibatGuidanceController = Controller:new()

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

function xibatGuidanceController:destroyWidget(field)
    local widget = self[field]
    self[field] = nil
    if widgetAlive(widget) then widget:destroy() end
end

function xibatGuidanceController:cleanup()
    self:destroyWidget('attachedWidget')
    self:destroyWidget('edgeWidget')
    self:destroyWidget('minimapMarker')
    self.attachmentKey = nil
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
    if not minimap or minimap:isDestroyed() then return end
    local marker = g_ui.createWidget('MinimapFlag')
    if not marker then return end
    minimap:insertChild(1, marker)
    marker.pos = { x = position.x, y = position.y, z = position.z }
    marker.temporary = true
    marker:setIcon(MINIMAP_ICON)
    marker:setTooltip(label)
    minimap:centerInPosition(marker, marker.pos)
    self.minimapMarker = marker
end

function xibatGuidanceController:showAttached(targetObject, attachmentKey)
    self:destroyWidget('edgeWidget')
    if widgetAlive(self.attachedWidget) and self.attachmentKey == attachmentKey then return end
    self:destroyWidget('attachedWidget')
    local widget = g_ui.createWidget('XibatGuidanceAttached')
    if not widget then return end
    widget.label:setText(self.target.label)
    self.attachedWidget = widget
    self.attachmentKey = attachmentKey
    targetObject:attachWidget(widget)
end

function xibatGuidanceController:showEdge(playerPosition, targetPosition)
    self:destroyWidget('attachedWidget')
    self.attachmentKey = nil
    local panel = modules.game_interface.getMapPanel()
    if not panel or panel:isDestroyed() then return end

    local widget = self.edgeWidget
    if not widgetAlive(widget) then
        widget = g_ui.createWidget('XibatGuidanceEdge', panel)
        if not widget then return end
        self.edgeWidget = widget
    end

    widget.label:setText(self.target.label .. floorSuffix(playerPosition, targetPosition))
    local dx = targetPosition.x - playerPosition.x
    local dy = targetPosition.y - playerPosition.y
    if dx == 0 and dy == 0 then dy = targetPosition.z < playerPosition.z and -1 or 1 end
    widget.arrow:setRotation(math.deg(math.atan2(dy, dx)))

    local rect = panel:getRect()
    local halfWidth = math.max(1, rect.width / 2 - widget:getWidth() / 2 - ARROW_INSET)
    local halfHeight = math.max(1, rect.height / 2 - widget:getHeight() / 2 - ARROW_INSET)
    local scale = math.min(halfWidth / math.max(math.abs(dx), 0.001),
        halfHeight / math.max(math.abs(dy), 0.001))
    local x = rect.x + rect.width / 2 + dx * scale - widget:getWidth() / 2
    local y = rect.y + rect.height / 2 + dy * scale - widget:getHeight() / 2
    x = math.max(rect.x + ARROW_INSET, math.min(x, rect.x + rect.width - widget:getWidth() - ARROW_INSET))
    y = math.max(rect.y + ARROW_INSET, math.min(y, rect.y + rect.height - widget:getHeight() - ARROW_INSET))
    widget:setPosition({ x = math.floor(x), y = math.floor(y) })
end

function xibatGuidanceController:refresh()
    if self.terminated or self.refreshing or not self.target or not g_game.isOnline() then return end
    self.refreshing = true

    local player = g_game.getLocalPlayer()
    local panel = modules.game_interface.getMapPanel()
    if not player or not panel or panel:isDestroyed() then
        self.refreshing = false
        return
    end

    local creature = self:resolveCreature()
    local targetPosition = creature and creature:getPosition() or self.target.position
    local playerPosition = player:getPosition()
    local visible = targetPosition.z == playerPosition.z and panel:isInRange(targetPosition)
    local targetObject = creature
    if visible and not targetObject then targetObject = g_map.getTile(targetPosition) end

    if widgetAlive(self.minimapMarker) and not samePosition(self.minimapMarker.pos, targetPosition) then
        self.minimapMarker.pos = { x = targetPosition.x, y = targetPosition.y, z = targetPosition.z }
        local minimap = modules.game_minimap.getMiniMapUi()
        if minimap and not minimap:isDestroyed() then minimap:centerInPosition(self.minimapMarker, self.minimapMarker.pos) end
    end

    if visible and targetObject then
        local attachmentKey = creature and ('creature:' .. creature:getId()) or
            string.format('tile:%d:%d:%d', targetPosition.x, targetPosition.y, targetPosition.z)
        self:showAttached(targetObject, attachmentKey)
    else
        self:showEdge(playerPosition, targetPosition)
    end
    self.refreshing = false
end

function xibatGuidanceController:onOpcode(_, _, payload)
    if self.terminated then return end
    local request = validatePayload(payload)
    if not request then return end

    if request.action == 'clear' then
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
    self:createMinimapMarker(self.target.position, self.target.label)
    self:refresh()
end

function xibatGuidanceController:onInit()
    self.terminated = false
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
    self:cleanup()
end

function xibatGuidanceController:onGameEnd()
    self:cleanup()
end

function xibatGuidanceController:onTerminate()
    self.terminated = true
    self:cleanup()
end
