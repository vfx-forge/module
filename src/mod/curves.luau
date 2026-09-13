local path = require("@mod/common/path")
local logger = require("@mod/logger")

local curves = {}

local default_curve: string? = nil
local linear_curve: string? = nil

-- built on first call rather than at module scope, so a module that requires
-- this one still LOADS outside the engine: Path2DControlPoint and UDim2 are
-- Roblox datatypes and lune has neither. legacy_mods needs the same out cubic
-- default utility hands every effect, and cannot require utility for it because
-- utility requires mods which requires legacy_mods
function curves.default(): string
  if default_curve == nil then
    default_curve = buffer.tostring(path.serializePath({
      Path2DControlPoint.new(UDim2.fromScale(0, 1), UDim2.new(), UDim2.fromScale(0.215, -0.61)),
      Path2DControlPoint.new(UDim2.fromScale(1, 0), UDim2.fromScale(-0.645, 0), UDim2.new()),
    }))
  end

  return default_curve :: string
end

function curves.linear(): string
  if linear_curve == nil then
    linear_curve = buffer.tostring(path.serializePath({
      Path2DControlPoint.new(UDim2.fromScale(0, 1)),
      Path2DControlPoint.new(UDim2.fromScale(1, 0)),
    }))
  end

  return linear_curve :: string
end

curves.PRESETS = {
  easeOut = curves.default,
  linear = curves.linear,
}

-- a row names its curve by preset; nil is the out cubic every effect always
-- eased with
function curves.preset(name: string?): string
  local build = curves.PRESETS[name or "easeOut"]

  if build == nil then
    logger.error(`unknown curve preset {tostring(name)}`)
  end

  return build()
end

return curves
