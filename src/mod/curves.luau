local path = require("@mod/common/path")
local logger = require("@mod/logger")

local curves = {}

-- a chain in the serialized form a curve row stores: the points as f32 pairs,
-- y down, an anchor every 24 bytes with its handles between. taken as plain
-- numbers, y up, since a vector would round them to single precision first
local function encode(numbers: { number }): string
  local buf = buffer.create((#numbers // 6 + 1) * 24)

  for i = 1, #numbers, 2 do
    buffer.writef32(buf, (i - 1) * 4, numbers[i])
    buffer.writef32(buf, (i - 1) * 4 + 4, 1 - numbers[i + 1])
  end

  return buffer.tostring(buf)
end

-- each a chain of x and y pairs, y up: an anchor, its outgoing handle, the next
-- anchor's incoming handle, the next anchor. the eased three are the cubic
-- easings CSS names. the out cubic is the one every effect always eased with,
-- its incoming handle's x as the editor stored it, one f32 step off 0.355
curves.PRESETS = table.freeze({
  linear = encode({ 0, 0, 0, 0, 1, 1, 1, 1 }),
  easeIn = encode({ 0, 0, 0.55, 0.055, 0.675, 0.19, 1, 1 }),
  easeOut = encode({ 0, 0, 0.215, 0.61, 0.355000019, 1, 1, 1 }),
  easeInOut = encode({ 0, 0, 0.645, 0.045, 0.355, 1, 1, 1 }),
})

-- whether a string naming no preset is a serialized path, decided once per
-- string: a rule handing back a curve row's value asks again for every piece
local PATHS: { [string]: boolean } = {}

-- the out cubic every effect always eased with
function curves.default(): string
  return curves.PRESETS.easeOut
end

function curves.linear(): string
  return curves.PRESETS.linear
end

-- a row names its curve by preset; nil is the out cubic. a string naming no
-- preset is a serialized path when it holds points, which is what a rule
-- reading a curve row hands back
function curves.preset(name: (string | buffer)?)
  if typeof(name) == "buffer" then
    return name
  end

  local serialized = curves.PRESETS[name or "easeOut"]

  if serialized ~= nil then
    return serialized
  end

  if typeof(name) == "string" then
    local known = PATHS[name]

    if known == nil then
      known = #path.deserializePath(name) > 0
      PATHS[name] = known
    end

    if known then
      return name
    end
  end

  logger.error(`unknown curve preset {tostring(name)}`)
end

-- a preset's chain as its points, y up, the way `PRESETS` writes them
function curves.points(name: string): { vector }
  const points = path.deserializePath(curves.preset(name) :: string)

  for i, p in points do
    points[i] = vector.create(p.x, 1 - p.y, 0)
  end

  return points
end

return curves
