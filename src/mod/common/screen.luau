local common = {}

-- the plugin's schema refactor of 2026-07-02 stores PartScale as a Vector2
-- while older assets still hold the Vector3 the previous panel wrote, and
-- multiplying a Vector3 by a Vector2 throws inside the render step
function common.size(width: number, height: number, depth: number, scale: any): Vector3
  local t = typeof(scale)

  if t == "Vector3" or t == "vector" then
    return Vector3.new(width * scale.X, height * scale.Y, depth * scale.Z)
  end

  if t == "Vector2" then
    return Vector3.new(width * scale.X, height * scale.Y, depth)
  end

  if t == "number" then
    return Vector3.new(width * scale, height * scale, depth)
  end

  return Vector3.new(width, height, depth)
end

return common
