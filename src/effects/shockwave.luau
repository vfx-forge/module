local knob = require("@mod/knob")

local shockwave = {}

shockwave.id = "shockwave"
shockwave.display = { name = "Shockwave", icon = "shockwave", order = 50 }
shockwave.classifier = "Attachment.Shockwave"

-- the origin every piece effect casts from. it emits nothing itself: its
-- rings, lines and debris are effects of their own that read it
shockwave.attributes = {
  RayDirection = knob(vector.create(0, -50, 0))
    :unit("studs")
    :label("RayDirection")
    :hint("Direction for raycast-based effects."),
  RayCollisionGroup = knob("Default"):label("RayCollisionGroup"):hint("Collision group used for raycasting."),
  FilterTag = knob(""):label("Tag"):hint("CollectionService tag used to filter raycast hits."),
  FilterType = knob("Exclude")
    :options({ "Include", "Exclude" })
    :label("Type")
    :hint("Whether the tag filter includes or excludes tagged parts."),
  IgnoreWater = knob(true):label("IgnoreWater"):hint("Whether raycasts ignore water."),
  IgnoreCanCollide = knob(false)
    :label("IgnoreCanCollide")
    :hint("Whether raycasts also hit parts with CanCollide off. Off, they pass through them."),
}

shockwave.properties = {}

shockwave.layout = {
  { title = "Raycast", entries = { "RayDirection", "RayCollisionGroup" } },
  { title = "Filter", entries = { "FilterTag", "FilterType", "IgnoreWater", "IgnoreCanCollide" } },
}

function shockwave.emit() end

return shockwave
