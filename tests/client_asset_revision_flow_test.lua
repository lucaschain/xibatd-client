local root = arg[1] or '.'
dofile(root .. '/modules/corelib/json.lua')
local function hash(data)
  local n = 0
  for i = 1, #data do n = (n * 31 + data:byte(i)) % 4294967296 end
  return string.format('%064x', n)
end
local manifest = { schema = 1, compatibilityVersion = 1098, revision = '2000',
  archiveUrl = 'https://example.test/assets.zip', archiveSha256 = hash('archive'), files = {} }
local pair = { ['Tibia.dat'] = 'new dat', ['Tibia.spr'] = 'new spr' }
for name, data in pairs(pair) do manifest.files[name] = { size = #data, sha256 = hash(data) } end
local base = 'data/things/1098/'

local function fixture(browser)
  local files, requests, events, results = {}, {}, {}, {}
  local fakeWidget
  fakeWidget = function()
    return setmetatable({ content = {}, progressFill = {} }, { __index = function(_, key)
      if key == 'holder' then return nil end
      if key == 'getWidth' then return function() return 360 end end
      if key == 'getChildById' then return function() return nil end end
      return function() end
    end })
  end
  local window
  local env
  local function drainStorageSyncs()
    if env.pauseStorageSyncs then return end
    for _, event in ipairs(events) do
      if event.delay == 0 and not event.removed then event.removed = true event.fn() end
    end
  end
  local function resourcePath(path) return path:gsub('^/', '') end
  local function request(kind, url, callback)
    requests[#requests + 1] = { kind = kind, url = url, callback = function(...)
      local data, err = ...
      if kind == 'manifest' and type(data) == 'table' then
        callback(json.decode(json.encode(data)), err)
      else
        callback(...)
      end
      drainStorageSyncs()
    end }
    return #requests
  end
  env = {
    io = { open = function(path, mode)
      local key = resourcePath(path)
      local data = files[key]
      if mode == 'wb' then files[key] = '' elseif not data then return nil end
      local cursor = 1
      return {
        seek = function(_, where) assert(where == 'end') return #data end,
        read = function(_, size)
          assert(size <= 64 * 1024, 'Browser file copies must use bounded chunks')
          if cursor > #data then return nil end
          local chunk = data:sub(cursor, cursor + size - 1)
          cursor = cursor + #chunk
          return chunk
        end,
        write = function(_, chunk) files[key] = files[key] .. chunk return true end,
        close = function() return true end
      }
    end },
    json = json, Services = { clientAssets = { repository = false, installInWorkDir = not browser,
      revisionManifestUrl = 'https://example.test/current.json' } },
    tr = function(s) return s end,
    g_logger = { info = function() end, warning = function() end, error = function() end },
    g_game = { isOnline = function() return false end },
    g_sprites = { isLoaded = function() return false end },
    g_platform = { isBrowser = function() return browser end },
    g_app = { exit = function() error('Unexpected browser reload') end },
    g_clock = { millis = function() return 1 end },
    g_crypt = { sha256 = hash },
    g_ui = { createWidget = fakeWidget },
    displayCancelBox = function()
      window = fakeWidget()
      window.content = fakeWidget()
      return window
    end,
    connect = function(target, callbacks) target.callbacks = callbacks end,
    disconnect = function(target) target.callbacks = nil end,
    scheduleEvent = function(fn, delay) events[#events + 1] = {fn = fn, delay = delay} return #events end,
    removeEvent = function(id) if events[id] then events[id].removed = true end end,
    HTTP = { timeout = 30, cancel = function() end,
      getJSON = function(url, cb) return request('manifest', url, cb) end,
      download = function(url, path, cb) return request('archive', url, cb) end },
    g_resources = {
      getWorkDir = function() return browser and '/user' or 'D:/Test' end,
      getRealPath = function(path) return path end,
      makeDir = function() return true end,
      fileExists = function(path) return files[resourcePath(path)] ~= nil end,
      readFileContents = function(path) return assert(files[resourcePath(path)], path) end,
      writeFileContents = function(path, data) files[resourcePath(path)] = data return true end,
      deleteFile = function(path) files[resourcePath(path)] = nil return true end,
      fileSha256 = function(path) return files[resourcePath(path)] and hash(files[resourcePath(path)]) or '' end,
    }
  }
  local resources = env.g_resources
  local syncId = 0
  resources.requestWritableStorageSync = function()
    syncId = syncId + 1
    local id = syncId
    env.scheduleEvent(function()
      if resources.callbacks and resources.callbacks.onWritableStorageSync then
        resources.callbacks.onWritableStorageSync(id, env.storageError or '')
      end
    end, 0)
    return id
  end
  resources.fileExistsInWorkDir = resources.fileExists
  resources.readFileContentsFromWorkDir = resources.readFileContents
  resources.writeFileContentsToWorkDir = resources.writeFileContents
  resources.fileSha256InWorkDir = resources.fileSha256
  resources.fileSizeInWorkDir = function(path) return files[path] and #files[path] or -1 end
  local function extract(_, stage)
    for name, data in pairs(pair) do files[stage .. name] = data end
    return true
  end
  resources.extractDownloadedArchive = extract
  resources.extractDownloadedArchiveToWorkDir = extract
  setmetatable(env, { __index = _G })
  for _, name in ipairs({ 'asset_revision', 'client_assets' }) do
    local chunk = assert(loadfile(root .. '/modules/client_assets/' .. name .. '.lua'))
    setfenv(chunk, env)()
  end
  local function ensure()
    env.ensureClientVersion(1098, function(ok, message, reloadRequired)
      results[#results + 1] = {ok, message, reloadRequired}
    end)
  end
  local function install()
    requests[#requests].callback(manifest)
    assert(requests[#requests].kind == 'archive')
    files['downloads/archive.zip'] = 'archive'
    requests[#requests].callback('archive.zip', nil, nil)
    for _, event in ipairs(events) do
      if event.delay == 50 and not event.removed then
        event.removed = true
        event.fn()
        drainStorageSyncs()
      end
    end
  end
  return env, files, requests, results, ensure, install, function() window.callbacks.onCancel() end, events
end

for _, browser in ipairs({ false, true }) do
  local env, files, requests, results, ensure, install, cancel, events = fixture(browser)
  files[base .. 'Tibia.dat'], files[base .. 'Tibia.spr'] = 'old dat', 'old spr'
  ensure()
  assert(#requests == 1 and requests[1].kind == 'manifest', 'Existing files bypassed remote check')
  install()
  assert(results[1][1] and env.isClientVersionInstalled(1098))
  assert(results[1][3] == true, 'Fresh assets did not request a reload')
  assert(files[base .. 'Tibia.dat'] == pair['Tibia.dat'] and files[base .. 'Tibia.spr'] == pair['Tibia.spr'])
  if browser then
    local originalRead = env.g_resources.readFileContents
    env.g_resources.readFileContents = function(path)
      assert(not path:match('Tibia%.spr$'), 'Browser metadata check copied the entire loaded SPR into Lua')
      return originalRead(path)
    end
  end
  ensure()
  assert(requests[#requests].kind == 'manifest', 'Second login skipped current requirement')
  local count = #requests
  requests[count].callback(manifest)
  assert(#requests == count and results[2][1], 'Matching revision downloaded again')
  assert(results[2][3] == false, 'Matching revision requested a redundant reload')
  -- Later repair/update scenarios intentionally copy file contents during install.
  env.g_resources.readFileContents = env.g_resources.readFileContentsFromWorkDir
  ensure()
  requests[#requests].callback(nil, 'offline')
  assert(not results[3][1] and not env.isClientVersionInstalled(1098), 'Offline requirement check failed open')
  ensure()
  local stale = requests[#requests].callback
  cancel()
  assert(not results[4][1])
  ensure()
  count = #requests
  stale(manifest)
  assert(#requests == count and #results == 4, 'Canceled callback affected the new operation')
  requests[#requests].callback(manifest)
  assert(results[5][1])
  files[base .. 'Tibia.spr'] = 'corruption'
  ensure()
  install()
  assert(results[6][1] and files[base .. 'Tibia.spr'] == pair['Tibia.spr'])
  assert(results[6][3] == true, 'Repaired assets did not request a reload')
  ensure()
  requests[#requests].callback(manifest)
  assert(results[7][1])
  files[base .. 'Tibia.dat'] = nil
  ensure()
  requests[#requests].callback(manifest)
  files['downloads/bad.zip'] = 'bad archive'
  requests[#requests].callback('bad.zip', nil, nil)
  assert(not results[8][1] and files[base .. 'Tibia.dat'] == nil, 'Bad archive touched live assets')
  ensure()
  requests[#requests].callback(manifest)
  local canceledDownload = requests[#requests].callback
  cancel()
  ensure()
  local before = #requests
  canceledDownload('archive.zip', nil, nil)
  assert(#requests == before and #results == 9, 'Canceled archive callback affected a new check')
  install()
  assert(results[10][1])
  manifest.revision = '2001'
  ensure()
  requests[#requests].callback(manifest)
  assert(results[11][1] and results[11][3], 'New revision with identical files was not adopted')
  manifest.revision = '2000'
  -- A rollback is explicit pointer promotion too; equality, not numeric ordering.
  ensure()
  requests[#requests].callback(manifest)
  assert(results[12][1])
  ensure()
  local afterUnload = requests[#requests].callback
  env.terminate()
  before = #requests
  afterUnload(manifest)
  assert(#requests == before and #results == 12, 'Module unload left a live callback')
  if browser then
    local reloads = 0
    env.g_sprites.isLoaded = function() return true end
    env.g_app.exit = function() reloads = reloads + 1 end
    files[base .. 'Tibia.dat'] = 'outdated'
    ensure()
    before = #requests
    requests[#requests].callback(manifest)
    assert(reloads == 1 and #requests == before and #results == 12,
        'A browser update tried to extract alongside the cached SPR or resumed stale login')
  end
end

-- A reopened browser may retain the old pending journal despite having a fully
-- valid pair. Repair and persist the metadata without a single ZIP request.
do
  local env, files, requests, results, ensure = fixture(true)
  for name, contents in pairs(pair) do files[base .. name] = contents end
  files[base .. '.asset-update/pending.json'] = '{"previous":[]}'
  ensure()
  requests[1].callback(manifest)
  assert(#requests == 1 and results[1][1])
  assert(files[base .. '.asset-update/pending.json'] == nil)
  assert(json.decode(files[base .. '.asset-revision.json']).revision == manifest.revision)
  files[base .. '.asset-update/backup/Tibia.spr'] = 'orphaned backup'
  ensure()
  requests[#requests].callback(manifest)
  assert(#requests == 2 and results[2][1] and results[2][3] == false)
  assert(files[base .. '.asset-update/backup/Tibia.spr'] == nil,
      'A verified cache hit retained an orphaned backup')
end

do
  local env, files, requests, results, ensure, _, cancel, events = fixture(true)
  env.storageError = 'QuotaExceededError'
  ensure()
  requests[1].callback(manifest)
  assert(#requests == 1 and not results[1][1] and next(files) == nil,
      'Unavailable storage allowed download or installation')
  env.storageError = nil
  env.pauseStorageSyncs = true
  ensure()
  requests[#requests].callback(manifest)
  assert(#results == 1, 'A pending durability acknowledgment reported completion')
  cancel()
  assert(#results == 2 and not results[2][1])
  env.pauseStorageSyncs = false
  for name, contents in pairs(pair) do files[base .. name] = contents end
  ensure()
  requests[#requests].callback(manifest)
  assert(#results == 3 and results[3][1], 'A stale sync result resumed the canceled operation')
  env.pauseStorageSyncs = true
  ensure()
  requests[#requests].callback(manifest)
  for _, event in ipairs(events) do
    if event.delay == 120000 and not event.removed then
      event.removed = true
      event.fn()
      break
    end
  end
  assert(#results == 4 and not results[4][1] and results[4][2]:find('timed out', 1, true))
end
print('Desktop/browser asset revision login flow tests passed')
