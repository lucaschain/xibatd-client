-- Asset identity is independent of protocol/feature selection. Runtime files stay
-- in the OTC-standard directory; staging and recovery files are never loaded.
AssetRevision = {}
local names = { 'Tibia.dat', 'Tibia.spr' }

local function sha256(value)
  return type(value) == 'string' and #value == 64 and value:match('^[0-9a-f]+$')
end

function AssetRevision.validate(manifest, version)
  if type(manifest) ~= 'table' or manifest.schema ~= 1 or manifest.compatibilityVersion ~= version or
      version ~= 1098 or type(manifest.revision) ~= 'string' or #manifest.revision > 64 or
      not manifest.revision:match('^[0-9A-Za-z][0-9A-Za-z._-]*$') or
      type(manifest.archiveUrl) ~= 'string' or not manifest.archiveUrl:match('^https://') or
      not sha256(manifest.archiveSha256) or type(manifest.files) ~= 'table' then
    return false, 'Invalid asset revision manifest or incompatible client version.'
  end
  for _, name in ipairs(names) do
    local file = manifest.files[name]
    if type(file) ~= 'table' or not sha256(file.sha256) or type(file.size) ~= 'number' or
        file.size < 1 or file.size > 2147483647 or file.size ~= math.floor(file.size) then
      return false, 'Invalid asset metadata for ' .. name
    end
  end
  return true
end

-- io reads/writes the same physical install target on desktop and browser.
-- File mutations are synchronous; the owner fences asynchronous sync callbacks
-- between phases so cancellation cannot resume a later installation attempt.
function AssetRevision.new(io, version)
  local base = string.format('data/things/%d/', version)
  local stage = base .. '.asset-update/stage/'
  local backup = base .. '.asset-update/backup/'
  local marker = base .. '.asset-revision.json'
  local journal = base .. '.asset-update/pending.json'
  local self = { stage = stage }

  local function write(path, data)
    assert(io.write(path, data), 'Unable to write asset file: ' .. path)
  end

  local function clear(path)
    if io.remove then
      if io.exists(path) then assert(io.remove(path), 'Unable to remove asset file: ' .. path) end
    else
      write(path, '')
    end
  end

  local function cleanup()
    for _, name in ipairs(names) do
      clear(stage .. name)
      clear(backup .. name)
    end
  end

  local function copy(source, destination)
    if io.copy then
      assert(io.copy(source, destination), 'Unable to copy asset file: ' .. destination)
    else
      write(destination, io.read(source))
    end
  end

  local function matches(directory, manifest)
    for _, name in ipairs(names) do
      local metadata = manifest.files[name]
      if not io.exists(directory .. name) then return false, 'missing-file: ' .. name end
      if io.size(directory .. name) ~= metadata.size then return false, 'size-mismatch: ' .. name end
      if io.hash(directory .. name) ~= metadata.sha256 then return false, 'hash-mismatch: ' .. name end
    end
    return true
  end

  function self.current(manifest)
    local ok, result, reason = pcall(function()
      -- A pending transaction, including a malformed/torn journal, blocks loading.
      if io.exists(journal) and io.read(journal) ~= '' then return false, 'pending-journal' end
      if not io.exists(marker) then return false, 'missing-revision-marker' end
      local installed = io.decode(io.read(marker))
      if not AssetRevision.validate(installed, version) then return false, 'invalid-revision-marker' end
      if installed.revision ~= manifest.revision then return false, 'revision-mismatch' end
      if installed.archiveSha256 ~= manifest.archiveSha256 then return false, 'archive-mismatch' end
      return matches(base, manifest)
    end)
    if not ok then return false, 'metadata-read-error: ' .. tostring(result) end
    return result == true, reason
  end

  function self.filesMatch(manifest)
    assert(AssetRevision.validate(manifest, version))
    local ok, result, reason = pcall(matches, base, manifest)
    if not ok then return false, 'file-read-error: ' .. tostring(result) end
    return result, reason
  end

  function self.flush(callback)
    if io.sync then return io.sync(callback) end
    callback(true)
  end

  -- Each phase completes its durable sync before the next mutates anything.
  -- On sync failure retain recovery state; a retry can finish a hash-verified
  -- candidate without downloading or rolling it back unnecessarily.
  local function runPhases(phases, callback, operationFailed)
    callback = callback or function(ok, message) if not ok then error(message, 0) end end
    local function advance(index)
      if not phases[index] then return callback(true) end
      local ok, message = pcall(phases[index])
      if not ok then
        if operationFailed then return operationFailed(message, callback) end
        return callback(false, tostring(message))
      end
      self.flush(function(synced, syncError)
        if not synced then return callback(false, 'Unable to persist game assets: ' .. tostring(syncError)) end
        advance(index + 1)
      end)
    end
    advance(1)
  end

  function self.confirm(manifest, callback)
    assert(AssetRevision.validate(manifest, version))
    runPhases({
      function() assert(self.filesMatch(manifest), 'Cannot confirm mismatched DAT/SPR files.') end,
      function()
        write(marker, io.encode(manifest))
        -- Truncating a journal to zero bytes does not trigger IDBFS autoPersist.
        -- Removal does, and cannot be missed due to equal modification times.
        clear(journal)
      end,
      cleanup,
    }, callback)
  end

  function self.finishCached(callback)
    -- A previous attempt may have committed its marker but failed to persist
    -- temporary-file removal. Retry cleanup on cache hits too, without touching
    -- the verified live pair or requiring desktop workdir write permissions.
    runPhases({function()
      if io.remove then
        assert(not io.exists(journal) or io.read(journal) == '', 'Cannot clean a pending asset transaction.')
        clear(journal)
        cleanup()
      end
    end}, callback)
  end

  function self.recover()
    if not io.exists(journal) or io.read(journal) == '' then return end
    local pending = io.decode(io.read(journal))
    assert(type(pending) == 'table' and type(pending.previous) == 'table', 'Invalid asset recovery journal.')
    -- Restore only verified backups. Leave the journal in place on any failure;
    -- the next attempt retries recovery and cannot load a mixed pair.
    for _, name in ipairs(names) do
      local previous = pending.previous[name]
      if previous then
        assert(type(previous) == 'table' and sha256(previous.sha256) and
            io.hash(backup .. name) == previous.sha256 and io.size(backup .. name) == previous.size,
            'Asset recovery backup is incomplete: ' .. name)
      end
    end
    for _, name in ipairs(names) do
      if pending.previous[name] then copy(backup .. name, base .. name) end
    end
    for _, name in ipairs(names) do
      local previous = pending.previous[name]
      if previous then
        assert(io.size(base .. name) == previous.size and io.hash(base .. name) == previous.sha256,
            'Unable to verify restored asset: ' .. name)
      end
    end
    clear(marker) -- A recovered pair must be revalidated against the remote requirement.
    clear(journal)
  end

  function self.install(manifest, extract, callback)
    assert(AssetRevision.validate(manifest, version))
    local liveMutated = false
    runPhases({
      function()
        self.recover()
        for _, name in ipairs(names) do clear(stage .. name) end
        assert(extract(stage), 'Unable to extract asset archive into staging.')
        assert(matches(stage, manifest), 'Staged DAT/SPR size or SHA-256 mismatch.')
        local pending = { previous = {} }
        for _, name in ipairs(names) do
          if io.exists(base .. name) then
            copy(base .. name, backup .. name)
            pending.previous[name] = { size = io.size(base .. name), sha256 = io.hash(base .. name) }
            assert(io.hash(backup .. name) == pending.previous[name].sha256, 'Unable to verify asset backup.')
          end
        end
        write(journal, io.encode(pending))
      end,
      function()
        liveMutated = true
        for _, name in ipairs(names) do copy(stage .. name, base .. name) end
        assert(matches(base, manifest), 'Installed DAT/SPR size or SHA-256 mismatch.')
      end,
      function()
        write(marker, io.encode(manifest))
        clear(journal)
      end,
      cleanup,
    }, callback, function(err, done)
      if not liveMutated then return done(false, tostring(err)) end
      local recovered, recoveryError = pcall(self.recover)
      if not recovered then return done(false, tostring(err) .. '\nRecovery pending: ' .. tostring(recoveryError)) end
      self.flush(function(ok, syncError)
        done(false, tostring(err) .. (ok and '' or '\nRecovery persistence failed: ' .. tostring(syncError)))
      end)
    end)
  end

  return self
end
