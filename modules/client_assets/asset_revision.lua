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
-- All callbacks here are synchronous: no cancellation can interrupt activation.
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

  local function matches(directory, manifest)
    for _, name in ipairs(names) do
      local metadata = manifest.files[name]
      if io.size(directory .. name) ~= metadata.size or io.hash(directory .. name) ~= metadata.sha256 then
        return false
      end
    end
    return true
  end

  function self.current(manifest)
    local ok, result = pcall(function()
      -- A pending transaction, including a malformed/torn journal, blocks loading.
      if io.exists(journal) and io.read(journal) ~= '' then return false end
      if not io.exists(marker) then return false end
      local installed = io.decode(io.read(marker))
      return AssetRevision.validate(installed, version) and installed.revision == manifest.revision and
          installed.archiveSha256 == manifest.archiveSha256 and matches(base, manifest)
    end)
    return ok and result == true
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
      if pending.previous[name] then write(base .. name, io.read(backup .. name)) end
    end
    for _, name in ipairs(names) do
      local previous = pending.previous[name]
      if previous then
        assert(io.size(base .. name) == previous.size and io.hash(base .. name) == previous.sha256,
            'Unable to verify restored asset: ' .. name)
      end
    end
    write(marker, '') -- A recovered pair must be revalidated against the remote requirement.
    write(journal, '')
  end

  function self.install(manifest, extract)
    assert(AssetRevision.validate(manifest, version))
    self.recover()
    -- Clear previous staging contents so missing archive entries cannot be
    -- accidentally satisfied by an earlier extraction.
    for _, name in ipairs(names) do write(stage .. name, '') end
    assert(extract(stage), 'Unable to extract asset archive into staging.')
    assert(matches(stage, manifest), 'Staged DAT/SPR size or SHA-256 mismatch.')
    local pending = { previous = {} }
    for _, name in ipairs(names) do
      if io.exists(base .. name) then
        local contents = io.read(base .. name)
        write(backup .. name, contents)
        pending.previous[name] = { size = #contents, sha256 = io.hash(base .. name) }
        assert(io.hash(backup .. name) == pending.previous[name].sha256, 'Unable to verify asset backup.')
      end
    end
    -- Publish the journal before replacing either live file. On browser these
    -- writes live under /user (IDBFS autoPersist); recovery tolerates partial saves.
    write(journal, io.encode(pending))
    local ok, err = pcall(function()
      for _, name in ipairs(names) do write(base .. name, io.read(stage .. name)) end
      assert(matches(base, manifest), 'Installed DAT/SPR size or SHA-256 mismatch.')
      write(marker, io.encode(manifest))
      write(journal, '')
    end)
    if not ok then
      local recovered, recoveryError = pcall(self.recover)
      error(tostring(err) .. (recovered and '' or '\nRecovery pending: ' .. tostring(recoveryError)))
    end
    -- Retain only the active pair after successful activation. Interrupted cleanup
    -- is harmless: no runtime loader uses these temporary paths.
    for _, name in ipairs(names) do
      io.write(stage .. name, '')
      io.write(backup .. name, '')
    end
  end

  return self
end
