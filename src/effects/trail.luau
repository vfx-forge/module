local reader = require("@mod/reader")

local trail = {}

trail.id = "trail"
trail.display = { name = "Trail", icon = "trail", order = 12 }
trail.classifier = "Trail"

trail.attributes = {}
trail.properties = {}

-- a trail has nothing to read: emitting it turns it on, and whatever queues it
-- carries are the applier's
function trail.emit(ctx: reader.Ctx)
  (ctx.ref :: Trail).Enabled = true
end

return trail
