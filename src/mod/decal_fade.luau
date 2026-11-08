local attr = require("@mod/attributes")

local decal_fade = {}

-- what a mesh model stores for its decal's fade, each under whichever
-- spelling it was found: the stone-age pair for the whole model, then the
-- decal's own start and end
export type Stored = {
  flipbook: boolean?,
  start: number?,
  finish: number?,
  decalStart: number?,
  decalEnd: number?,
}

-- whether the oldest transparency pair, one StartTransparency and one
-- EndTransparency for the whole model, meant the mesh or its decal: the decal
-- when the model's start wears one and the model is not an old flipbook
function decal_fade.onMesh(start: Instance?, flipbook: boolean?)
  return flipbook == true or start == nil or start:FindFirstChildOfClass("Decal") == nil
end

-- where a mesh model fades its decal: the start, nil where the model stores
-- none for it, and the end. a model storing no end fades its decal to clear,
-- as v2.4.0 did and the EasyMesh imports rely on
function decal_fade.resolve(start: Instance?, stored: Stored): (number?, number)
  const onMesh = decal_fade.onMesh(start, stored.flipbook)
  const from = if stored.decalStart ~= nil then stored.decalStart elseif onMesh then nil else stored.start

  if stored.decalEnd ~= nil then
    return from, stored.decalEnd
  end

  if not onMesh and stored.finish ~= nil then
    return from, stored.finish
  end

  return from, 1
end

-- a number stored as text reads as the number it spells, as a row reads it
const function numberOf(map: { [string]: any }, name: string, alias: string?): number?
  local v = map[name]

  if v == nil and alias ~= nil then
    v = map[alias]
  end

  return if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
end

-- what the model stores for its decal's fade, under every spelling the
-- mesh's rows answer to. one walk of its attributes rather than one read a
-- name, since the plugin reads this on every read of the decal's rows
function decal_fade.read(model: Instance): Stored
  const map = attr.map(model)

  return {
    flipbook = map.Flipbook == true,
    start = numberOf(map, "StartTransparency"),
    finish = numberOf(map, "EndTransparency"),
    decalStart = numberOf(map, "DecalStartTransparency", "Decal_StartTransparency"),
    decalEnd = numberOf(map, "DecalEndTransparency", "Decal_EndTransparency"),
  }
end

return decal_fade
