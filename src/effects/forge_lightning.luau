local lazy = require("@mod/lazy")

const rows = require("@mod/lightning/rows")
const timeline = require("@mod/lightning/timeline")

const NO_TIME = { Min = 0, Max = 0 }
const forge_lightning = {}

forge_lightning.id = "forge_lightning"
forge_lightning.display = { name = "Lightning", icon = "lightning", category = "paths" }
forge_lightning.classifier = "Attachment.ForgeLightning"
forge_lightning.components =
  "> #End, > #EmitOnStart, > #EmitOnImpact, > #EmitAtTip, > #Bolt, > #EmitAlong, > #EmitOnFinish"
forge_lightning.constant = true
forge_lightning.layout = rows.layout
forge_lightning.attributes = rows.attributes
forge_lightning.properties = {}

const function sample(track: any, elapsed: number)
  return if track.animated then track.at(elapsed) else track.value
end

-- an Instant bolt has no appear phase, so its hidden time rows add nothing, and a continuous one holds until it is
-- let go, so it takes no hold and no restrikes from its rows. a bolt's timing is its own rows as they start, and the
-- effect's length reads the rows' own values, since a drawn one is not drawn yet
const function timing(attrs: any, mine: any?, staying: boolean?)
  const restrikes = if mine then sample(mine.Restrikes, 0) else attrs.Restrikes.value
  const disappearTime = if mine then sample(mine.DisappearTime, 0) else attrs.DisappearTime.value

  return {
    appear = attrs.Appear,
    appearTime = if attrs.Appear == "Instant" then NO_TIME else attrs.AppearTime,
    hold = if staying then NO_TIME else attrs.Hold,
    restrikes = if staying then 0 else math.max(0, math.floor(restrikes)),
    disappear = attrs.Disappear,
    disappearTime = math.max(0, disappearTime),
  }
end

const play = lazy.unit("forge_lightning", function()
  return require("@root/play/forge_lightning").bind({ sample = sample, timing = timing })
end)

-- a window's last tick can start as it closes and plays a whole bolt after it
function forge_lightning.duration(_: any, attrs: any)
  return attrs.EmitDelay + attrs.EmitDuration + timeline.duration(timing(attrs))
end

function forge_lightning.template()
  const attachment = Instance.new("Attachment")

  attachment.Name = "ForgeLightning"
  attachment:AddTag("ForgeLightning")

  const finish = Instance.new("Attachment")

  finish.Name = "End"
  finish.CFrame = CFrame.new(0, -20, 0)
  finish.Parent = attachment

  for _, name in { "EmitOnImpact", "Bolt", "EmitAlong" } do
    const folder = Instance.new("Folder")

    folder.Name = name
    folder.Parent = attachment
  end

  return attachment
end

function forge_lightning.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return forge_lightning
