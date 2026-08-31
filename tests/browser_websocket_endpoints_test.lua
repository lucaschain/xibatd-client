local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then
        error(message, 2)
    end
end

local environment = {}
setmetatable(environment, { __index = _G })
local chunk = assert(loadfile(root .. '/modules/gamelib/websocketendpoints.lua'))
setfenv(chunk, environment)
chunk()

local endpoints = environment.WebSocketEndpoints

local production = {
    browserWebSocket = {
        login = 'wss://play.example.com/login',
        world = 'wss://play.example.com/world/{worldId}'
    }
}

local loginUrl, loginError = endpoints.resolveLogin(production)
requireValue(loginUrl == 'wss://play.example.com/login' and loginError == nil,
    'login endpoint was not preserved')

local worldUrl, worldError = endpoints.resolveWorld(production, 7, 'Antica')
requireValue(worldUrl == 'wss://play.example.com/world/7' and worldError == nil,
    'worldId endpoint was not expanded')

local byName = {
    browserWebSocket = {
        login = 'ws://localhost:8080/login',
        world = 'ws://localhost:8080/world/{worldName}'
    }
}

local namedUrl = endpoints.resolveWorld(byName, nil, 'Preview World/One')
requireValue(namedUrl == 'ws://localhost:8080/world/Preview%20World%2FOne',
    'worldName endpoint was not percent-encoded')

local missingUrl, missingError = endpoints.resolveLogin(nil)
requireValue(missingUrl == nil and missingError:find('browserWebSocket', 1, true),
    'missing browser configuration was accepted')

local invalidUrl, invalidError = endpoints.resolveLogin({
    browserWebSocket = { login = 'https://play.example.com/login' }
})
requireValue(invalidUrl == nil and invalidError:find('ws:// or wss://', 1, true),
    'HTTP endpoint was accepted as a WebSocket endpoint')

local fragmentUrl, fragmentError = endpoints.resolveLogin({
    browserWebSocket = { login = 'wss://play.example.com/login#secret' }
})
requireValue(fragmentUrl == nil and fragmentError:find('URL fragment', 1, true),
    'WebSocket URL fragment was accepted')

local invalidPortUrl, invalidPortError = endpoints.resolveLogin({
    browserWebSocket = { login = 'wss://play.example.com:70000/login' }
})
requireValue(invalidPortUrl == nil and invalidPortError:find('invalid port', 1, true),
    'out-of-range WebSocket port was accepted')

local ipv6Url = endpoints.resolveLogin({
    browserWebSocket = { login = 'ws://[::1]:8080/login' }
})
requireValue(ipv6Url == 'ws://[::1]:8080/login', 'valid IPv6 WebSocket endpoint was rejected')

local missingWorldId, missingWorldIdError = endpoints.resolveWorld(production, nil, 'Antica')
requireValue(missingWorldId == nil and missingWorldIdError:find('worldId', 1, true),
    'missing worldId was accepted')

local unresolvedUrl, unresolvedError = endpoints.resolveWorld({
    browserWebSocket = {
        world = 'wss://play.example.com/world/{unknown}'
    }
}, 7, 'Antica')
requireValue(unresolvedUrl == nil and unresolvedError:find('unresolved placeholder', 1, true),
    'unknown endpoint placeholder was accepted')

print('Browser WebSocket endpoint tests passed')
