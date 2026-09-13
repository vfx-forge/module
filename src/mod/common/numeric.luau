local common = {}

function common.finite(n: number): boolean
  return n == n and n ~= math.huge and n ~= -math.huge
end

-- a value that is not numeric is nobody's business here, so it passes. a
-- numeric one passes only when every component is finite: math.clamp keeps
-- nan, so one nan attribute would otherwise reach a tween as a duration and
-- throw from a render step every frame
function common.usable(v: any): boolean
  local t = typeof(v)

  if t == "number" then
    return common.finite(v)
  end

  if t == "Vector3" or t == "vector" then
    return common.finite(v.X) and common.finite(v.Y) and common.finite(v.Z)
  end

  if t == "Vector2" then
    return common.finite(v.X) and common.finite(v.Y)
  end

  if t == "NumberRange" then
    return common.finite(v.Min) and common.finite(v.Max)
  end

  return true
end

return common
