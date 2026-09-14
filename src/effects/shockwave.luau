local knob = require("@mod/knob")

local shockwave = {}

shockwave.id = "shockwave"
shockwave.display = { name = "Shockwave", icon = "shockwave", order = 50 }
shockwave.classifier = "Attachment.Shockwave"

-- the origin every piece effect casts from. it emits nothing itself: its
-- rings, lines and debris are effects of their own that read it
shockwave.attributes = {
  RayDirection = knob(vector.create(0, -50, 0)):unit("studs"),
  RayCollisionGroup = knob("Default"),
  FilterTag = knob(""),
  FilterType = knob("Exclude"):options({ "Include", "Exclude" }),
  IgnoreWater = knob(true),
  IgnoreCanCollide = knob(false),
}

shockwave.properties = {}

shockwave.layout = {
  { title = "Ray", entries = { "RayDirection", "RayCollisionGroup" } },
  { title = "Filter", entries = { "FilterTag", "FilterType", "IgnoreWater", "IgnoreCanCollide" } },
}

function shockwave.emit() end

return shockwave
