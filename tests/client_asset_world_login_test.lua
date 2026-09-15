local root = arg[1] or '.'
local pending, connections, reloads, errors = nil, 0, {}, 0
local env = {
  G = { account = 'synthetic', password = 'fixture' },
  g_game = {
    isOnline = function() return false end,
    getClientVersion = function() return 1098 end,
    setClientVersion = function(version) reloads[#reloads + 1] = version end,
    loginWorld = function() connections = connections + 1 end,
  },
  g_platform = { isBrowser = function() return false end },
  g_settings = { set = function() end },
  modules = {
    client_assets = {
      requiresRevisionCheck = function() return true end,
      ensureClientVersion = function(version, callback) assert(version == 1098) pending = callback end,
    },
    game_things = { isLoaded = function() return true end },
  },
  tr = function(text) return text end,
  displayErrorBox = function() errors = errors + 1 end,
  displayCancelBox = function() return {} end,
  connect = function() end,
}
setmetatable(env, { __index = _G })
local chunk = assert(loadfile(root .. '/modules/client_entergame/characterlist.lua'))
setfenv(chunk, env)()
env.CharacterList.hide = function() end
env.CharacterList.show = function() end
-- Exercise the actual private world-connection boundary used by character
-- selection, the waiting-list retry and auto-reconnect, without rendering UI.
local tryLogin
for i = 1, 30 do
  local name, value = debug.getupvalue(env.CharacterList.doLogin, i)
  if not name then break end
  if name == 'tryLogin' then tryLogin = value end
end
assert(tryLogin)
local character = { worldName = 'fixture', characterName = 'synthetic', worldHost = '127.0.0.1', worldPort = 7172 }
tryLogin(character)
assert(pending and connections == 0, 'World connection bypassed asset check')
pending(false, 'network failure')
assert(connections == 0 and errors == 1, 'Failed requirement check connected anyway')
tryLogin(character)
pending(true)
assert(connections == 1 and reloads[1] == 0 and reloads[2] == 1098, 'Same-version assets were not reloaded')
pending = nil
tryLogin(character)
assert(pending and connections == 1, 'Reconnect bypassed the current requirement')
pending(false, 'canceled')
assert(connections == 1)
print('Character selection and reconnect asset gate tests passed')
