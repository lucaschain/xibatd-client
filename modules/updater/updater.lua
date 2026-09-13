Updater = {}

Updater.maxArchiveSize = 256 * 1024 * 1024

local updaterWindow
local loadModulesFunction
local httpOperationId = 0
local pendingPayload
local errorWindow
local checkForUpdate
local checkGeneration = 0
local downloadGeneration = 0

local function closeWindow()
  if updaterWindow then
    updaterWindow:destroy()
    updaterWindow = nil
  end
end

local function closeErrorWindow()
  if errorWindow then
    errorWindow:destroy()
    errorWindow = nil
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

local function exitClient()
  checkGeneration = checkGeneration + 1
  downloadGeneration = downloadGeneration + 1
  HTTP.cancel(httpOperationId)
  closeErrorWindow()
  closeWindow()
  g_app.exit()
end

local function fail(message, retryCallback)
  g_logger.error('Desktop update failed: ' .. tostring(message))
  HTTP.cancel(httpOperationId)
  closeErrorWindow()

  local function retry()
    closeErrorWindow()
    retryCallback()
  end
  errorWindow = displayGeneralBox(tr('Updater Error'),
    tr('The client cannot continue until the update succeeds.\n\n%s', tostring(message)), {
      { text = tr('Retry'), callback = retry },
      { text = tr('Exit'), callback = exitClient }
    }, retry, exitClient)
end

local function readLocalRelease()
  local ok, release = pcall(function()
    if not g_resources.fileExistsInWorkDir('update-release.json') then
      return { sequence = 0, revision = g_app.getBuildRevision() }
    end
    return json.decode(g_resources.readFileContentsFromWorkDir('update-release.json'))
  end)
  if not ok then return nil, 'Unable to read the installed release metadata: ' .. tostring(release) end
  if type(release) ~= 'table' then
    return { sequence = 0, revision = g_app.getBuildRevision() }
  end
  return release
end

local function readInstallerFailure()
  local ok, contents = pcall(function()
    if not g_resources.fileExistsInWorkDir('.update/status.json') then return nil end
    return g_resources.readFileContentsFromWorkDir('.update/status.json')
  end)
  if not ok then return nil, 'Unable to read the previous update status: ' .. tostring(contents) end
  if not contents then return nil end

  contents = contents:gsub('^\239\187\191', '')
  local decoded, status = pcall(json.decode, contents)
  if not decoded or type(status) ~= 'table' or type(status.status) ~= 'string' then
    return nil, 'The previous update status is invalid.'
  end
  if status.status == 'rolled_back' then
    return tostring(status.error or 'The previous update was rolled back.')
  end
  if status.status == 'installed' or status.status == 'acknowledged' then return nil end
  return nil, 'The previous update status is invalid.'
end

function Updater.validateEnvelope(envelope)
  if type(envelope) ~= 'table' or envelope.schema ~= 1 or type(envelope.key_id) ~= 'string' or
      type(envelope.payload) ~= 'string' or type(envelope.signature) ~= 'string' then
    return nil, 'Invalid update envelope.'
  end
  if not g_crypt.verifyClientUpdateSignature(envelope.key_id, envelope.payload, envelope.signature) then
    return nil, 'The update signature is invalid.'
  end

  local ok, payload = pcall(function()
    return json.decode(g_crypt.base64Decode(envelope.payload))
  end)
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
    return fail('Unable to stage the downloaded package.', Updater.install)
  end
  if g_resources.fileSha256InWorkDir('.update/package.zip') ~= payload.archive_sha256 then
    return fail('The downloaded package checksum is invalid.', Updater.install)
  end
  if g_resources.fileSizeInWorkDir('.update/package.zip') ~= payload.archive_size then
    return fail('The downloaded package size is invalid.', Updater.install)
  end

  local stageRelative = '.update/stage-' .. tostring(payload.sequence)
  if not g_resources.extractDownloadedArchiveToWorkDir(downloadName, stageRelative, 'xibatd-client', true) then
    return fail('Unable to extract the downloaded package.', Updater.install)
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
    return fail('Unable to start the Windows update installer.', Updater.install)
  end

  updaterWindow.status:setText(tr('Restarting into version %s', payload.version))
  g_app.exit()
end

local function downloadUpdate(generation)
  local payload = pendingPayload
  if generation ~= downloadGeneration or not payload or not updaterWindow then return end

  updaterWindow.updateNowButton:hide()
  updaterWindow.exitButton:hide()
  updaterWindow.cancelButton:show()
  updaterWindow.downloadProgress:show()
  updaterWindow.downloadStatus:show()
  updaterWindow.status:setText(tr('Downloading version %s', payload.version))

  local downloadName = 'client-update-' .. tostring(payload.sequence) .. '.zip'
  local started, operationId = pcall(HTTP.download, payload.archive_url, downloadName, function(_, _, err)
    if generation ~= downloadGeneration then return end
    if err then
      return fail(err, Updater.install)
    end
    launchInstaller(payload, downloadName)
  end, function(progress, speed)
    if not updaterWindow then return end
    updaterWindow.downloadProgress:setPercent(progress)
    updaterWindow.downloadProgress:setText(speed .. ' kbps')
  end)
  if not started then return fail(operationId, Updater.install) end
  httpOperationId = operationId
end

local function offerUpdate(payload)
  pendingPayload = payload
  updaterWindow.status:setText(tr('Version %s is ready to install.', payload.version))
  updaterWindow.mainProgress:setPercent(100)
  updaterWindow.updateNowButton:show()
  updaterWindow.exitButton:show()
  updaterWindow.cancelButton:hide()
end

checkForUpdate = function()
  checkGeneration = checkGeneration + 1
  local generation = checkGeneration
  closeErrorWindow()
  pendingPayload = nil
  updaterWindow.updateNowButton:hide()
  updaterWindow.exitButton:hide()
  updaterWindow.cancelButton:hide()
  updaterWindow.downloadProgress:hide()
  updaterWindow.downloadStatus:hide()
  updaterWindow.mainProgress:setPercent(0)
  updaterWindow.status:setText(tr('Checking for updates'))

  local started, operationId = pcall(HTTP.getJSON, Services.updater, function(envelope, err)
    if generation ~= checkGeneration then return end
    if err then
      g_logger.warning('Desktop update check unavailable: ' .. tostring(err))
      return fail(err, checkForUpdate)
    end
    local payload, validationError = Updater.validateEnvelope(envelope)
    if not payload then
      return fail(validationError, checkForUpdate)
    end
    local localRelease, localReleaseError = readLocalRelease()
    if not localRelease then return fail(localReleaseError, checkForUpdate) end
    if not Updater.isUpdateAvailable(payload, localRelease) then
      return finishWithoutUpdate()
    end
    offerUpdate(payload)
  end)
  if not started then return fail(operationId, checkForUpdate) end
  httpOperationId = operationId
end

local function checkInstallerStatus()
  local installerError, installerStatusError = readInstallerFailure()
  if installerStatusError then return fail(installerStatusError, checkInstallerStatus) end
  if installerError then
    local function acknowledgeFailure()
      local ok, written = pcall(g_resources.writeFileContentsToWorkDir, '.update/status.json',
        '{"status":"acknowledged"}')
      if not ok or not written then
        return fail('Unable to acknowledge the previous update failure.', acknowledgeFailure)
      end
      checkForUpdate()
    end
    return fail('The previous update installation failed and was rolled back.\n\n' .. installerError,
      acknowledgeFailure)
  end
  checkForUpdate()
end

function Updater.init(loadModulesFunc)
  loadModulesFunction = loadModulesFunc
  if g_app.getOs() ~= 'windows' then
    return finishWithoutUpdate()
  end

  updaterWindow = g_ui.displayUI('updater')
  updaterWindow:show()
  updaterWindow:raise()
  checkInstallerStatus()
end

function Updater.terminate()
  checkGeneration = checkGeneration + 1
  downloadGeneration = downloadGeneration + 1
  HTTP.cancel(httpOperationId)
  closeErrorWindow()
  closeWindow()
  loadModulesFunction = nil
end

function Updater.abort()
  downloadGeneration = downloadGeneration + 1
  fail('The update download was canceled.', Updater.install)
end

function Updater.install()
  closeErrorWindow()
  downloadGeneration = downloadGeneration + 1
  downloadUpdate(downloadGeneration)
end

function Updater.exit()
  exitClient()
end
