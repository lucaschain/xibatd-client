local root = arg[1] or "."

local function readFile(path)
    local file = assert(io.open(root .. "/" .. path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function requireMatch(contents, pattern, message)
    if not contents:match(pattern) then error(message, 2) end
end

local function requireAbsent(contents, pattern, message)
    if contents:match(pattern) then error(message, 2) end
end

local bot = readFile("mods/game_bot/bot.lua")
local executor = readFile("mods/game_bot/executor.lua")
local ui = readFile("mods/game_bot/bot.otui")
local loader = readFile("mods/game_bot/default_configs/nExBot/_Loader.lua")

requireMatch(bot, 'local BOT_CONFIG = "nExBot"', "nExBot is not the fixed bot package")
requireMatch(bot, 'local BOT_REVISION = "xibat%-3"', "nExBot runtime files are not revisioned")
requireMatch(bot, "settings%[index%]%.botRevision ~= BOT_REVISION", "updated bot code is not disabled for migration")
requireMatch(executor, 'entryPoint = "/bot/" %.%. config %.%. "/_Loader%.lua"',
    "executor does not load the bot from its absolute virtual path")
requireMatch(executor, 'file:gsub%("%^/%+", ""%)', "bot-relative dofile paths are not normalized")
requireAbsent(executor, "listDirectoryFiles", "executor still discovers arbitrary bot package files")
requireAbsent(ui, "id: config", "bot package selector is still visible")
requireAbsent(ui, "editConfig", "bot package editor is still visible")
requireAbsent(loader, "loadPrivateScripts", "nExBot still loads private scripts")
requireAbsent(loader, 'loadScript%("updater"', "nExBot still loads its upstream updater")
requireMatch(loader, 'if not OPTIONAL_MODULES%[name%] then', "required nExBot module failures are not fatal")
requireAbsent(loader, '"AttackBot"', "unvalidated TargetBot attack modules are loaded")

print("Xibat bot integration tests passed")
