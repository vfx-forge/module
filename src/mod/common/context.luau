local common = {}

-- studio's edit session, where a plugin holds the authority a server holds at
-- runtime. an idle studio session counts even without a plugin ancestor, so a
-- story or the command bar resolves an effect the same way the plugin does
function common.pluginContext(inPlugin: boolean, isStudio: boolean, isRunning: boolean)
  return inPlugin or (isStudio and not isRunning)
end

-- whether this context owns an effect's attributes and may write a resolved
-- default back onto it. RunService:IsServer() alone is not the question; it
-- reads false in a team create session, whose edit session is a collaboration
-- client rather than the authority, and gating the write on it alone left an
-- effect emitted there with no attributes at all
function common.serverContext(isServer: boolean, isPluginContext: boolean)
  return isServer or isPluginContext
end

return common
