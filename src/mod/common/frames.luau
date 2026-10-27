local common = {}

export type Bounds = { size: Vector3, center: Vector3 }
export type Entry = { textures: number, used: number, lent: number, parked: boolean }

function common.index(count: number, alpha: number): number
  if count <= 0 then
    return 0
  end

  return math.min(math.max(math.round(count * alpha), 1), count)
end

local function axis(piece: number, union: number): number
  return if union == 0 then 1 else piece / union
end

function common.fit(frame: Bounds?, union: Bounds?, size: Vector3): (Vector3, Vector3)
  if not frame or not union then
    return size, Vector3.zero
  end

  const x = axis(size.X, union.size.X)
  const y = axis(size.Y, union.size.Y)
  const z = axis(size.Z, union.size.Z)
  const shift = frame.center - union.center

  return Vector3.new(frame.size.X * x, frame.size.Y * y, frame.size.Z * z),
    Vector3.new(shift.X * x, shift.Y * y, shift.Z * z)
end

function common.order(children: { Instance }): { Instance }
  const numbered = {}
  const found = {}

  for _, child in children do
    const number = tonumber(child.Name)

    if number and number >= 1 and number == math.floor(number) and not string.find(child.Name, "[^%d]") then
      table.insert(found, child)
      numbered[child] = number
    end
  end

  table.sort(found, function(a: Instance, b: Instance)
    return numbered[a] < numbered[b]
  end)

  return found
end

function common.evict(entries: { Entry }, budget: number, keep: Entry?): { Entry }
  local total = 0
  const parked = {}

  for _, entry in entries do
    if entry.parked then
      total += entry.textures
      table.insert(parked, entry)
    end
  end

  table.sort(parked, function(a: Entry, b: Entry)
    return a.used < b.used
  end)

  const out = {}

  for _, entry in parked do
    if total <= budget then
      break
    end

    if entry.lent == 0 and entry ~= keep then
      table.insert(out, entry)
      total -= entry.textures
    end
  end

  return out
end

return common
