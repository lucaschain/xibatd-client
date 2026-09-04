local root = arg[1] or '.'

local function requireValue(condition, message)
    if not condition then
        error(message, 2)
    end
end

local existingFiles = {}
local environment = {
    g_resources = {
        fileExists = function(path)
            return existingFiles[path] == true
        end
    }
}
setmetatable(environment, { __index = _G })

local chunk = assert(loadfile(root .. '/modules/client_assets/client_assets.lua'))
setfenv(chunk, environment)
chunk()

requireValue(not environment.isClientVersionInstalled(1098),
    '1098 was accepted without Tibia.dat and Tibia.spr')

existingFiles['/data/things/1098/Tibia.dat'] = true
requireValue(not environment.isClientVersionInstalled(1098),
    '1098 was accepted without Tibia.spr')

existingFiles['/data/things/1098/Tibia.spr'] = true
requireValue(environment.isClientVersionInstalled(1098),
    '1098 was rejected with both required files installed')

requireValue(not environment.isClientVersionInstalled('invalid'),
    'a non-numeric client version was accepted')

print('Legacy client asset tests passed')
