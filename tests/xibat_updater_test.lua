local root = arg[1] or '.'

local function requireValue(condition, message)
  if not condition then error(message, 2) end
end

local signedPayload = {
  schema = 1,
  channel = 'stable',
  platform = 'windows-x64',
  sequence = 42,
  version = '0.2.0',
  revision = 'new-revision',
  archive_url = 'https://storage.googleapis.com/principal-346712-xibat-client-downloads/client/windows/0.2.0/revision/client.zip',
  archive_sha256 = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  archive_size = 1234,
  published_at = '2026-09-12T12:00:00Z'
}

local environment = {
  g_crypt = {
    verifyClientUpdateSignature = function(keyId, payload, signature)
      return keyId == 'xibat-client-2026-01' and payload == 'encoded-payload' and signature == 'valid-signature'
    end,
    base64Decode = function(payload)
      requireValue(payload == 'encoded-payload', 'unexpected payload passed to decoder')
      return 'decoded-payload'
    end
  },
  json = {
    decode = function(payload)
      requireValue(payload == 'decoded-payload', 'unexpected decoded payload')
      return signedPayload
    end
  }
}
setmetatable(environment, { __index = _G })

local chunk = assert(loadfile(root .. '/modules/updater/updater.lua'))
setfenv(chunk, environment)
chunk()

local envelope = {
  schema = 1,
  key_id = 'xibat-client-2026-01',
  payload = 'encoded-payload',
  signature = 'valid-signature'
}
local payload, validationError = environment.Updater.validateEnvelope(envelope)
requireValue(payload ~= nil and validationError == nil, 'valid signed update was rejected')
requireValue(environment.Updater.isUpdateAvailable(payload, { sequence = 41, revision = 'old-revision' }),
  'newer update was not selected')
requireValue(not environment.Updater.isUpdateAvailable(payload, { sequence = 42, revision = 'other-revision' }),
  'equal release sequence was accepted')
requireValue(not environment.Updater.isUpdateAvailable(payload, { sequence = 1, revision = 'new-revision' }),
  'same revision was accepted')

envelope.signature = 'tampered'
local invalid, signatureError = environment.Updater.validateEnvelope(envelope)
requireValue(invalid == nil and signatureError:find('signature', 1, true), 'invalid signature was accepted')

envelope.signature = 'valid-signature'
signedPayload.archive_url = 'https://example.com/client.zip'
local untrusted = environment.Updater.validateEnvelope(envelope)
requireValue(untrusted == nil, 'untrusted archive host was accepted')
signedPayload.archive_url = 'https://storage.googleapis.com/principal-346712-xibat-client-downloads/client/windows/0.2.0/revision/client.zip'

local function makeControl()
  local control = { visible = false }
  function control:show() self.visible = true end
  function control:hide() self.visible = false end
  function control:setText(text) self.text = text end
  function control:setPercent(percent) self.percent = percent end
  return control
end

local function makeRuntime(options)
  local state = { canceled = {}, downloads = {}, exited = 0, loaded = 0, signals = 0, checks = 0 }
  local window = {
    status = makeControl(),
    mainProgress = makeControl(),
    downloadStatus = makeControl(),
    downloadProgress = makeControl(),
    updateNowButton = makeControl(),
    exitButton = makeControl(),
    cancelButton = makeControl()
  }
  function window:show() self.visible = true end
  function window:raise() self.raised = true end
  function window:destroy() self.destroyed = true end

  local runtime = {
    Services = { updater = 'https://xibatd.online/api/client/updates/windows-x64' },
    g_crypt = environment.g_crypt,
    json = {
      decode = function(payload)
        if payload == 'installer-status' then return { status = 'rolled_back', error = options.installerError } end
        return environment.json.decode(payload)
      end
    },
    g_logger = { error = function() end, warning = function() end },
    g_app = {
      getOs = function() return options.os or 'windows' end,
      getBuildRevision = function() return options.revision or 'old-revision' end,
      getProcessId = function() return 123 end,
      exit = function() state.exited = state.exited + 1 end
    },
    g_resources = {
      fileExistsInWorkDir = function(path)
        if options.statusReadError then error(options.statusReadError) end
        return path == '.update/status.json' and options.installerError ~= nil
      end,
      readFileContentsFromWorkDir = function()
        if options.statusContents then return options.statusContents end
        return options.statusBom and '\239\187\191installer-status' or 'installer-status'
      end,
      writeFileContentsToWorkDir = function(path, contents)
        if options.statusWriteError then error(options.statusWriteError) end
        state.statusWrite = { path = path, contents = contents }
        if options.statusWrite == false then return false end
        options.installerError = nil
        return true
      end,
      writeDownloadedFileToWorkDir = function() return options.stage ~= false end,
      fileSha256InWorkDir = function() return signedPayload.archive_sha256 end,
      fileSizeInWorkDir = function() return signedPayload.archive_size end,
      extractDownloadedArchiveToWorkDir = function() return options.extract ~= false end,
      getWorkDir = function() return 'C:/Xibat/' end
    },
    g_platform = {
      spawnProcess = function() return options.spawn ~= false end,
      getProcessId = function() return 123 end
    },
    g_ui = { displayUI = function() return window end },
    HTTP = {},
    tr = function(text, ...)
      if select('#', ...) > 0 then return string.format(text, ...) end
      return text
    end,
    signalcall = function() state.signals = state.signals + 1 end,
    displayGeneralBox = function(title, message, buttons, onEnter, onEscape)
      local prompt = { title = title, message = message, buttons = buttons, onEnter = onEnter, onEscape = onEscape }
      function prompt:destroy() self.destroyed = true end
      state.prompt = prompt
      return prompt
    end
  }
  setmetatable(runtime, { __index = _G })

  function runtime.HTTP.cancel(id) table.insert(state.canceled, id) end
  function runtime.HTTP.getJSON(_, callback)
    if options.checkThrow then error(options.checkThrow) end
    state.checks = state.checks + 1
    local response = options.checks and options.checks[state.checks] or options.check
    if response and response.error then
      callback(nil, response.error)
    else
      callback(response and response.envelope or envelope, nil)
    end
    return state.checks
  end
  function runtime.HTTP.download(_, _, callback)
    if options.downloadThrow then error(options.downloadThrow) end
    table.insert(state.downloads, callback)
    return 100 + #state.downloads
  end

  local runtimeChunk = assert(loadfile(root .. '/modules/updater/updater.lua'))
  setfenv(runtimeChunk, runtime)
  runtimeChunk()
  runtime.Updater.init(function() state.loaded = state.loaded + 1 end)
  return runtime, state, window
end

local function requireRetryExit(state, context)
  requireValue(state.prompt ~= nil, context .. ' did not show an error prompt')
  requireValue(#state.prompt.buttons == 2, context .. ' did not offer exactly two actions')
  requireValue(state.prompt.buttons[1].text == 'Retry' and state.prompt.buttons[2].text == 'Exit',
    context .. ' did not offer Retry and Exit')
  requireValue(state.loaded == 0, context .. ' loaded normal client modules')
end

local _, nonWindows = makeRuntime({ os = 'linux' })
requireValue(nonWindows.loaded == 1 and nonWindows.checks == 0, 'non-Windows startup behavior changed')

local _, noUpdate = makeRuntime({ revision = 'new-revision' })
requireValue(noUpdate.loaded == 1 and noUpdate.signals == 1, 'no-update startup did not continue')

local _, checkFailure = makeRuntime({ checks = { { error = 'offline' }, { envelope = envelope } }, revision = 'new-revision' })
requireRetryExit(checkFailure, 'update check failure')
checkFailure.prompt.buttons[1].callback()
requireValue(checkFailure.loaded == 1 and checkFailure.checks == 2, 'check Retry did not recheck and continue on no update')

local _, synchronousCheckFailure = makeRuntime({ checkThrow = 'request setup failed' })
requireRetryExit(synchronousCheckFailure, 'synchronous update check failure')

local _, statusReadFailure = makeRuntime({ statusReadError = 'status permission denied' })
requireRetryExit(statusReadFailure, 'installer status read failure')
statusReadFailure.prompt.buttons[1].callback()
requireRetryExit(statusReadFailure, 'installer status read failure Retry')
requireValue(statusReadFailure.checks == 0, 'installer status read failure Retry bypassed the status gate')

local _, malformedStatus = makeRuntime({ installerError = 'rollback', statusContents = 'truncated' })
requireRetryExit(malformedStatus, 'malformed installer status')
malformedStatus.prompt.buttons[1].callback()
requireValue(malformedStatus.checks == 0, 'malformed installer status Retry bypassed the status gate')

local invalidEnvelope = { schema = 1, key_id = 'xibat-client-2026-01', payload = 'encoded-payload', signature = 'tampered' }
local _, validationFailure = makeRuntime({ check = { envelope = invalidEnvelope } })
requireRetryExit(validationFailure, 'metadata validation failure')
validationFailure.prompt.buttons[2].callback()
requireValue(validationFailure.exited == 1 and validationFailure.loaded == 0,
  'validation failure Exit did not terminate the blocked client')

local availableRuntime, available, availableWindow = makeRuntime({})
requireValue(available.loaded == 0, 'available mandatory update loaded normal client modules')
requireValue(availableWindow.updateNowButton.visible and availableWindow.exitButton.visible,
  'available update did not offer Update now and Exit')

availableRuntime.Updater.install()
requireValue(#available.downloads == 1 and availableWindow.cancelButton.visible, 'update download did not start')
availableRuntime.Updater.abort()
requireRetryExit(available, 'download cancellation')
available.downloads[1](nil, nil, nil)
requireValue(available.exited == 0, 'canceled download callback launched the installer')
available.prompt.buttons[1].callback()
requireValue(#available.downloads == 2, 'download cancellation Retry did not restart the download')

local downloadRuntime, downloadFailure = makeRuntime({})
downloadRuntime.Updater.install()
downloadFailure.downloads[1](nil, nil, 'download failed')
requireRetryExit(downloadFailure, 'download failure')

local installRuntime, installFailure = makeRuntime({ stage = false })
installRuntime.Updater.install()
installFailure.downloads[1](nil, nil, nil)
requireRetryExit(installFailure, 'install preparation failure')

local _, rollbackFailure = makeRuntime({ installerError = 'file replacement failed', statusBom = true })
requireRetryExit(rollbackFailure, 'rolled-back installer failure')
rollbackFailure.prompt.buttons[1].callback()
requireValue(rollbackFailure.checks == 1 and rollbackFailure.statusWrite.contents == '{"status":"acknowledged"}',
  'rolled-back installer Retry did not acknowledge the failure and recheck')

local _, acknowledgementFailure = makeRuntime({ installerError = 'rollback', statusWrite = false })
acknowledgementFailure.prompt.buttons[1].callback()
requireRetryExit(acknowledgementFailure, 'rollback acknowledgement failure')
acknowledgementFailure.prompt.buttons[1].callback()
requireRetryExit(acknowledgementFailure, 'rollback acknowledgement failure Retry')
requireValue(acknowledgementFailure.checks == 0, 'rollback acknowledgement failure Retry bypassed the status gate')

local synchronousDownloadRuntime, synchronousDownloadFailure = makeRuntime({ downloadThrow = 'download setup failed' })
synchronousDownloadRuntime.Updater.install()
requireRetryExit(synchronousDownloadFailure, 'synchronous download failure')

local successRuntime, success = makeRuntime({})
successRuntime.Updater.install()
success.downloads[1](nil, nil, nil)
requireValue(success.exited == 1 and success.loaded == 0, 'successful installer launch did not exit without loading modules')

local otuiFile = assert(io.open(root .. '/modules/updater/updater.otui', 'r'))
local otui = otuiFile:read('*a')
otuiFile:close()
requireValue(not otui:find("tr%('Later'%)"), 'updater UI still offers Later')

print('Desktop updater contract tests passed')
