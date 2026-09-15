local root = arg[1] or '.'
local expected = {}
-- Golden compatibility contract for Xiba's existing 1098 wire/asset formats.
for name in ([[
GameFormatCreatureName GameSpritesAlphaChannel GameDoubleSoul GameAllowPreWalk GameMapCache
GameSoul GameLevelU16 GameLooktypeU16 GameMessageStatements GameLoginPacketEncryption
GamePlayerAddons GamePlayerStamina GameNewFluids GameMessageLevel GamePlayerStateU16
GameNewOutfitProtocol GameWritableDate GameProtocolChecksum GameAccountNames
GameDoubleFreeCapacity GameChallengeOnLogin GameMessageSizeCheck GameTileAddThingWithStackpos
GameCreatureEmblems GameAttackSeq GamePenalityOnDeath GameDoubleExperience GamePlayerMounts
GameSpellList GameNameOnNpcTrade GameTotalCapacity GameSkillsBase GamePlayerRegenerationTime
GameChannelPlayerList GameEnvironmentEffect GameItemAnimationPhase GamePlayerMarket
GamePurseSlot GameClientPing GameSpritesU32 GameOfflineTrainingTime GameAdditionalVipInfo
GameDoublePlayerGoodsMoney GamePreviewState GameClientVersion GameLoginPending GameNewSpeedLaw
GameContainerPagination GameBrowseField GameThingMarks GamePVPMode GameDoubleSkills
GameBaseSkillU16 GameCreatureIcons GameHideNpcNames GamePremiumExpiration GameEnhancedAnimations
GameUnjustifiedPoints GameExperienceBonus GameDeathType GameIdleAnimations GameOGLInformation
GameContentRevision GameAuthenticator GameSessionKey GameIngameStore GameIngameStoreServiceType
GameIngameStoreHighlights GameAdditionalSkills GameLeechAmount
]]):gmatch('%S+') do expected[name] = true end

local features, onVersionChange = {}, nil
local env = {
  g_game = {
    enableFeature = function(feature) features[feature] = true end,
    disableFeature = function(feature) features[feature] = nil end,
  },
  Controller = { new = function()
    return { registerEvents = function(_, _, events) onVersionChange = events.onClientVersionChange end }
  end }
}
setmetatable(env, { __index = function(_, key)
  if key:match('^Game') then return key end
  return _G[key]
end })
local chunk = assert(loadfile(root .. '/modules/game_features/features.lua'))
setfenv(chunk, env)()
for _, revision in ipairs({ '2000', '2001', '10982' }) do
  env.Services = { clientAssets = { revision = revision } }
  features = {}
  onVersionChange(1098)
  for name in pairs(expected) do assert(features[name], 'Missing 1098 feature ' .. name) end
  for name in pairs(features) do assert(expected[name], 'Unexpected feature ' .. name) end
end
print('Xiba asset revisions preserve the complete 1098 feature set')
