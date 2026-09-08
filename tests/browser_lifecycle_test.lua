local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then
        error(message, 2)
    end
end

local warnings = {}
local gameCallbacks
local disconnectedGameCallbacks

local environment = {
    g_app = {
        hasUpdater = function()
            return false
        end,
    },
    g_game = {
        isOnline = function()
            return false
        end,
    },
    g_window = {
        setCloseWarning = function(enabled)
            warnings[#warnings + 1] = enabled
        end,
    },
}

environment.connect = function(target, callbacks)
    if target == environment.g_game then
        gameCallbacks = callbacks
    end
end
environment.disconnect = function(target, callbacks)
    if target == environment.g_game then
        disconnectedGameCallbacks = callbacks
    end
end
setmetatable(environment, { __index = _G })

local chunk = assert(loadfile(root .. '/modules/client/client.lua'))
setfenv(chunk, environment)
chunk()

environment.init()
requireValue(warnings[1] == false, 'close warning was not initialized from offline game state')
requireValue(gameCallbacks ~= nil, 'game lifecycle callbacks were not connected')

gameCallbacks.onGameStart()
requireValue(warnings[#warnings] == true, 'game start did not enable the close warning')

gameCallbacks.onGameEnd()
requireValue(warnings[#warnings] == false, 'game end did not disable the close warning')

gameCallbacks.onGameStart()
environment.terminate()
requireValue(warnings[#warnings] == false, 'module termination did not clear the close warning')
requireValue(disconnectedGameCallbacks ~= nil, 'game lifecycle callbacks were not disconnected')
requireValue(disconnectedGameCallbacks.onGameStart == gameCallbacks.onGameStart,
    'game start callback was not disconnected by identity')
requireValue(disconnectedGameCallbacks.onGameEnd == gameCallbacks.onGameEnd,
    'game end callback was not disconnected by identity')

print('Browser lifecycle tests passed')
