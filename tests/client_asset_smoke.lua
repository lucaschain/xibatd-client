-- Run from otclientrc.lua in an isolated installation/profile. No server login.
scheduleEvent(function()
  local ok, result = pcall(function()
    g_game.setClientVersion(0)
    g_game.setClientVersion(1098)
    g_game.setProtocolVersion(1098)
    assert(modules.game_things.isLoaded(), 'DAT/SPR did not load with 1098 flags')
    for _, feature in ipairs({ GameSpritesU32, GameSpritesAlphaChannel,
        GameEnhancedAnimations, GameIdleAnimations, GameDoubleSoul }) do
      assert(g_game.getFeature(feature), 'Missing Xiba compatibility feature ' .. feature)
    end
    assert(not g_game.getFeature(GamePrey), 'Unexpected modern protocol features')
    -- Optional prepared package: exercise the real Windows file APIs while the
    -- SPR is already loaded, then reload the installed pair at the same version.
    if g_resources.fileExists('/release/2000.json') then
      dofile('/modules/client_assets/asset_revision.lua')
      local manifest = json.decode(g_resources.readFileContents('/release/2000.json'))
      local store = AssetRevision.new({
        exists = g_resources.fileExistsInWorkDir,
        read = g_resources.readFileContentsFromWorkDir,
        write = g_resources.writeFileContentsToWorkDir,
        hash = g_resources.fileSha256InWorkDir,
        size = g_resources.fileSizeInWorkDir,
        encode = json.encode, decode = json.decode,
      }, 1098)
      store.install(manifest, function(stage)
        for _, name in ipairs({ 'Tibia.dat', 'Tibia.spr' }) do
          assert(g_resources.writeFileContentsToWorkDir(stage .. name,
              g_resources.readFileContentsFromWorkDir('data/things/1098/' .. name)))
        end
        return true
      end)
      assert(store.current(manifest), 'Native file activation failed')
      g_game.setClientVersion(0)
      g_game.setClientVersion(1098)
      assert(modules.game_things.isLoaded(), 'Reload after activation failed')
    end
    local types = g_things.getThingTypes(ThingCategoryItem)
    return { status = 'PASS', itemCount = #types, sprites = g_sprites.getSpritesCount(),
      datSignature = g_things.getDatSignature(), sprSignature = g_sprites.getSprSignature() }
  end)
  g_resources.writeFileContentsToWorkDir('asset-smoke-result.json',
      json.encode(ok and result or { status = 'FAIL', error = tostring(result) }))
  scheduleEvent(function() g_app.exit() end, 100)
end, 1000)
