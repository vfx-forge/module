-- run through the Studio MCP's execute_luau with a plugin build that carries this lightning
-- plays short bolts through the plugin's runtime (shared.vfx) and reads where each bolt's tip lands from its
-- EmitAtTip host and where it starts from its EmitOnStart host: that a random Length draws again for every bolt of
-- one emit, that a random EndOffset scatters each bolt's end around End, that a StartOffset moves the start alone and
-- leaves the end where it was, that a tweened Length moves a bolt's end while it holds one shape and stops at a wall
-- its line crosses, and that rows with no modifiers still land every bolt where they say. modifiers are written through the plugin's own store (shared.forge_dev)
-- with CLEAN true it only removes what an earlier run left; any FAIL raises with the whole output
const CLEAN = false

const HttpService = game:GetService("HttpService")

const KEY = "lightning_rows_check"
const NAME = "LightningRowsCheck"
const ORIGIN = Vector3.new(-300, 80, -340)
const SETTLE = 0.15
const NEAR = 0.05

-- only what an earlier run recorded is destroyed, never anything found by name
const function clean()
  const record = shared[KEY]

  shared[KEY] = nil

  if not record then
    return
  end

  for _, connection in record.connections do
    connection:Disconnect()
  end

  for _, instance in record.made do
    instance:Destroy()
  end
end

clean()

if CLEAN then
  return "cleaned"
end

const vfx = shared.vfx
const dev = shared.forge_dev

if type(vfx) ~= "table" or type(vfx.emit) ~= "function" then
  error("the plugin's runtime is not in shared.vfx", 0)
end

if type(dev) ~= "table" or type(dev.modules) ~= "table" or type(dev.modules.modifier_store) ~= "table" then
  error("the plugin's modifier store is not in shared.forge_dev", 0)
end

const store = dev.modules.modifier_store
const record = { made = {}, connections = {} }

shared[KEY] = record

const folder = Instance.new("Folder")

folder.Name = NAME
table.insert(record.made, folder)
folder.Parent = workspace

const lines = {}
local failed = false

const function check(name: string, ok: boolean, detail: string?)
  if not ok then
    failed = true
  end

  table.insert(lines, `{if ok then "ok" else "FAIL"} {name}{if detail then `: {detail}` else ""}`)
end

const function lit(v: any)
  return { t = "lit", v = v }
end

const function tween(from: any, to: any, duration: number)
  return { kind = "tween", chain = false, duration = duration, start = lit(from), finish = lit(to) }
end

const function randomizer(from: any, to: any, perComponent: boolean?)
  return { kind = "randomizer", chain = false, start = lit(from), finish = lit(to), perComponent = perComponent }
end

-- a still, straight bolt that shows at once and holds, with an emitter in EmitAtTip so its tip has a host
const function bolt(label: string, offset: number, attributes: { [string]: any }): Attachment
  const anchor = Instance.new("Part")

  anchor.Name = `Anchor{label}`
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanQuery = false
  anchor.Transparency = 1
  anchor.Size = Vector3.one
  anchor.CFrame = CFrame.new(ORIGIN + Vector3.new(offset, 0, 0))
  anchor.Parent = folder

  const attachment = Instance.new("Attachment")

  attachment.Name = `ForgeLightning{HttpService:GenerateGUID(false)}`
  attachment:AddTag("ForgeLightning")

  const defaults = {
    Forks = 0,
    Jagged = 0,
    Jitter = 0,
    Restrikes = 0,
    Appear = "Instant",
    Hold = NumberRange.new(0.5, 0.5),
    DisappearTime = 0.05,
  }

  for name, value in defaults do
    attachment:SetAttribute(name, value)
  end

  for name, value in attributes do
    attachment:SetAttribute(name, value)
  end

  const finish = Instance.new("Attachment")

  finish.Name = "End"
  finish.CFrame = CFrame.new(0, -20, 0)
  finish.Parent = attachment

  for _, slot in { "EmitAtTip", "EmitOnStart" } do
    const holder = Instance.new("Folder")
    const emitter = Instance.new("ParticleEmitter")

    holder.Name = slot
    emitter.Enabled = false
    emitter.Rate = 0
    emitter.Lifetime = NumberRange.new(0.1)
    emitter.Parent = holder
    holder.Parent = attachment
  end

  attachment.Parent = anchor

  return attachment
end

-- each bolt's tip and start, in the ref's space, once the bolts have settled
const function tips(ref: Attachment): ({ Vector3 }, { Vector3 })
  const hosts = { EmitAtTip = {}, EmitOnStart = {} }

  table.insert(
    record.connections,
    workspace.Terrain.DescendantAdded:Connect(function(child)
      const list = hosts[child.Name]

      if list and child:IsA("Attachment") then
        table.insert(list, child)
      end
    end)
  )

  vfx.emit(ref)
  task.wait(SETTLE)

  const function placed(list: { Attachment }): { Vector3 }
    const out = {}

    for _, host in list do
      table.insert(out, ref.WorldCFrame:PointToObjectSpace(host.WorldPosition))
    end

    return out
  end

  return placed(hosts.EmitAtTip), placed(hosts.EmitOnStart)
end

const function spread(values: { number }): number
  local low, high = math.huge, -math.huge

  for _, v in values do
    low = math.min(low, v)
    high = math.max(high, v)
  end

  return high - low
end

const function list(points: { Vector3 }): string
  const out = {}

  for _, p in points do
    table.insert(out, string.format("(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z))
  end

  return table.concat(out, " ")
end

do
  const ref = bolt("Plain", 0, { Target = "Direction", Count = 3, Length = 12 })
  const found = tips(ref)
  local onAxis = #found == 3

  for _, p in found do
    onAxis = onAxis and math.abs(p.Y - 12) < NEAR and math.abs(p.X) < NEAR and math.abs(p.Z) < NEAR
  end

  check("three bolts with no modifiers all end at Length up the axis", onAxis, list(found))
end

do
  const ref = bolt("Length", 40, { Target = "Direction", Count = 3, Length = 20 })

  store.write(ref, "attribute", "Length", { v = 2, queue = { randomizer(5, 40) } })

  const found = tips(ref)
  const lengths = {}
  local inside = #found == 3

  for _, p in found do
    table.insert(lengths, p.Y)
    inside = inside and p.Y >= 5 - NEAR and p.Y <= 40 + NEAR and math.abs(p.X) < NEAR and math.abs(p.Z) < NEAR
  end

  check("a random Length lands every bolt between its ends, up the axis", inside, list(found))
  check("a random Length draws again for each bolt of one emit", spread(lengths) > 0.5, list(found))
end

do
  const ref = bolt("EndOffset", 80, { Target = "End", Count = 3 })
  const box = Vector3.new(6, 6, 6)

  store.write(ref, "attribute", "EndOffset", { v = 2, queue = { randomizer(-box, box, true) } })

  const found = tips(ref)
  const xs = {}
  local inside = #found == 3

  for _, p in found do
    const off = p - Vector3.new(0, -20, 0)

    table.insert(xs, off.X)
    inside = inside and math.abs(off.X) <= 6 + NEAR and math.abs(off.Y) <= 6 + NEAR and math.abs(off.Z) <= 6 + NEAR
  end

  check("a random EndOffset lands each End bolt within its box around End", inside, list(found))
  check("a random EndOffset scatters the bolts of one emit", spread(xs) > 0.5, list(found))
end

do
  const ref = bolt("StartOffset", 120, {
    Target = "Direction",
    Length = 10,
    StartOffset = Vector3.new(4, 0, 0),
    EndOffset = Vector3.new(0, 0, 3),
  })

  const found, starts = tips(ref)

  check(
    "a StartOffset moves the start alone, in the attachment's axes",
    #starts == 1 and (starts[1] - Vector3.new(4, 0, 0)).Magnitude < NEAR,
    list(starts)
  )
  check(
    "and the end stays where Length and the EndOffset put it",
    #found == 1 and (found[1] - Vector3.new(0, 10, 3)).Magnitude < NEAR,
    list(found)
  )
end

for _, target in { "Direction", "End" } do
  const ref = bolt(`Starts{target}`, if target == "End" then 200 else 160, { Target = target, Count = 3, Length = 12 })
  const box = Vector3.new(5, 0, 5)

  store.write(ref, "attribute", "StartOffset", { v = 2, queue = { randomizer(-box, box, true) } })

  const found, starts = tips(ref)
  const want = if target == "End" then Vector3.new(0, -20, 0) else Vector3.new(0, 12, 0)
  const xs = {}
  local still = #found == 3

  for _, p in found do
    still = still and (p - want).Magnitude < NEAR
  end

  for _, p in starts do
    table.insert(xs, p.X)
  end

  check(
    `{target}: a random StartOffset starts each bolt of one emit apart`,
    #starts == 3 and spread(xs) > 0.5,
    list(starts)
  )
  check(`{target}: and every bolt still ends at the one end`, still, list(found))
end

do
  -- Jitter 0 never aims again, so only the frame's own reading of Length can move the end
  const free = bolt("Grows", 240, { Target = "Direction", Length = 2, Hold = NumberRange.new(1.2, 1.2) })
  const walled = bolt("Walled", 280, { Target = "Direction", Length = 2, Hold = NumberRange.new(1.2, 1.2) })
  const wall = Instance.new("Part")

  wall.Anchored = true
  wall.Size = Vector3.new(8, 1, 8)
  wall.CFrame = CFrame.new(ORIGIN + Vector3.new(280, 15.5, 0))
  wall.Parent = folder

  for _, ref in { free, walled } do
    store.write(ref, "attribute", "Length", { v = 2, queue = { tween(2, 30, 0.8) } })
  end

  const freeTips = tips(free)
  const walledTips = tips(walled)
  const early = { freeTips[1] and freeTips[1].Y, walledTips[1] and walledTips[1].Y }

  task.wait(0.8)

  -- a tip host keeps to its joint, so it is read again where it stands now
  const hosts = {}

  for _, child in workspace.Terrain:GetDescendants() do
    if child.Name == "EmitAtTip" and child:IsA("Attachment") then
      table.insert(hosts, child)
    end
  end

  const function reached(ref: Attachment): number?
    local best: number? = nil

    for _, host in hosts do
      const p = ref.WorldCFrame:PointToObjectSpace(host.WorldPosition)

      if math.abs(p.X) < NEAR and math.abs(p.Z) < NEAR and (best == nil or p.Y > best) then
        best = p.Y
      end
    end

    return best
  end

  const late = { reached(free), reached(walled) }
  const said = `early {early[1]} {early[2]}, late {late[1]} {late[2]}`

  check(
    "a tweened Length moves the end of a bolt that never aims again",
    early[1] ~= nil and late[1] ~= nil and early[1] < 12 and math.abs(late[1] - 30) < NEAR,
    said
  )
  check("and a wall its line crosses still stops it", late[2] ~= nil and math.abs(late[2] - 15) < NEAR, said)
end

task.wait(0.8)
clean()

const output = table.concat(lines, "\n")

if failed then
  error(`rows check failed\n{output}`, 0)
end

return output
