WebSocketEndpoints = {}

local function encodePathSegment(value)
    return tostring(value):gsub('([^%w%-_%.~])', function(character)
        return string.format('%%%02X', string.byte(character))
    end)
end

local function validateUrl(url, endpointName)
    if type(url) ~= 'string' or url == '' then
        return nil, string.format('Missing browser WebSocket %s endpoint.', endpointName)
    end

    local authority = url:match('^wss?://([^/%?#]+)')
    if not authority or authority:find('%s') or authority:find('@', 1, true) then
        return nil, string.format('Browser WebSocket %s endpoint must be a valid ws:// or wss:// URL.', endpointName)
    end

    if url:find('#', 1, true) then
        return nil, string.format('Browser WebSocket %s endpoint must not contain a URL fragment.', endpointName)
    end

    local port
    if authority:sub(1, 1) == '[' then
        local closeBracket = authority:find(']', 2, true)
        local suffix = closeBracket and authority:sub(closeBracket + 1) or nil
        if not closeBracket or closeBracket == 2 or (suffix ~= '' and not suffix:match('^:%d+$')) then
            return nil, string.format('Browser WebSocket %s endpoint has an invalid IPv6 authority.', endpointName)
        end
        port = suffix ~= '' and suffix:sub(2) or nil
    elseif authority:find(':', 1, true) then
        local host
        host, port = authority:match('^([^:]+):(%d+)$')
        if not host then
            return nil, string.format('Browser WebSocket %s endpoint has an invalid authority.', endpointName)
        end
    end

    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then
        return nil, string.format('Browser WebSocket %s endpoint has an invalid port.', endpointName)
    end

    if url:find('[{}]') then
        return nil, string.format('Browser WebSocket %s endpoint contains an unresolved placeholder.', endpointName)
    end

    return url
end

local function getConfig(server)
    if type(server) ~= 'table' or type(server.browserWebSocket) ~= 'table' then
        return nil, 'Missing browserWebSocket configuration for this server.'
    end
    return server.browserWebSocket
end

function WebSocketEndpoints.resolveLogin(server)
    local config, errorMessage = getConfig(server)
    if not config then
        return nil, errorMessage
    end
    return validateUrl(config.login, 'login')
end

function WebSocketEndpoints.resolveWorld(server, worldId, worldName)
    local config, errorMessage = getConfig(server)
    if not config then
        return nil, errorMessage
    end

    if type(config.world) ~= 'string' or config.world == '' then
        return nil, 'Missing browser WebSocket world endpoint.'
    end

    local url = config.world
    if url:find('{worldId}', 1, true) then
        if worldId == nil or tostring(worldId) == '' then
            return nil, 'Browser WebSocket world endpoint requires a worldId that the login response did not provide.'
        end
        url = url:gsub('{worldId}', function()
            return encodePathSegment(worldId)
        end)
    end

    if url:find('{worldName}', 1, true) then
        if worldName == nil or tostring(worldName) == '' then
            return nil, 'Browser WebSocket world endpoint requires a worldName that the login response did not provide.'
        end
        url = url:gsub('{worldName}', function()
            return encodePathSegment(worldName)
        end)
    end

    return validateUrl(url, 'world')
end
