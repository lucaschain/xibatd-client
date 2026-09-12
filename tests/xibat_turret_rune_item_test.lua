local root = assert(arg[1], "repository root argument is required")

UIItem = {}

local createdOverlay = nil
g_ui = {
    createWidget = function(style, parent)
        assert(style == 'TurretRuneLevelOverlay' and parent, "unexpected overlay creation")
        local overlay = { visible = false }
        function overlay:setId(id) self.id = id end
        function overlay:setText(text) self.text = text end
        function overlay:show() self.visible = true end
        function overlay:hide() self.visible = false end
        createdOverlay = overlay
        return overlay
    end,
}

dofile(root .. '/modules/game_interface/widgets/uiitem.lua')

local item = { runeLevel = 201 }
function item:isTurretRune() return self.runeLevel >= 0 end
function item:getRuneLevel() return self.runeLevel end

local widget = { item = item }
function widget:getItem() return self.item end
function widget:getChildById(id)
    return createdOverlay and createdOverlay.id == id and createdOverlay or nil
end

UIItem.refreshTurretRuneLevel(widget)
assert(createdOverlay and createdOverlay.visible and createdOverlay.text == '2/0/1',
    'upgraded rune overlay was not formatted in branch order')

item.runeLevel = 0
UIItem.refreshTurretRuneLevel(widget)
assert(createdOverlay.visible and createdOverlay.text == '0/0/0',
    'unupgraded rune overlay was hidden or formatted incorrectly')

item.runeLevel = -1
UIItem.refreshTurretRuneLevel(widget)
assert(not createdOverlay.visible, 'ordinary item retained the rune overlay')

print('xibat turret rune item tests passed')
