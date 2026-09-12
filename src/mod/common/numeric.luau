local numeric = {}

function numeric.finite(n: number): boolean
  return n == n and n ~= math.huge and n ~= -math.huge
end

-- a value that is not numeric is nobody's business here, so it passes. a
-- numeric one passes only when every component is finite: math.clamp keeps
-- nan, so one nan attribute reaches a tween as a duration and throws from a
-- render step every frame, which is how the Slash fixture looped
function numeric.usable(v: any): boolean
  local t = typeof(v)

  if t == "number" then
    return numeric.finite(v)
  end

  if t == "Vector3" or t == "vector" then
    return numeric.finite(v.X) and numeric.finite(v.Y) and numeric.finite(v.Z)
  end

  if t == "Vector2" then
    return numeric.finite(v.X) and numeric.finite(v.Y)
  end

  if t == "NumberRange" then
    return numeric.finite(v.Min) and numeric.finite(v.Max)
  end

  return true
end

return numeric
