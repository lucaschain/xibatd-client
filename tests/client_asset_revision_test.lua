local root = arg[1] or '.'
dofile(root .. '/modules/corelib/json.lua')
dofile(root .. '/modules/client_assets/asset_revision.lua')

-- Synthetic hashes keep this ownership/recovery test independent of native crypto.
local function hash(data)
  if data == nil then return '' end
  local result = 0
  for i = 1, #data do result = (result * 31 + data:byte(i)) % 4294967296 end
  return string.format('%064x', result)
end
local pair = { ['Tibia.dat'] = 'new dat', ['Tibia.spr'] = 'new sprites' }
local manifest = {
  schema = 1, compatibilityVersion = 1098, revision = '2000',
  archiveUrl = 'https://example.test/assets.zip', archiveSha256 = hash('archive'), files = {}
}
for name, data in pairs(pair) do manifest.files[name] = { size = #data, sha256 = hash(data) } end
local base = 'data/things/1098/'
local marker = base .. '.asset-revision.json'
local journal = base .. '.asset-update/pending.json'

local function fixture()
  local files = { [base .. 'Tibia.dat'] = 'old dat', [base .. 'Tibia.spr'] = 'old spr' }
  local storage = {
    exists = function(path) return files[path] ~= nil end,
    read = function(path) return assert(files[path], 'Missing ' .. path) end,
    write = function(path, contents) files[path] = contents return true end,
    hash = function(path) return hash(files[path]) end,
    size = function(path) return files[path] and #files[path] or -1 end,
    encode = json.encode, decode = json.decode
  }
  local store = AssetRevision.new(storage, 1098)
  local function extract(stage)
    for name, data in pairs(pair) do files[stage .. name] = data end
    return true
  end
  return files, storage, store, extract
end

local files, storage, store, extract = fixture()
assert(not store.current(manifest), 'Presence-only legacy installation passed')
store.install(manifest, extract)
assert(store.current(manifest), 'Installed pair did not pass')
assert(files[base .. 'Tibia.dat'] == pair['Tibia.dat'])
assert(files[base .. 'Tibia.spr'] == pair['Tibia.spr'])
local nextManifest = json.decode(json.encode(manifest))
nextManifest.revision = '2001'
assert(not store.current(nextManifest), 'New revision accepted without installation')
files[base .. 'Tibia.spr'] = 'corrupt spr'
assert(not store.current(manifest), 'Corruption accepted with a matching marker')
files[base .. 'Tibia.spr'] = nil
assert(not store.current(manifest), 'Missing sprite accepted with a matching marker')

files, storage, store, extract = fixture()
assert(not pcall(store.install, manifest, function(stage)
  files[stage .. 'Tibia.dat'] = pair['Tibia.dat']
  return true
end), 'Incomplete archive accepted')
assert(files[base .. 'Tibia.dat'] == 'old dat' and files[base .. 'Tibia.spr'] == 'old spr')
assert(not files[journal], 'Activation started before stage verification')

-- Failed write restores the old pair and a fresh process can retry installation.
files, storage, store, extract = fixture()
local write = storage.write
local failed = false
storage.write = function(path, contents)
  if not failed and path == base .. 'Tibia.spr' and contents == pair['Tibia.spr'] then
    failed = true
    return false
  end
  return write(path, contents)
end
assert(not pcall(store.install, manifest, extract))
assert(files[base .. 'Tibia.dat'] == 'old dat' and files[base .. 'Tibia.spr'] == 'old spr')
assert(not store.current(manifest))
AssetRevision.new(storage, 1098).install(manifest, extract)
assert(store.current(manifest))

-- Interrupt after first live write; even failed rollback must leave the journal
-- and backups available for a new process to recover.
files, storage, store, extract = fixture()
write = storage.write
local interrupted = false
storage.write = function(path, contents)
  if path == base .. 'Tibia.spr' then interrupted = true end
  if interrupted then return false end
  return write(path, contents)
end
assert(not pcall(store.install, manifest, extract))
assert(files[journal] ~= '' and not store.current(manifest))
storage.write = write
local restarted = AssetRevision.new(storage, 1098)
restarted.recover()
assert(files[base .. 'Tibia.dat'] == 'old dat' and files[base .. 'Tibia.spr'] == 'old spr')
restarted.recover() -- terminal recovery is idempotent
restarted.install(manifest, extract)
assert(restarted.current(manifest))

-- Malformed local metadata cannot be mistaken for a completed installation.
files[journal] = '{torn'
assert(not restarted.current(manifest))
assert(not pcall(restarted.recover))
for _, field in ipairs({ 'revision', 'archiveSha256', 'compatibilityVersion', 'files' }) do
  local invalid = json.decode(json.encode(manifest))
  invalid[field] = false
  assert(not AssetRevision.validate(invalid, 1098), 'Invalid ' .. field .. ' accepted')
end
assert(not AssetRevision.validate(manifest, 2000), 'Asset revision treated as compatibility version')

-- Browser durability fixture: mutations are visible in memory immediately, but
-- survive a restart only after a successful asynchronous storage acknowledgment.
local function durableFixture()
  local memory, backend, owner, extractPair = fixture()
  local disk, syncs = {}, {}
  for path, contents in pairs(memory) do disk[path] = contents end
  backend.remove = function(path) memory[path] = nil return true end
  backend.sync = function(callback) syncs[#syncs + 1] = callback end
  local function sync(ok)
    local callback = assert(table.remove(syncs, 1), 'No pending storage sync')
    if ok then
      for path in pairs(disk) do disk[path] = nil end
      for path, contents in pairs(memory) do disk[path] = contents end
    end
    callback(ok, not ok and 'QuotaExceededError' or nil)
  end
  return memory, backend, owner, extractPair, disk, sync, syncs
end

local memory, backend, owner, extractPair, disk, sync, syncs = durableFixture()
local complete
owner.install(manifest, extractPair, function(ok, err) complete = {ok, err} end)
assert(not complete and memory[base .. 'Tibia.dat'] == 'old dat')
sync(true) -- staged pair, backup and pending journal become durable before replacement
assert(not complete and disk[base .. 'Tibia.dat'] == 'old dat' and disk[journal])
assert(memory[base .. 'Tibia.dat'] == pair['Tibia.dat'])
sync(true) -- live DAT/SPR become durable before the completion marker
assert(not complete and disk[base .. 'Tibia.dat'] == pair['Tibia.dat'] and disk[journal])
assert(memory[journal] == nil and memory[marker])
sync(true) -- marker and journal deletion are durable before removing backups
assert(not complete and disk[journal] == nil and disk[marker])
sync(true) -- cleanup is acknowledged before reporting success
assert(complete[1] and #syncs == 0 and disk[journal] == nil)
assert(disk[owner.stage .. 'Tibia.spr'] == nil, 'Temporary SPR remained in persistent storage')

-- Reproduce the deployed bug: saved DAT/SPR and marker are correct but an old
-- nonempty journal survived a zero-byte truncation. Roll forward without extraction.
memory[journal] = '{"previous":[]}'
local cached, reason = owner.current(manifest)
assert(not cached and reason == 'pending-journal')
assert(owner.filesMatch(manifest))
complete = nil
owner.confirm(manifest, function(ok, err) complete = {ok, err} end)
assert(not complete)
sync(true)
sync(true)
sync(true)
assert(complete[1] and disk[journal] == nil and owner.current(manifest))

-- A missing/invalid marker is repairable using hashes; corrupt bytes are not.
memory[marker] = nil
assert(owner.filesMatch(manifest))
local _, missingReason = owner.current(manifest)
assert(missingReason == 'missing-revision-marker')
owner.confirm(manifest, function(ok) assert(ok) end)
sync(true) sync(true) sync(true)
memory[base .. 'Tibia.spr'] = 'corrupt'
assert(not owner.filesMatch(manifest))
complete = nil
owner.confirm(manifest, function(ok, err) complete = {ok, err} end)
assert(not complete[1] and #syncs == 0)

-- Failure at any durable checkpoint cannot claim installation success.
for failedPhase = 1, 4 do
  memory, backend, owner, extractPair, disk, sync, syncs = durableFixture()
  complete = nil
  owner.install(manifest, extractPair, function(ok, err) complete = {ok, err} end)
  for phase = 1, failedPhase - 1 do sync(true) end
  sync(false)
  assert(complete and not complete[1] and complete[2]:find('QuotaExceededError', 1, true))
  assert(#syncs == 0, 'Failed storage sync advanced the installation')
  if failedPhase == 1 then
    assert(memory[base .. 'Tibia.dat'] == 'old dat' and not disk[marker])
  elseif failedPhase == 2 then
    assert(disk[journal] and not disk[marker])
  elseif failedPhase == 3 then
    assert(disk[journal] and disk[base .. 'Tibia.dat'] == pair['Tibia.dat'])
  elseif failedPhase == 4 then
    -- Reopen the persisted state after cleanup failed. The marker is current,
    -- but disk still contains staging/backups; a cache hit must finish removal.
    for path in pairs(memory) do memory[path] = nil end
    for path, contents in pairs(disk) do memory[path] = contents end
    assert(owner.current(manifest) and memory[owner.stage .. 'Tibia.spr'])
    complete = nil
    owner.finishCached(function(ok, err) complete = {ok, err} end)
    assert(not complete)
    sync(true)
    assert(complete[1] and disk[owner.stage .. 'Tibia.spr'] == nil)
    assert(disk[base .. '.asset-update/backup/Tibia.spr'] == nil)
  end
end

print('Asset revision integrity and recovery tests passed')
