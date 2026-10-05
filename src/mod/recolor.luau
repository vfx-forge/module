local attr = require("@mod/attributes")
local registry = require("@mod/registry")

local colorProps = {
  Single = {
    Color3 = {
      "Decal",
      "Texture",
    },

    Color = {
      "Part",
      "Union",
      "MeshPart",

      "SpotLight",
      "PointLight",
      "SurfaceLight",

      "SurfaceAppearance",
    },
  },

  Sequence = {
    Color = {
      "Beam",
      "Trail",
      "ParticleEmitter",
    },
  },
}

local function warp(x: number)
  return ((x % 1) + 1) % 1
end

local function multiplyHue(h0: number, h1: number)
  local rotation = (h1 - 0.5) * 1
  return warp(h0 + rotation)
end

local function multiplyChannel(c0: number, c1: number)
  local t = 2 * c1 - 1

  if t >= 0 then
    return math.clamp(c0 + (1 - c0) * t, 0, 1)
  else
    return math.clamp(c0 - c0 * math.abs(t), 0, 1)
  end
end

local function normalizeColor(color: Color3)
  local r, g, b = color.R, color.G, color.B
  local f = math.max(1, r, g, b)
  return f, Color3.new(r / f, g / f, b / f)
end

local function multiplyRGB(color: Color3, factor: number)
  return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

-- one color multiplied by another, the way this module has always meant it:
-- the hue rotated, the saturation and value pushed, the overbright factor kept
local function multiplyColor(c: Color3, color: Color3): Color3
  local hue, sat, val = color:ToHSV()

  local f, col = normalizeColor(c)
  local h0, s0, v0 = col:ToHSV()

  local h2 = multiplyHue(h0, hue)
  local s2 = multiplyChannel(s0, sat)
  local v2 = multiplyChannel(v0, val)

  return multiplyRGB(Color3.fromHSV(h2, s2, v2), f)
end

local function recolorObj(obj: Instance, color: Color3, mode: string, isDirect: boolean)
  if not isDirect and obj:IsA("BasePart") then
    return
  end

  for _, info in colorProps do
    for k, v in info do
      if not table.find(v, obj.ClassName) then
        continue
      end

      local c = obj[k]

      if mode == "multiply" then
        if typeof(c) == "Color3" then
          obj[k] = multiplyColor(c, color)
        elseif typeof(c) == "ColorSequence" then
          local res = {}

          for _, kp in c.Keypoints do
            table.insert(res, ColorSequenceKeypoint.new(kp.Time, multiplyColor(kp.Value, color)))
          end

          obj[k] = ColorSequence.new(res)
        end
      else
        if typeof(c) == "Color3" then
          local f = normalizeColor(c)
          obj[k] = Color3.new(color.R * f, color.G * f, color.B * f)
        elseif typeof(c) == "ColorSequence" then
          obj[k] = ColorSequence.new(color)
        end
      end
    end
  end
end

-- the color rows of a classified instance: a sequence row is replaced by a
-- flat sequence of the color, or multiplied keypoint by keypoint. the row goes
-- through the cache-aware read and write, so a cached instance is recolored
-- where every reader on this path looks, and a soft read stamps nothing
local function recolorRows(obj: Instance, color: Color3, mode: string)
  local module = registry.of(obj)

  if module == nil then
    return
  end

  for name, row in module.attributes do
    local kind = row.kind

    if kind ~= "Color3" and kind ~= "ColorSequence" then
      continue
    end

    local current = attr.get(obj, name, nil, true)

    if current == nil then
      for _, alias in row.names do
        current = attr.get(obj, alias, nil, true)

        if current ~= nil then
          name = alias
          break
        end
      end
    end

    if current == nil then
      current = row.default
    end

    if typeof(current) == "Color3" then
      attr.set(obj, name, if mode == "multiply" then multiplyColor(current, color) else color)
    elseif typeof(current) == "ColorSequence" then
      if mode == "multiply" then
        local keypoints = {}

        for _, kp in current.Keypoints do
          table.insert(keypoints, ColorSequenceKeypoint.new(kp.Time, multiplyColor(kp.Value, color)))
        end

        attr.set(obj, name, ColorSequence.new(keypoints))
      else
        attr.set(obj, name, ColorSequence.new(color))
      end
    end
  end
end

local function recolor(color: Color3, mode: "replace" | "multiply", ...: Instance)
  for _, instance in { ... } do
    recolorObj(instance, color, mode, true)
    recolorRows(instance, color, mode)

    for _, desc in instance:GetDescendants() do
      recolorObj(desc, color, mode, false)
      recolorRows(desc, color, mode)
    end
  end
end

return recolor
