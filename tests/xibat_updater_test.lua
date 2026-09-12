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

print('Desktop updater contract tests passed')
