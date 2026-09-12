-- Cavebot by otclient@otclient.ovh
-- visit the documentation on GitHub
-- https://www.nexbot.cc/docs/cavebot

local cavebotTab = "Cave"
local targetingTab = storage.extras.joinBot and "Cave" or "Target"

setDefaultTab(cavebotTab)
CaveBot.Extensions = {}

local function safeDofile(path)
	local ok, res = pcall(function() return dofile(path) end)
	if ok then
		return res
	else
		warn("[CaveBot] Failed to load " .. path .. ": " .. tostring(res))
	end
	return res
end

-- Essential UI and core modules (load immediately)
importStyle("/cavebot/cavebot.otui")
importStyle("/cavebot/config.otui")
importStyle("/cavebot/editor.otui")
safeDofile("/cavebot/actions.lua")
safeDofile("/cavebot/config.lua")
safeDofile("/cavebot/example_functions.lua")
safeDofile("/cavebot/editor.lua")
safeDofile("/cavebot/recorder.lua")
safeDofile("/cavebot/tools.lua")
safeDofile("/cavebot/walking.lua")

safeDofile("/cavebot/minimap.lua")

-- Defer auxiliary modules to reduce startup cost; cavebot.lua must be last (depends on all above)
local deferredModules = {
	"/cavebot/cavebot.lua" -- Must remain last (depends on walking.lua, recorder.lua, etc.)
}

local function loadDeferred(idx)
	idx = idx or 1
	if idx > #deferredModules then return end
	setDefaultTab(cavebotTab)
		safeDofile(deferredModules[idx])
	schedule(20, function() loadDeferred(idx + 1) end)
end

loadDeferred()

TargetBot = {}
setDefaultTab("Main")
