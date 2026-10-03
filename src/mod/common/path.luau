local path = {}

function path.serializePath(points: { Path2DControlPoint })
  local buf = buffer.create(#points * 4 * 6)

  local offset = 0

  for i, p in points do
    local px = p.Position.X.Scale
    local py = p.Position.Y.Scale

    if i ~= 1 then
      buffer.writef32(buf, offset, px + p.LeftTangent.X.Scale)
      buffer.writef32(buf, offset + 4, py + p.LeftTangent.Y.Scale)

      offset += 8
    end

    buffer.writef32(buf, offset, px)
    buffer.writef32(buf, offset + 4, py)

    offset += 8

    if i ~= #points then
      buffer.writef32(buf, offset, px + p.RightTangent.X.Scale)
      buffer.writef32(buf, offset + 4, py + p.RightTangent.Y.Scale)

      offset += 8
    end
  end

  return buf
end

function path.deserializePath(data: string | buffer)
  local buf = typeof(data) == "string" and buffer.fromstring(data) or data
  local count = buffer.len(buf) / 24

  local points = {}

  for i = 0, count - 1 do
    local offset = i * 4 * 6

    local px = buffer.readf32(buf, offset)
    local py = buffer.readf32(buf, offset + 4)

    table.insert(points, vector.create(px, py))

    if i ~= count - 1 then
      local t1x = buffer.readf32(buf, offset + 8)
      local t1y = buffer.readf32(buf, offset + 12)

      local t2x = buffer.readf32(buf, offset + 16)
      local t2y = buffer.readf32(buf, offset + 20)

      table.insert(points, vector.create(t1x, t1y))
      table.insert(points, vector.create(t2x, t2y))
    end
  end

  return points
end

return path
