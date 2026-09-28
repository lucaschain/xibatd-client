local window
local button
local active = false

local function ended()
    active = false
end

function play(filename)
    if g_game.isOnline() or g_game.isLogging() or active then
        return false, 'Log out or stop the current recording first.'
    end
    if type(filename) ~= 'string' or not filename:match('^[%w_-]+%.rec$') then
        return false, 'Enter a recording filename such as hive-timeout.rec.'
    end
    -- PacketPlayer uses records/ relative to the process working directory,
    -- rather than the resource manager's virtual filesystem.
    local file = io.open('records/' .. filename, 'r')
    if not file then
        return false, 'Recording not found in the client working directory: records/' .. filename
    end
    local first = file:read('*l')
    file:close()
    if not first or not first:match('^< %d+ %x+$') then
        return false, 'The file is not a native packet recording.'
    end
    -- Reinitialize feature flags and load the normal Xibat assets, including
    -- alpha sprites and 16-bit soul. Rune-level support arrives in the recording.
    g_game.setClientVersion(0)
    g_game.setClientVersion(1098)
    g_game.setProtocolVersion(1098)
    if not modules.game_things.isLoaded() then
        return false, 'Install the matching Xibat 1098 assets before playback.'
    end
    local ok, err = pcall(g_game.playRecord, filename)
    if not ok then
        return false, tostring(err)
    end
    active = true
    if window then window:hide() end
    local enter = modules.client_entergame and modules.client_entergame.EnterGame
    if enter then enter.hide() end
    return true
end

function openRecording()
    local ok, err = play(window:getChildById('filename'):getText())
    if not ok then displayErrorBox('Replay', err) end
end

function stop()
    if not active then return end
    if g_game.isOnline() then g_game.forceLogout() else g_game.cancelLogin() end
    active = false
end

function toggle()
    if window:isVisible() then window:hide() else window:show(); window:raise(); window:focus() end
end

function init()
    window = g_ui.displayUI('replay')
    window:hide()
    button = modules.client_topmenu.addTopRightRegularButton('replayButton', 'Run replay', '/images/topbuttons/debug', toggle)
    connect(g_game, { onGameEnd = ended, onLoginError = ended, onConnectionError = ended })
end

function terminate()
    stop()
    disconnect(g_game, { onGameEnd = ended, onLoginError = ended, onConnectionError = ended })
    if button then button:destroy(); button = nil end
    if window then window:destroy(); window = nil end
end
