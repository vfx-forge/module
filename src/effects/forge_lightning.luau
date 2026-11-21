local lazy = require("@mod/lazy")

const SDK = require("@root/sdk/v1/types")

const rows = require("@mod/lightning/rows")
const timeline = require("@mod/lightning/timeline")

const NO_TIME = { Min = 0, Max = 0 }
const effect = {}

effect.sdk_version = 1
effect.id = "forge_lightning"
effect.display = { name = "Lightning", icon = "lightning", category = "paths" }
effect.classifier = "Attachment.ForgeLightning"
effect.components = "> #End, > #EmitOnStart, > #EmitOnImpact, > #EmitAtTip, > #Bolt, > #EmitAlong, > #EmitOnFinish"
effect.constant = true
effect.layout = rows.layout
effect.params = rows.params

const function sample(track: any, elapsed: number)
  return if track.animated then track:at(elapsed) else track.value
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
function effect.duration(_: SDK.V1, attrs: any)
  return attrs.EmitDelay + attrs.EmitDuration + timeline.duration(timing(attrs))
end

function effect.template(_: SDK.V1)
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

function effect.emit(sdk: any, ctx: any, attrs: any)
  return play().emit(sdk, ctx, attrs)
end

return effect
