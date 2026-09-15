-- Opt-in real HTTPS/extraction smoke. Run only from otclientrc.lua in a disposable
-- installation and profile: this deliberately invalidates its local asset marker.
local finished = false
local downloads = 0
local originalDownload = HTTP.download
local timeout

local function finish(ok, message)
  if finished then return end
  finished = true
  HTTP.download = originalDownload
  if timeout then removeEvent(timeout) end
  g_resources.writeFileContentsToWorkDir('asset-download-smoke-result.json', json.encode({
    status = ok and 'PASS' or 'FAIL', message = message, downloads = downloads
  }))
  scheduleEvent(function() g_app.exit() end, 100)
end

local function protected(fn)
  return function(...)
    if finished then return end
    local ok, err = pcall(fn, ...)
    if not ok then finish(false, tostring(err)) end
  end
end

timeout = scheduleEvent(function() finish(false, 'Asset download timed out') end, 600000)
scheduleEvent(protected(function()
  assert(not g_game.isOnline(), 'Smoke must run without a server connection')
  Services.clientAssets.enabled = true
  assert(g_resources.writeFileContentsToWorkDir('data/things/1098/.asset-revision.json', ''))
  HTTP.download = function(...)
    downloads = downloads + 1
    return originalDownload(...)
  end
  modules.client_assets.ensureClientVersion(1098, protected(function(ok, err, reloadRequired)
    assert(ok, err)
    assert(reloadRequired, 'Fresh installation did not request a reload')
    assert(downloads == 1, 'Outdated installation did not download exactly one archive')
    g_game.setClientVersion(0)
    g_game.setClientVersion(1098)
    g_game.setProtocolVersion(1098)
    assert(modules.game_things.isLoaded(), 'Downloaded DAT/SPR did not load')
    for _, flag in ipairs({ GameSpritesU32, GameSpritesAlphaChannel, GameEnhancedAnimations,
        GameIdleAnimations, GameDoubleSoul }) do
      assert(g_game.getFeature(flag), 'Missing compatibility flag: ' .. flag)
    end
    modules.client_assets.ensureClientVersion(1098, protected(function(current, checkError, changed)
      assert(current, checkError)
      assert(changed == false, 'Matching assets requested another reload')
      assert(downloads == 1, 'Matching revision was downloaded again')
      finish(true, 'HTTPS download, archive extraction, DAT/SPR reload and repeat revision check passed')
    end))
  end))
end), 1000)
