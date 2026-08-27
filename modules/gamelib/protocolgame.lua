local opcodeCallbacks = {}
local extendedCallbacks = {}
local extendedJSONCallbacks = {}
local maxPacketSize = 65000
local maxJSONSize = 1024 * 1024

local function decodeExtendedJSON(opcode, buffer, callback, protocol)
    local status, data = pcall(json.decode, buffer)
    if not status then
        g_logger.error('Invalid data in extended JSON opcode ' .. opcode .. ': ' .. tostring(data))
        return
    end

    callback(protocol, opcode, data)
end

local function clearExtendedJSONOpcode(opcode)
    local protocol = g_game and g_game.getProtocolGame and g_game.getProtocolGame()
    local fragments = protocol and protocol.extendedJSONData
    if fragments then
        fragments[opcode] = nil
    end
end

local function appendExtendedJSONFragment(protocol, opcode, fragment)
    local fragments = protocol.extendedJSONData
    local data = fragments and fragments[opcode]
    if not data then
        return nil
    end

    if #data + #fragment > maxJSONSize then
        fragments[opcode] = nil
        g_logger.error('Extended JSON opcode ' .. opcode .. ' exceeded the reassembly limit')
        return nil
    end

    fragments[opcode] = data .. fragment
    return fragments[opcode]
end

function ProtocolGame:onOpcode(opcode, msg)
    for i, callback in pairs(opcodeCallbacks) do
        if i == opcode then
            callback(self, msg)
            return true
        end
    end
    return false
end

function ProtocolGame:onExtendedOpcode(opcode, buffer)
    local callback = extendedCallbacks[opcode]
    if callback then
        callback(self, opcode, buffer)
    end

    callback = extendedJSONCallbacks[opcode]
    if callback then
        local status = buffer:sub(1, 1) -- O - just one message, S - start, P - part, E - end
        local data = buffer:sub(2)

        if status == 'S' then
            if #data > maxJSONSize then
                g_logger.error('Extended JSON opcode ' .. opcode .. ' exceeded the reassembly limit')
                if self.extendedJSONData then
                    self.extendedJSONData[opcode] = nil
                end
                return
            end
            self.extendedJSONData = self.extendedJSONData or {}
            self.extendedJSONData[opcode] = data
            return
        end

        if status == 'P' or status == 'E' then
            local reassembled = appendExtendedJSONFragment(self, opcode, data)
            if not reassembled or status == 'P' then
                return
            end

            self.extendedJSONData[opcode] = nil
            decodeExtendedJSON(opcode, reassembled, callback, self)
            return
        end

        if self.extendedJSONData then
            self.extendedJSONData[opcode] = nil
        end
        if #buffer > maxJSONSize then
            g_logger.error('Extended JSON opcode ' .. opcode .. ' exceeded the reassembly limit')
            return
        end
        decodeExtendedJSON(opcode, buffer, callback, self)
    end
end

function ProtocolGame.registerOpcode(opcode, callback)
    if opcodeCallbacks[opcode] then
        error('opcode ' .. opcode .. ' already registered will be overriden')
    end

    opcodeCallbacks[opcode] = callback
end

function ProtocolGame.unregisterOpcode(opcode)
    opcodeCallbacks[opcode] = nil
end

function ProtocolGame.registerExtendedOpcode(opcode, callback)
    if not callback or type(callback) ~= 'function' then
        error('Invalid callback.')
    end

    if opcode < 0 or opcode > 255 then
        error('Invalid opcode. Range: 0-255')
    end

    if extendedCallbacks[opcode] then
        error('Opcode is already taken.')
    end

    extendedCallbacks[opcode] = callback
end

function ProtocolGame.unregisterExtendedOpcode(opcode)
    if opcode < 0 or opcode > 255 then
        error('Invalid opcode. Range: 0-255')
    end

    if not extendedCallbacks[opcode] then
        error('Opcode is not registered.')
    end

    extendedCallbacks[opcode] = nil
end

function ProtocolGame.registerExtendedJSONOpcode(opcode, callback)
    if not callback or type(callback) ~= 'function' then
        error('Invalid callback.')
    end

    if opcode < 0 or opcode > 255 then
        error('Invalid opcode. Range: 0-255')
    end

    if extendedJSONCallbacks[opcode] then
        error('Opcode is already taken.')
    end

    clearExtendedJSONOpcode(opcode)
    extendedJSONCallbacks[opcode] = callback
end

function ProtocolGame.unregisterExtendedJSONOpcode(opcode)
    if opcode < 0 or opcode > 255 then
        error('Invalid opcode. Range: 0-255')
    end

    if not extendedJSONCallbacks[opcode] then
        error('Opcode is not registered.')
    end

    clearExtendedJSONOpcode(opcode)
    extendedJSONCallbacks[opcode] = nil
end

function ProtocolGame:sendExtendedJSONOpcode(opcode, data)
    if opcode < 0 or opcode > 255 then
        error('Invalid opcode. Range: 0-255')
    end
    if type(data) ~= 'table' then
        error('Invalid data type, should be table')
    end

    local buffer = json.encode(data)
    local s = {}
    for i = 1, #buffer, maxPacketSize do
        s[#s + 1] = buffer:sub(i, i + maxPacketSize - 1)
    end
    if #s == 1 then
        self:sendExtendedOpcode(opcode, s[1])
        return
    end
    self:sendExtendedOpcode(opcode, 'S' .. s[1])
    for i = 2, #s - 1 do
        self:sendExtendedOpcode(opcode, 'P' .. s[i])
    end
    self:sendExtendedOpcode(opcode, 'E' .. s[#s])
end
