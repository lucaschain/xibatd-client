-- Run from the client source root: luajit tests/xibat_replay_test.lua
local online, logging, loaded, played, stopped = false, false, true, nil, false
local versions = {}
g_game = {
    isOnline = function() return online end,
    isLogging = function() return logging end,
    setClientVersion = function(v) versions[#versions+1] = v end,
    setProtocolVersion = function(v) assert(v == 1098) end,
    playRecord = function(name) played = name end,
    forceLogout = function() stopped = true end,
    cancelLogin = function() stopped = true end,
}
modules = { game_things = { isLoaded = function() return loaded end } }
local originalOpen = io.open
io.open = function(path)
    if path ~= 'records/hive-timeout.rec' then return nil end
    return { read = function() return '< 0 430100' end, close = function() end }
end
dofile('modules/client_replay/replay.lua')
assert(not play('../escape.rec'))
assert(not play('missing.rec'))
online = true
assert(not play('hive-timeout.rec'))
online, logging = false, true
assert(not play('hive-timeout.rec'))
logging, loaded = false, false
assert(not play('hive-timeout.rec'))
assert(played == nil)
loaded = true
assert(play('hive-timeout.rec'))
assert(played == 'hive-timeout.rec')
assert(versions[#versions-1] == 0 and versions[#versions] == 1098)
assert(not play('hive-timeout.rec'))
stop()
assert(stopped)
-- Stopping a replay must not later log out an unrelated live session.
stopped, online = false, true
stop()
assert(not stopped)
io.open = originalOpen
print('Xibat replay entry-point tests passed')
