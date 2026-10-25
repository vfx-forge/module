-- run through the VFX Forge MCP's studio_execute_luau, holding the place permission, with each paste line replaced
-- by that module's text, and comment lines, blank lines and indentation stripped so the paste stays small:
-- gawk 'match($0, /^ *--@paste ([a-z_]+)$/, m) { f = "src/mod/lightning/" m[1] ".luau"; while ((getline l < f) > 0) { sub(/^export type/, "type", l); print l }; next } { print }' tests/forge_lightning_studio/world_check.luau | grep -v -E '^\s*(--.*)?$' | sed -E 's/^\s+//'
-- rays only meet what is in the place, and the sandbox reaches the place only through place(), which lands after
-- the call answers, so the check runs twice: with KEY empty it builds the scratch geometry, stamps both of its roots
-- with a fresh GUID under the ROOT attribute, places them and answers that GUID; with KEY set to it, it finds the two
-- roots stamped with exactly that GUID, runs the rays, and destroys those two roots whatever happens
-- the sandbox cannot require a ModuleScript it made, so each module is pasted as a function body and require is
-- shadowed; nested takes a stand-in workspace whose Terrain is an anchored Part of the check's own at the origin,
-- since the sandbox cannot parent into the real Terrain
-- a module whose file does not exist yet is left empty, so its require fails by name; any FAIL raises with the
-- whole output
const KEY = ""

const HttpService = game:GetService("HttpService")

const ROOT = "LightningWorldCheck"
const TOLERANCE = 1e-4
const LIFT = 100

const modules = {}

const script = {
  Parent = setmetatable({}, {
    __index = function(_, name: string)
      return name
    end,
  }),
}

const function require(name: string): any
  const found = modules[name]

  if found == nil then
    error(`no module {name}`, 2)
  end

  return found
end

modules.impacts = (function()
  --@paste impacts
end)()

modules.world = (function()
  --@paste world
end)()

-- nested parents its hosts into workspace.Terrain, so it loads with a stand-in
const function loadNested(workspace: any)
  --@paste nested
end

const function at(x: number, y: number, z: number): Vector3
  return Vector3.new(x, y + LIFT, z)
end

const function slab(name: string, size: Vector3, cframe: CFrame, collide: boolean, parent: Instance): Part
  const part = Instance.new("Part")

  part.Name = name
  part.Anchored = true
  part.CanCollide = collide
  part.Size = size
  part.CFrame = cframe
  part.Parent = parent

  return part
end

const tilt = CFrame.new(at(-400, 0, -300)) * CFrame.Angles(0, 0, math.rad(30))

-- the baseplate tops out at y 8, so every position is lifted clear of it
-- wall face at z -419.5 looking +z; slope tilted 30 degrees about Z; the latch walls face x -255.5 and x -272.5;
-- the fence stands 6 high on the floor, its face at x -329.75 looking +x
const function build(): string
  const key = HttpService:GenerateGUID(false)
  const folder = Instance.new("Folder")
  const pieces = Instance.new("Folder")

  folder.Name = ROOT
  pieces.Name = ROOT
  folder:SetAttribute(ROOT, key)
  pieces:SetAttribute(ROOT, key)

  slab("Floor", Vector3.new(100, 1, 100), CFrame.new(at(-300, -0.5, -300)), true, folder)
  slab("Wall", Vector3.new(40, 40, 1), CFrame.new(at(-300, 20, -420)), true, folder)
  slab("Slope", Vector3.new(40, 1, 40), tilt, true, folder)
  -- the sandbox cannot parent into the place, so the attachment the rays start from is placed with its part
  Instance.new("Attachment").Parent = slab("Sword", Vector3.new(1, 1, 1), CFrame.new(at(-300, 5, -300)), true, folder)
  slab("Ghost", Vector3.new(20, 1, 20), CFrame.new(at(-300, 3, -300)), false, folder)
  slab("LatchNear", Vector3.new(1, 10, 10), CFrame.new(at(-255, 20, -300)), true, folder)
  slab("LatchFar", Vector3.new(1, 10, 10), CFrame.new(at(-273, 20, -300)), true, folder)
  slab("Fence", Vector3.new(0.5, 6, 10), CFrame.new(at(-330, 3, -270)), true, folder)

  -- collidable pieces another effect keeps under Terrain, like a Shockwave's debris, are not surfaces
  for i = 1, 3 do
    slab(`Rock{i}`, Vector3.new(30, 0.5, 30), CFrame.new(at(-300, 2 * i, -330)), true, pieces)
  end

  -- place is the bridge sandbox's own global
  -- selene: allow(undefined_variable)
  place(folder, workspace)
  -- selene: allow(undefined_variable)
  place(pieces, workspace.Terrain)

  return key
end

const lines = {}
local failed = false

const function check(name: string, ok: boolean, detail: string?)
  if not ok then
    failed = true
  end

  table.insert(lines, `{if ok then "ok" else "FAIL"} {name}{if ok or not detail then "" else `: {detail}`}`)
end

const function near(a: Vector3, b: Vector3): boolean
  return (a - b).Magnitude < TOLERANCE
end

const function stamped(parent: Instance): Instance?
  for _, child in parent:GetChildren() do
    if child:GetAttribute(ROOT) == KEY then
      return child
    end
  end

  return nil
end

const function rays(folder: Instance)
  const world = require("world")
  const impacts = require("impacts")
  const sword = folder:FindFirstChild("Sword") :: Part
  const holder = sword:FindFirstChildOfClass("Attachment") :: Attachment

  const params = world.params(holder)

  check(
    "params exclude the attachment's part",
    params.FilterType == Enum.RaycastFilterType.Exclude and params.FilterDescendantsInstances[1] == sword
  )
  check("params ignore water and respect CanCollide", params.IgnoreWater and params.RespectCanCollide)

  const down = Vector3.new(0, -1, 0)
  const floorPoint, floorNormal = world.ground(at(-300, 10, -300), down, 30, params)

  check("ground answers the floor point", floorPoint ~= nil and near(floorPoint, at(-300, 0, -300)), `{floorPoint}`)
  check(
    "ground answers the floor normal",
    floorNormal ~= nil and near(floorNormal, Vector3.new(0, 1, 0)),
    `{floorNormal}`
  )

  const wallPoint, wallNormal = world.ground(at(-300, 20, -410), Vector3.new(0, 0, -1), 30, params)

  check("ground answers the wall point", wallPoint ~= nil and near(wallPoint, at(-300, 20, -419.5)), `{wallPoint}`)
  check("ground answers the wall normal", wallNormal ~= nil and near(wallNormal, Vector3.new(0, 0, 1)), `{wallNormal}`)

  const slopeUp = tilt.UpVector
  const slopeTop = tilt.Position + slopeUp * 0.5
  const slopePoint, slopeNormal = world.ground(slopeTop + slopeUp * 10, -slopeUp, 30, params)

  check("ground answers the slope point", slopePoint ~= nil and near(slopePoint, slopeTop), `{slopePoint}`)
  check("ground answers the slope normal", slopeNormal ~= nil and near(slopeNormal, slopeUp), `{slopeNormal}`)

  const farPoint = world.ground(at(-300, 100, -300), down, 30, params)

  check("ground answers nil from out of reach", farPoint == nil, `{farPoint}`)

  const across, acrossNormal = world.cross(at(-300, 20, -400), at(-300, 20, -430), params)

  check(
    "cross finds the wall",
    across ~= nil and near(across, at(-300, 20, -419.5)) and near(acrossNormal, Vector3.new(0, 0, 1))
  )
  check("cross misses short of it", world.cross(at(-300, 20, -400), at(-300, 20, -410), params) == nil)

  const beyond = world.beyond(at(-300, 20, -419), Vector3.new(0, 0, -1), params)

  check("beyond finds a surface just past the end", beyond ~= nil and near(beyond, at(-300, 20, -419.5)), `{beyond}`)
  check("beyond misses in open air", world.beyond(at(-300, 20, -380), Vector3.new(0, 0, -1), params) == nil)

  const rockPoint, rockNormal = world.ground(at(-300, 10, -330), down, 30, world.params(holder))

  check(
    "ground passes through effect pieces under Terrain to the floor",
    rockPoint ~= nil and near(rockPoint, at(-300, 0, -330)) and near(rockNormal, Vector3.new(0, 1, 0)),
    `{rockPoint}`
  )

  const crossRocks = world.cross(at(-300, 10, -330), at(-300, -5, -330), world.params(holder))

  check(
    "cross passes through effect pieces under Terrain",
    crossRocks ~= nil and near(crossRocks, at(-300, 0, -330)),
    `{crossRocks}`
  )

  -- a fork's tip at x -260: the near wall's face 4.5 studs one way, the far wall's 12.5 the other
  const tip = at(-260, 20, -300)
  const east = Vector3.new(1, 0, 0)
  const west = Vector3.new(-1, 0, 0)
  const both = { west, east, Vector3.new(0, 1, 0) }
  const latched, latchNormal = world.latch(tip, both, 15, world.params(holder))

  check(
    "latch answers the nearest wall within reach",
    latched ~= nil and near(latched, at(-255.5, 20, -300)) and near(latchNormal, west),
    `{latched} {latchNormal}`
  )
  check("latch ignores a wall beyond its reach", world.latch(tip, { west }, 8, world.params(holder)) == nil)
  check("latch answers nil with nothing within reach", world.latch(tip, both, 4, world.params(holder)) == nil)

  const fanned = {}

  for _, direction in
    impacts.fan(vector.create(1, 0, 0), vector.create(0, -1, 0), impacts.LATCH_RAYS, impacts.LATCH_CONE)
  do
    table.insert(fanned, Vector3.new(direction.X, direction.Y, direction.Z))
  end

  const fanPoint = world.latch(tip, fanned, 6, world.params(holder))

  check("latch takes the fan's directions", fanPoint ~= nil and near(fanPoint, at(-255.5, 20, -300)), `{fanPoint}`)

  -- a fork whose chord crosses the fence strikes its face, though the floor behind it is within Latch of the tip
  const fence = Vector3.new(1, 0, 0)
  const struck, struckNormal = world.fork(at(-325, 4, -270), at(-335, 3, -270), 6, world.params(holder))

  check(
    "a fork whose chord crosses a wall strikes its face, not the floor behind it",
    struck ~= nil and near(struck, at(-329.75, 3.525, -270)) and near(struckNormal, fence),
    `{struck} {struckNormal}`
  )

  -- a chord that clears the fence's top, from a tip whose latch finds the floor behind it
  const bent, bentNormal = world.fork(at(-322, 12, -270), at(-334, 5.5, -270), 6, world.params(holder))

  check(
    "a fork bent onto a latch through a wall strikes the wall instead",
    bent ~= nil and near(bent, at(-329.75, 4.25, -270)) and near(bentNormal, fence),
    `{bent} {bentNormal}`
  )

  const clear, clearNormal = world.fork(at(-340, 8, -280), at(-345, 4, -280), 6, world.params(holder))

  check(
    "a fork with a clear chord latches onto the floor within reach",
    clear ~= nil and near(clear, at(-345, 0, -280)) and near(clearNormal, Vector3.new(0, 1, 0)),
    `{clear} {clearNormal}`
  )

  const debris, debrisNormal = world.latch(at(-300, 10, -330), { down, east }, 30, world.params(holder))

  check(
    "latch passes through effect pieces under Terrain to the floor",
    debris ~= nil and near(debris, at(-300, 0, -330)) and near(debrisNormal, Vector3.new(0, 1, 0)),
    `{debris}`
  )
end

const function hosts(held: { Instance })
  const impacts = require("impacts")
  const terrain = Instance.new("Part")

  table.insert(held, terrain)
  terrain.Name = "Terrain"
  terrain.Anchored = true
  terrain.CFrame = CFrame.identity

  const nested = loadNested({ Terrain = terrain })

  -- nested hosts, with a stand-in sdk that records what it is handed
  const emitted = {}
  const sdk = {
    hold = function(_, thing)
      table.insert(held, thing)

      return thing
    end,
    emit = function(_, instance)
      table.insert(emitted, instance)
    end,
  }

  const ref = Instance.new("Folder")

  table.insert(held, ref)

  for _, name in { "EmitOnImpact", "EmitAlong", "Bolt", "Other" } do
    const slot = Instance.new("Folder")

    slot.Name = name
    slot.Parent = ref
  end

  Instance.new("ParticleEmitter").Parent = ref.EmitOnImpact
  Instance.new("Beam").Parent = ref.Bolt

  const empty = Instance.new("Folder")

  empty.Name = "EmitOnStart"
  empty.Parent = ref

  const slots = nested.slots(ref)
  local slotCount = 0

  for _ in slots do
    slotCount += 1
  end

  check(
    "slots holds only named folders with a child, Bolt among them",
    slots.EmitOnImpact == ref.EmitOnImpact and slots.Bolt == ref.Bolt and slotCount == 2,
    `{slots.EmitOnImpact} {slots.Bolt} count {slotCount}`
  )

  const slopeUp = tilt.UpVector
  const right, up, look =
    impacts.axes(vector.create(slopeUp.X, slopeUp.Y, slopeUp.Z), vector.create(0, -1, 0), "Surface")
  const point = at(-400, 0, -300)
  const frame = CFrame.fromMatrix(point, Vector3.new(right.x, right.y, right.z), Vector3.new(up.x, up.y, up.z))
  const children = { ref.EmitOnImpact:GetChildren()[1], ref.Bolt:GetChildren()[1] }
  const host = nested.host(sdk, {}, children, "EmitOnImpact", frame)

  check(
    "host sits under Terrain, named for its slot, and is not archivable",
    host.Parent == terrain and host.Name == "EmitOnImpact" and not host.Archivable
  )
  check(
    "host holds a clone of each child it was handed",
    #host:GetChildren() == 2
      and host:FindFirstChildOfClass("ParticleEmitter") ~= nil
      and host:FindFirstChildOfClass("Beam") ~= nil
  )
  check("host is emitted once", #emitted == 1 and emitted[1] == host)
  check(
    "host's UpVector is the slope normal",
    near(host.WorldCFrame.UpVector, slopeUp),
    `{host.WorldCFrame.UpVector} want {slopeUp}`
  )
  check(
    "host's forward axis is the projected travel",
    near(host.WorldCFrame.LookVector, Vector3.new(look.x, look.y, look.z))
  )

  nested.again(sdk, {}, host, CFrame.new(at(1, 2, 3)))

  check(
    "again moves the host and emits it again",
    #emitted == 2 and near(host.WorldCFrame.Position, at(1, 2, 3)) and #host:GetChildren() == 2
  )
end

if KEY == "" then
  return build()
end

const folder = stamped(workspace)
const pieces = stamped(workspace.Terrain)
const held = {}

check("the scratch roots are in the place", folder ~= nil and pieces ~= nil)

-- each half runs on its own, so a raise in one still lets the other report
for name, half in
  {
    rays = function()
      rays(folder :: Instance)
    end,
    hosts = function()
      hosts(held)
    end,
  }
do
  if name == "rays" and not (folder and pieces) then
    continue
  end

  const ran, problem = pcall(half)

  if not ran then
    check(`the {name} half ran to its end`, false, tostring(problem))
  end
end

-- only the two roots stamped with this run's GUID and what this call held are destroyed
for i = #held, 1, -1 do
  held[i]:Destroy()
end

if folder then
  folder:Destroy()
end

if pieces then
  pieces:Destroy()
end

const output = table.concat(lines, "\n")

if failed then
  error(`world check failed\n{output}`, 0)
end

return output
