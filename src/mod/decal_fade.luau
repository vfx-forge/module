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
-- none for it, and the end, nil where the decal holds. an old model storing a
-- start and no end meant a fade to clear, which every release read before a
-- decal storing nothing held
function decal_fade.resolve(start: Instance?, stored: Stored): (number?, number?)
  const onMesh = decal_fade.onMesh(start, stored.flipbook)
  const from = if stored.decalStart ~= nil then stored.decalStart elseif onMesh then nil else stored.start

  if stored.decalEnd ~= nil then
    return from, stored.decalEnd
  end

  if onMesh then
    return from, 1
  end

  if stored.finish ~= nil then
    return from, stored.finish
  end

  return from, if from ~= nil then 1 else nil
end

-- a number stored as text reads as the number it spells, as a row reads it
const function numberOf(model: Instance, name: string, alias: string?): number?
  local v = attr.raw(model, name)

  if v == nil and alias ~= nil then
    v = attr.raw(model, alias)
  end

  return if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
end

-- what the model stores for its decal's fade, under every spelling the
-- mesh's rows answer to
function decal_fade.read(model: Instance): Stored
  return {
    flipbook = attr.raw(model, "Flipbook") == true,
    start = numberOf(model, "StartTransparency"),
    finish = numberOf(model, "EndTransparency"),
    decalStart = numberOf(model, "DecalStartTransparency", "Decal_StartTransparency"),
    decalEnd = numberOf(model, "DecalEndTransparency", "Decal_EndTransparency"),
  }
end

return decal_fade
