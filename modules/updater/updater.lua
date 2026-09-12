Updater = {}

Updater.maxRetries = 3
Updater.maxArchiveSize = 256 * 1024 * 1024

local updaterWindow
local loadModulesFunction
local httpOperationId = 0
local retries = 0
local pendingPayload

local function closeWindow()
  if updaterWindow then
    updaterWindow:destroy()
    updaterWindow = nil
  end
end

local function loadModules()
  if loadModulesFunction then
    local callback = loadModulesFunction
    loadModulesFunction = nil
    callback()
  end
end

local function finishWithoutUpdate()
  HTTP.cancel(httpOperationId)
  closeWindow()
  loadModules()
  signalcall(g_app.onUpdateFinished, g_app)
end

local function fail(message)
  g_logger.error('Desktop update failed: ' .. tostring(message))
  closeWindow()
  displayErrorBox(tr('Updater Error'), tr('The update could not be installed. The current client will continue.\n\n%s', tostring(message))).onOk = function()
    loadModules()
    signalcall(g_app.onUpdateFinished, g_app)
  end
end

local function readLocalRelease()
  if not g_resources.fileExistsInWorkDir('update-release.json') then
    return { sequence = 0, revision = g_app.getBuildRevision() }
  end
  local ok, release = pcall(json.decode, g_resources.readFileContentsFromWorkDir('update-release.json'))
  if not ok or type(release) ~= 'table' then
    return { sequence = 0, revision = g_app.getBuildRevision() }
  end
  return release
end

function Updater.validateEnvelope(envelope)
  if type(envelope) ~= 'table' or envelope.schema ~= 1 or type(envelope.key_id) ~= 'string' or
      type(envelope.payload) ~= 'string' or type(envelope.signature) ~= 'string' then
    return nil, 'Invalid update envelope.'
  end
  if not g_crypt.verifyClientUpdateSignature(envelope.key_id, envelope.payload, envelope.signature) then
    return nil, 'The update signature is invalid.'
  end

  local payloadBytes = g_crypt.base64Decode(envelope.payload)
  local ok, payload = pcall(json.decode, payloadBytes)
  if not ok or type(payload) ~= 'table' then
    return nil, 'The signed update payload is invalid.'
  end
  if payload.schema ~= 1 or payload.channel ~= 'stable' or payload.platform ~= 'windows-x64' then
    return nil, 'The update is for an unsupported channel or platform.'
  end
  if type(payload.sequence) ~= 'number' or payload.sequence < 1 or payload.sequence % 1 ~= 0 or
      type(payload.version) ~= 'string' or payload.version == '' or
      type(payload.revision) ~= 'string' or payload.revision == '' or
      type(payload.archive_url) ~= 'string' or
      not payload.archive_url:match('^https://storage%.googleapis%.com/principal%-346712%-xibat%-client%-downloads/client/windows/') or
      type(payload.archive_sha256) ~= 'string' or not payload.archive_sha256:match('^[0-9a-f]+$') or
      #payload.archive_sha256 ~= 64 or type(payload.archive_size) ~= 'number' or
      payload.archive_size < 1 or payload.archive_size > Updater.maxArchiveSize then
    return nil, 'The signed update metadata is invalid.'
  end
  return payload
end

function Updater.isUpdateAvailable(payload, localRelease)
  if payload.revision == localRelease.revision then
    return false
  end
  local localSequence = tonumber(localRelease.sequence) or 0
  return payload.sequence > localSequence
end

local function launchInstaller(payload, downloadName)
  updaterWindow.status:setText(tr('Preparing update'))
  if not g_resources.writeDownloadedFileToWorkDir(downloadName, '.update/package.zip', false) then
    return fail('Unable to stage the downloaded package.')
  end
  if g_resources.fileSha256InWorkDir('.update/package.zip') ~= payload.archive_sha256 then
    return fail('The downloaded package checksum is invalid.')
  end
  if g_resources.fileSizeInWorkDir('.update/package.zip') ~= payload.archive_size then
    return fail('The downloaded package size is invalid.')
  end

  local stageRelative = '.update/stage-' .. tostring(payload.sequence)
  if not g_resources.extractDownloadedArchiveToWorkDir(downloadName, stageRelative, 'xibatd-client', true) then
    return fail('Unable to extract the downloaded package.')
  end

  local workDir = g_resources.getWorkDir()
  local stage = workDir .. stageRelative
  local script = stage .. '/updater/install-update.ps1'
  local started = g_platform.spawnProcess('powershell', {
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', script,
    '-ProcessId', tostring(g_platform.getProcessId()),
    '-InstallDir', workDir,
    '-StageDir', stage
  })
  if not started then
    return fail('Unable to start the Windows update installer.')
  end

  updaterWindow.status:setText(tr('Restarting into version %s', payload.version))
  g_app.exit()
end

local function downloadUpdate()
  local payload = pendingPayload
  if not payload or not updaterWindow then return end

  retries = retries + 1
  updaterWindow.updateNowButton:hide()
  updaterWindow.laterButton:hide()
  updaterWindow.cancelButton:show()
  updaterWindow.downloadProgress:show()
  updaterWindow.downloadStatus:show()
  updaterWindow.status:setText(tr('Downloading version %s', payload.version))

  local downloadName = 'client-update-' .. tostring(payload.sequence) .. '.zip'
  httpOperationId = HTTP.download(payload.archive_url, downloadName, function(_, _, err)
    if err then
      if retries < Updater.maxRetries then
        return scheduleEvent(downloadUpdate, 500)
      end
      return fail(err)
    end
    launchInstaller(payload, downloadName)
  end, function(progress, speed)
    if not updaterWindow then return end
    updaterWindow.downloadProgress:setPercent(progress)
    updaterWindow.downloadProgress:setText(speed .. ' kbps')
  end)
end

local function offerUpdate(payload)
  pendingPayload = payload
  updaterWindow.status:setText(tr('Version %s is ready to install.', payload.version))
  updaterWindow.mainProgress:setPercent(100)
  updaterWindow.updateNowButton:show()
  updaterWindow.laterButton:show()
  updaterWindow.cancelButton:hide()
end

function Updater.init(loadModulesFunc)
  loadModulesFunction = loadModulesFunc
  if g_app.getOs() ~= 'windows' then
    return finishWithoutUpdate()
  end

  updaterWindow = g_ui.displayUI('updater')
  updaterWindow:show()
  updaterWindow:raise()
  httpOperationId = HTTP.getJSON(Services.updater, function(envelope, err)
    if err then
      g_logger.warning('Desktop update check unavailable: ' .. tostring(err))
      return finishWithoutUpdate()
    end
    local payload, validationError = Updater.validateEnvelope(envelope)
    if not payload then
      return fail(validationError)
    end
    if not Updater.isUpdateAvailable(payload, readLocalRelease()) then
      return finishWithoutUpdate()
    end
    offerUpdate(payload)
  end)
end

function Updater.terminate()
  HTTP.cancel(httpOperationId)
  closeWindow()
  loadModulesFunction = nil
end

function Updater.abort()
  finishWithoutUpdate()
end

function Updater.install()
  downloadUpdate()
end
