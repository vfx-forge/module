const lerp = require("@mod/lerp")
const curves = require("@mod/curves")
const attr = require("@mod/attributes")
const mods = require("@mod/mods")
const color = require("@mod/color/color")
const value = require("@mod/value")
const frame = require("@mod/modifier_frame")
const codec = require("@mod/modifier_codec")
const reader = require("@mod/reader")
const resize = require("@mod/resize")
const retime = require("@mod/retime")
const lifetime = require("@mod/lifetime")
const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const mover = require("@srv/mover")
const fake_pool = require("@tests/fake_pool")
const frame_show = require("@mod/frame_show")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")
const value_curve = require("@mod/value_curve")
const particle_motion = require("@mod/particle_motion")
const test, expect = harness.test, harness.expect

const look_common = require("@mod/common/look")
const force_rows = require("@mod/common/force_rows")
const launch_common = require("@mod/common/launch")
const state_list = require("@mod/common/state_list")
const path_curve = require("@mod/common/path_curve")
const collision_common = require("@mod/common/collision")
const parent_turn = require("@mod/common/parent_turn")

const forge_mesh = require("@vfx/forge_mesh")

const Bezier = require("@obj/Bezier")

const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

const EPSILON = 1e-4
const LOOSE = 1e-3
const FRAME = 1 / 60

-- the draws one States piece of no randomizers makes
const PIECE_DRAWS = 6

-- a launch of no speed, so a piece stands where it spawned
const STILL = NumberRange.new(0, 0)

-- the effect registered on the effects service and on a pool that clones
-- every take whole into its folder, or reuses a copy of a class `lists` names
-- the properties of, put back once `body` ends
const function staged(body: (fake: fake_pool.Fake) -> (), lists: { [string]: { string } }?)
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(forge_mesh)

  -- every emit cleared once `body` ends, so a piece of a long life left
  -- flying never moves under the next spec, where its pool is gone
  const emit = effects.emit
  const emitted = {}

  effects.emit = function(...)
    const env = emit(...)

    table.insert(emitted, env)

    return env
  end

  const fake = fake_pool.start(lists or {})
  const ok, err = pcall(body, fake)

  effects.emit = emit

  for _, env in emitted do
    env:Clear()
  end

  fake_pool.stop(fake)
  registry.clear()

  if not ok then
    error(err, 0)
  end
end

-- `staged` with the frame store started under a terrain of its own and both
-- frame engine seams stood in
const function framed(body: (fake: fake_pool.Fake) -> (), lists: { [string]: { string } }?)
  const protect, terrain = utility.protectParent, workspace.Terrain
  const constructor, store, show = Instance, frame_store.engine, frame_show.engine
  const scope = {}

  utility.protectParent = function() end
  -- selene: allow(incorrect_standard_library_use)
  workspace.Terrain = harness.make("Folder") :: any

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  frame_store.engine = {
    now = function()
      return 0
    end,
    detaches = function()
      return false
    end,
    maps = function()
      return 1
    end,
    clone = function(instance: Instance)
      return instance:Clone()
    end,
  }

  frame_show.engine = {
    apply = function() end,
  }

  const ok, err = pcall(staged, function(fake)
    frame_store.init(scope)
    body(fake)
  end, lists)

  utility.cleanupScope(scope)
  frame_store.engine, frame_show.engine = store, show
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- every piece's drawn life by the piece, as the look is handed it, put back
-- once `body` ends
const function recording(body: (lives: { [BasePart]: number }) -> ())
  const start = look_common.start
  const lives: { [BasePart]: number } = {}

  look_common.start = function(scope, piece, template, attrs, duration, ...)
    lives[piece] = duration

    return start(scope, piece, template, attrs, duration, ...)
  end

  const ok, err = pcall(body, lives)

  look_common.start = start

  if not ok then
    error(err, 0)
  end
end

-- every Random built without a seed seeded apart, as the harness's fixed one
-- would draw the same for every piece, put back once `body` ends
const function seeding(body: () -> ())
  const new = Random.new
  local seed = 0

  -- selene: allow(incorrect_standard_library_use)
  Random.new = function(given: number?)
    seed += 1

    return new(given or (seed * 1103515245 + 12345) % 2147483647)
  end

  const ok, err = pcall(body)

  -- selene: allow(incorrect_standard_library_use)
  Random.new = new

  if not ok then
    error(err, 0)
  end
end

-- the draws every Random built while `body` runs makes, put back once it ends
const function counted(body: () -> ()): number
  const new = Random.new
  local draws = 0

  -- selene: allow(incorrect_standard_library_use)
  Random.new = function(...: any)
    const rng = new(...) :: any

    return setmetatable({}, {
      __index = function(_, name: string)
        return function(_, ...: any)
          draws += 1

          return rng[name](rng, ...)
        end
      end,
    }) :: any
  end

  const ok, err = pcall(body)

  -- selene: allow(incorrect_standard_library_use)
  Random.new = new

  if not ok then
    error(err, 0)
  end

  return draws
end

-- a randomizer from `low` to `high` on the row `name`, drawn per component
const function randomized(obj: Instance, name: string, low: any, high: any)
  const queue = {
    { kind = "randomizer", chain = false, start = value.lit(low), finish = value.lit(high), perComponent = true },
  }

  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

-- a tween from `low` to `high` on the row `name` over the effect
const function tweened(obj: Instance, name: string, low: any, high: any)
  const queue = { { kind = "tween", chain = false, start = value.lit(low), finish = value.lit(high) } }

  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

-- tweens on the row `name` that play in turn, `each` seconds apiece, from
-- each of `values` to the next
const function stepped(obj: Instance, name: string, values: { any }, each: number)
  const queue = {}

  for i = 1, #values - 1 do
    table.insert(queue, {
      kind = "tween",
      chain = false,
      duration = each,
      start = value.lit(values[i]),
      finish = value.lit(values[i + 1]),
    })
  end

  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

-- every piece in the order it spawned while `body` runs, put back once it ends
const function spawning(body: (spawned: { BasePart }) -> ())
  const start = look_common.start
  const spawned = {}

  look_common.start = function(scope, piece, ...)
    table.insert(spawned, piece)

    return start(scope, piece, ...)
  end

  const ok, err = pcall(body, spawned)

  look_common.start = start

  if not ok then
    error(err, 0)
  end
end

-- a tagged template part under `parent`, its rows set from `attributes`
const function template(parent: Instance, attributes: { [string]: any }): BasePart
  const part = harness.make("Part", parent) :: BasePart

  part.Name = "Template"
  part:AddTag(utility.FORGE_MESH_TAG)

  for name, value in attributes do
    part:SetAttribute(name, value)
  end

  return part
end

-- a part of `size` at `cframe` holding the template, in a folder of its own
const function parentPart(cframe: CFrame, size: Vector3): (Instance, BasePart)
  const root = harness.make("Folder")
  const part = harness.make("Part", root) :: BasePart

  part.CFrame = cframe
  part.Size = size

  return root, part
end

-- where `attached` puts its attachment
const ATTACHED = Vector3.new(1, 12, 3)

-- a template under an attachment standing at ATTACHED, unturned
const function attached(attributes: { [string]: any }): BasePart
  const _, part = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
  const attachment = harness.make("Attachment", part) :: Attachment

  -- lune works out no world frame for an attachment, so it is written
  attachment.WorldCFrame = CFrame.new(ATTACHED)

  return template(attachment, attributes)
end

-- a Frames folder of `count` frames under `part`, the part naming its key
const function frameSet(part: BasePart, key: string, count: number)
  const folder = harness.make("Folder", part)

  folder.Name = "Frames"
  folder:SetAttribute("FrameSet", key)
  folder:SetAttribute("UnionSize", Vector3.new(2, 2, 2))
  folder:SetAttribute("UnionCenter", Vector3.zero)
  part:SetAttribute("FrameSet", key)

  for index = 1, count do
    const frame = harness.make("MeshPart", folder) :: any

    frame.Name = tostring(index)
    frame:SetAttribute("FrameSize", Vector3.new(1, 2, 2))
    frame:SetAttribute("FrameCenter", Vector3.zero)
    harness.make("SurfaceAppearance", frame)
  end
end

const function frames(count: number)
  for _ = 1, count do
    scheduler.frame(FRAME)
  end
end

-- what `read` gives of each piece in `spawned` on the frame it spawned, over
-- `count` frames
const function asSpawned(spawned: { BasePart }, count: number, read: (piece: BasePart) -> any): { any }
  const seen = {}

  for _ = 0, count do
    for i = #seen + 1, #spawned do
      seen[i] = read(spawned[i])
    end

    frames(1)
  end

  return seen
end

-- the writes a piece's property takes over `count` frames, and the last value
-- read before the piece went with its life
const function watched(piece: BasePart, name: string, count: number): (number, any)
  local writes, last = 0, (piece :: any)[name]

  for _ = 1, count do
    frames(1)

    const ok, now = pcall(function()
      return (piece :: any)[name]
    end)

    if not ok then
      break
    end

    if now ~= last then
      writes += 1
      last = now
    end
  end

  return writes, last
end

const function near1(a: number, b: number)
  return math.abs(a - b) < EPSILON
end

const function near(a: Vector3, b: Vector3, epsilon: number)
  return (a - b).Magnitude < epsilon
end

const function pieces(fake: fake_pool.Fake): { BasePart }
  return fake.folder:GetChildren() :: any
end

const function finite(cframe: CFrame)
  for _, x in { cframe:GetComponents() } do
    if x ~= x or math.abs(x) == math.huge then
      return false
    end
  end

  return true
end

-- the live piece cap lowered to `max` for as long as `body` runs
const function capped(max: number, body: () -> ())
  const census = forge_mesh.pieces
  const was = census.max

  census.max = max
  census.live = 0

  const ok, err = pcall(body)

  census.max = was

  if not ok then
    error(err, 0)
  end
end

-- the stored rows of `part` replaced by `rows` for as long as `body` runs; lune
-- refuses a non utf-8 attribute string, so a curve is stubbed in, not set
const function stubbed(part: BasePart, rows: { [string]: any }, body: () -> ())
  reader.source = function(inst: Instance)
    const map = table.clone(reader.defaultSource(inst))

    if inst == part then
      for name, row in rows do
        map[name] = row
      end
    end

    return map
  end

  const ok, err = pcall(body)

  reader.source = reader.defaultSource

  if not ok then
    error(err, 0)
  end
end

-- a curve of `channels` from keys given as { time, value, envelope? }
const function curveOf(channels: number, keys: { { any } }, linked: boolean?)
  const made = value_curve.flat(1, channels)

  made.linked = linked ~= false
  made.keys = {}

  for i, key in keys do
    made.keys[i] = {
      time = key[1],
      value = key[2],
      envelope = key[3] or 0,
      left = table.create(channels, vector.zero),
      right = table.create(channels, vector.zero),
    }
  end

  return value_curve.encode(made)
end

-- a template with `rows` stubbed in, one piece of a second's life standing
-- where it spawned
const function lived(rows: { [string]: any }, attributes: { [string]: any }?, body: (piece: BasePart, env: any) -> ())
  staged(function(fake)
    const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
    const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1) })

    for name, value in attributes or {} do
      part:SetAttribute(name, value)
    end

    part.Size = Vector3.new(2, 2, 2)

    stubbed(part, rows, function()
      const env = effects.emit(0, part)

      body(pieces(fake)[1], env)
      env:Clear()
    end)
  end)
end

const function tagged(roots: { Instance }): { Instance }
  const found = {}

  for _, root in roots do
    for _, inst in root:GetDescendants() do
      if inst:HasTag(utility.FORGE_MESH_TAG) then
        table.insert(found, inst)
      end
    end
  end

  return found
end

-- an Instance row's live read and the probe that unwraps it, lune storing no
-- instance in an attribute: a handle is a table naming its target. the row
-- is ForceTarget unless `row` names another, and a part naming no Force is
-- then pulled by Gravity
const function targeting(part: BasePart, target: Instance, body: () -> (), row: string?)
  const live, probe = reader.liveOf, reader.probe
  const named = row or "ForceTarget"

  if named == "ForceTarget" and part:GetAttribute("Force") == nil then
    part:SetAttribute("Force", "Gravity")
  end

  reader.liveOf = function(ref: Instance, name: string)
    return if ref == part and name == named then { handle = true, target = target } else live(ref, name)
  end

  reader.probe = table.freeze({
    kind = function(v: any)
      return if type(v) == "table" and v.handle then "InstanceHandle" else typeof(v)
    end,
    get = function(v: any)
      return v.target
    end,
    alive = function()
      return true
    end,
    isA = function(inst: Instance, class: string)
      return inst:IsA(class)
    end,
  }) :: any

  const ok, err = pcall(body)

  reader.liveOf, reader.probe = live, probe

  if not ok then
    error(err, 0)
  end
end

-- whether a target counts as in the game, answered by `open` for as long as
-- `body` runs
const function reachable(open: () -> boolean, body: () -> ())
  const real = forge_mesh.engine.alive

  forge_mesh.engine.alive = open

  const ok, err = pcall(body)

  forge_mesh.engine.alive = real

  if not ok then
    error(err, 0)
  end
end

-- the world stood in by a floor at y 0 and a parent part's top at y 11 that
-- hits only what its filter leaves in, the filters each ray was cast with
-- kept, put back once `body` ends
const function walled(parent: Instance, body: (filters: { { any } }) -> ())
  const real = collision_common.engine
  const filters = {}

  collision_common.engine = {
    params = function()
      const params = { added = {} }

      function params.AddToFilter(self: any, items: { any })
        for _, item in items do
          table.insert(self.added, item)
        end
      end

      return params :: any
    end,
    tagged = function()
      return {}
    end,
    raycast = function(params: any, from: vector, to: vector)
      table.insert(filters, params.added)

      const wall = if table.find(params.added, parent) == nil then 11 else 0

      if from.y > wall and to.y <= wall then
        const at = from + (to - from) * ((from.y - wall) / (from.y - to.y))

        return { Position = Vector3.new(at.x, at.y, at.z), Normal = Vector3.new(0, 1, 0) } :: any
      end

      return nil
    end,
  }

  const ok, err = pcall(body, filters)

  collision_common.engine = real

  if not ok then
    error(err, 0)
  end
end

-- the world stood in by a floor at y 0 tagged `tag`, hit as a real cast's
-- filter would: an Exclude filter holding the floor and an Include filter
-- lacking it both pass through, put back once `body` ends
const function floored(tag: string, body: () -> ())
  const real = collision_common.engine
  const floor = { Name = "Floor" }

  collision_common.engine = {
    params = function()
      const params = { added = {} }

      function params.AddToFilter(self: any, items: { any })
        for _, item in items do
          table.insert(self.added, item)
        end
      end

      return params :: any
    end,
    tagged = function(name: string)
      return if name == tag then { floor :: any } else {}
    end,
    raycast = function(params: any, from: vector, to: vector)
      const listed = table.find(params.added, floor) ~= nil
      const include = params.FilterType == Enum.RaycastFilterType.Include

      if listed ~= include or not (from.y > 0 and to.y <= 0) then
        return nil
      end

      const at = from + (to - from) * (from.y / (from.y - to.y))

      return { Position = Vector3.new(at.x, at.y, at.z), Normal = Vector3.new(0, 1, 0) } :: any
    end,
  }

  const ok, err = pcall(body)

  collision_common.engine = real

  if not ok then
    error(err, 0)
  end
end

-- a piece falling from y 12 on a template under an attachment, `rows` over it
const function falling(rows: { [string]: any }, body: (piece: BasePart, fake: fake_pool.Fake) -> ())
  framed(function(fake)
    const part = attached(table.clone(rows))

    part:SetAttribute("Acceleration", Vector3.new(0, -20, 0))
    part:SetAttribute("Lifetime", NumberRange.new(3, 3))
    part:SetAttribute("Speed", STILL)

    walled(part.Parent :: Instance, function()
      const env = effects.emit(0, part)

      body(pieces(fake)[1], fake)
      env:Clear()
    end)
  end)
end

-- a state of a mesh's list at `time` of each piece's life, as the template
-- stands, `fields` over it
const function stateOf(time: number, fields: { [string]: any }?): any
  const state = {
    time = time,
    easing = curves.linear(),
    position = vector.zero,
    rotation = vector.zero,
    spin = vector.zero,
    size = vector.one,
    color = Color3.new(1, 1, 1),
    transparency = 0,
    reflectance = 0,
    material = "Plastic",
    materialVariant = "",
    decals = {},
  }

  for name, v in fields or {} do
    state[name] = v
  end

  return state
end

-- a piece rising 10 studs along the template's own y over its life as it
-- fades out
const RISE = {
  stateOf(0),
  stateOf(1, { position = vector.create(0, 10, 0), transparency = 1 }),
}

-- one States piece of two seconds' life on a template under an attachment,
-- set apart from it and turned on its own z so its axes are not the world's,
-- moving through `list`, `attributes` over it and `dress` giving the template
-- its children
const function stated(
  attributes: { [string]: any },
  list: { any },
  body: (piece: BasePart, part: BasePart) -> (),
  dress: ((part: BasePart) -> ())?
)
  framed(function(fake)
    const part = attached(attributes)

    part:SetAttribute("Motion", "States")
    part:SetAttribute("Lifetime", NumberRange.new(2, 2))
    part.CFrame = CFrame.new(4, 5, 6) * CFrame.fromOrientation(0, 0, math.rad(90))

    if dress ~= nil then
      dress(part)
    end

    -- lune refuses a non utf-8 attribute string, so the list is stubbed in
    stubbed(part, { States = state_list.encode(list :: any) }, function()
      const env = effects.emit(0, part)

      body(pieces(fake)[1], part)
      env:Clear()
    end)
  end)
end

-- the frame a `stated` piece's states are posed in: where it spawned, the
-- attachment, turned as its template is
const function spawnedOn(part: BasePart): CFrame
  return CFrame.new(ATTACHED) * part.CFrame.Rotation
end

-- the turn a rig gives a `stated` template's parent after it was placed
const TURN = CFrame.fromOrientation(0, math.rad(90), 0)

-- a `stated` template measured against its unturned attachment, as the
-- plugin stores it, and the attachment turned by TURN after
const function placedThenTurned(part: BasePart)
  const attachment = part.Parent :: Attachment

  part:SetAttribute("ParentTurn", parent_turn.measure(attachment.WorldCFrame, part.CFrame))
  attachment.WorldCFrame = CFrame.new(ATTACHED) * TURN
end

-- the heights of one States piece of two seconds' life, spawned at ATTACHED
-- on an unturned template and moving through `list` under `rows`, once a
-- frame over its life, between walls across the world's y that each turn back
-- a ray crossing them against their `normal`: -1 a ceiling, 1 a floor, and
-- `dress` giving the template what rows cannot
const function walledStates(
  rows: { [string]: any },
  list: { any },
  walls: { { y: number, normal: number } },
  dress: ((part: BasePart) -> ())?
): { Vector3 }
  const real = collision_common.engine
  const seen = {}

  collision_common.engine = {
    params = function()
      return { AddToFilter = function() end } :: any
    end,
    tagged = function()
      return {}
    end,
    raycast = function(_, from: vector, to: vector)
      local nearest = nil
      local share = math.huge

      for _, wall in walls do
        const crosses = if wall.normal < 0
          then from.y < wall.y and to.y >= wall.y
          else from.y > wall.y and to.y <= wall.y
        const reached = if crosses then (wall.y - from.y) / (to.y - from.y) else math.huge

        if reached < share then
          nearest, share = wall, reached
        end
      end

      if nearest == nil then
        return nil
      end

      const at = from + (to - from) * share

      return { Position = Vector3.new(at.x, at.y, at.z), Normal = Vector3.new(0, nearest.normal, 0) } :: any
    end,
  }

  const ok, err = pcall(framed, function(fake)
    const part = attached(rows)

    part:SetAttribute("Motion", "States")
    part:SetAttribute("Lifetime", NumberRange.new(2, 2))
    part:SetAttribute("Speed", STILL)

    if dress ~= nil then
      dress(part)
    end

    stubbed(part, { States = state_list.encode(list :: any) }, function()
      const env = effects.emit(0, part)
      const piece = pieces(fake)[1]

      for k = 1, 119 do
        frames(1)
        seen[k] = piece.CFrame.Position
      end

      env:Clear()
    end)
  end)

  collision_common.engine = real

  if not ok then
    error(err, 0)
  end

  return seen
end

-- states that carry a piece 10 studs up over its life, and `side` studs
-- along x
const function climb(side: number): { any }
  return {
    stateOf(0),
    stateOf(1, { position = vector.create(side, 10, 0) }),
  }
end

-- a ceiling 5 studs above ATTACHED, met half way through a climb
const CEILING = { { y = 17, normal = -1 } }

-- a parent part turned off the world's axes
const TURNED = CFrame.new(0, 10, 0) * CFrame.fromOrientation(0, math.rad(30), math.rad(20))

-- the States pieces of one emit off a part of `size` at TURNED, the template
-- aligned with it and moving through `list`, or else one state 10 studs up its
-- own y, each handed with the frame it spawned at
const function launched(
  attributes: { [string]: any },
  size: Vector3,
  body: (spawns: { { piece: BasePart, spawn: CFrame } }, part: BasePart, parent: BasePart) -> (),
  list: { any }?
)
  framed(function()
    const _, parent = parentPart(TURNED, size)
    const part = template(parent, { Motion = "States", Speed = STILL, Lifetime = NumberRange.new(2, 2) })

    for name, v in attributes do
      part:SetAttribute(name, v)
    end

    part.CFrame = parent.CFrame

    const spawn = particle_motion.spawn
    const drawn: { CFrame } = {}

    particle_motion.spawn = function(...)
      const cframe = spawn(...)

      table.insert(drawn, cframe)

      return cframe
    end

    const states = list or { stateOf(0, { position = vector.create(0, 10, 0) }) }

    const ok, err = pcall(spawning, function(spawned)
      stubbed(part, { States = state_list.encode(states :: any) }, function()
        const env = effects.emit(0, part)

        frames(1)
        expect(#spawned).toBe(#drawn)

        const spawns = {}

        for i, piece in spawned do
          spawns[i] = { piece = piece, spawn = drawn[i] }
        end

        body(spawns, part, parent)
        env:Clear()
      end)
    end)

    particle_motion.spawn = spawn

    if not ok then
      error(err, 0)
    end
  end)
end

-- where a path piece's parent part stands
const PARENT = CFrame.new(0, 10, 0)

-- a path straight down the spawn's look vector, 20 studs long
const DROP = {
  { position = vector.zero },
  { position = vector.create(0, 0, -20) },
} :: any

-- whether a piece has left the world, or its pool has let it go
const function gone(piece: BasePart)
  const ok, parent = pcall(function()
    return piece.Parent
  end)

  return not ok or parent == nil
end

-- the frame a piece spawns at off a point emitter at `origin`, launching out
-- of its `face`
const function spawnAt(origin: CFrame, face: string): CFrame
  return particle_motion.spawn(origin, Vector3.zero, {
    shape = "Box",
    surface = false,
    partial = 1,
    normal = (Enum.NormalId :: any)[face],
    face = "Outward",
    spread = vector.zero,
  }, Random.new())
end

-- the world point `u` of the way along `curve` laid as drawn from `spawn`
const function freeAt(curve: any, spawn: CFrame, u: number): Vector3
  const drawn = path_curve.drawn(curve)
  const frame, scale = path_curve.place(drawn, "Free", spawn, nil, vector.zero, vector.zero, "AsDrawn", 0)
  const at = path_curve.at(Bezier.new(path_curve.points(curve)), drawn, frame, scale, u)

  return Vector3.new(at.x, at.y, at.z)
end

-- `way`, given in `curve`'s drawn frame, in the world once the curve is laid
-- as drawn from `spawn`
const function freeWay(curve: any, spawn: CFrame, way: Vector3): Vector3
  const drawn = path_curve.drawn(curve)
  const frame = path_curve.place(drawn, "Free", spawn, nil, vector.zero, vector.zero, "AsDrawn", 0)

  return frame:VectorToWorldSpace(way).Unit
end

-- the way `curve` laid as drawn from `spawn` runs `u` of the way along it
const function freeTangent(curve: any, spawn: CFrame, u: number): Vector3
  return (freeAt(curve, spawn, u + 1e-3) - freeAt(curve, spawn, u - 1e-3)).Unit
end

-- the most degrees a piece's up vector stands off `way` over the next
-- `count` frames
const function turnedOff(piece: BasePart, way: Vector3, count: number)
  local worst = 0

  for _ = 1, count do
    frames(1)

    worst = math.max(worst, math.deg(math.acos(math.clamp(piece.CFrame.UpVector:Dot(way), -1, 1))))
  end

  return worst
end

-- one Path piece of two seconds' life walking `curve`, on a template under a
-- part at PARENT of `opts.size` (a point unless given), held a second past
-- its motion, `attributes` over it and `opts.rows` stubbed beside the path;
-- `opts.wrap` runs the emit inside whatever it stands in
const function pathed(
  attributes: { [string]: any },
  curve: any,
  body: (piece: BasePart, part: BasePart, parent: BasePart) -> (),
  opts: {
    size: Vector3?,
    rows: { [string]: any }?,
    wrap: ((part: BasePart, parent: BasePart, run: () -> ()) -> ())?,
  }?
)
  const given = opts or {}

  framed(function(fake)
    const _, parent = parentPart(PARENT, given.size or Vector3.zero)
    const part = template(parent, {
      Motion = "Path",
      Speed = STILL,
      Lifetime = NumberRange.new(2, 2),
      DestroyDelay = 1,
    })

    for name, v in attributes do
      part:SetAttribute(name, v)
    end

    const rows = table.clone(given.rows or {})

    -- lune refuses a non utf-8 attribute string, so the path is stubbed in
    rows.Path = path_curve.encode(curve)

    const function run()
      stubbed(part, rows, function()
        const env = effects.emit(0, part)

        body(pieces(fake)[1], part, parent)
        env:Clear()
      end)
    end

    if given.wrap ~= nil then
      given.wrap(part, parent, run)
    else
      run()
    end
  end)
end

-- `run` with an EndPoint part at `position` that counts as in the game while
-- `open` answers true, handed to `made`
const function endingAt(position: Vector3, made: (goal: BasePart) -> (), open: (() -> boolean)?)
  return function(part: BasePart, parent: BasePart, run: () -> ())
    const goal = harness.make("Part", parent) :: BasePart

    goal.Position = position
    made(goal)

    reachable(open or function()
      return true
    end, function()
      targeting(part, goal, run, "EndPoint")
    end)
  end
end

-- a decal named `name` on `part`
const function decalOn(part: BasePart, name: string): Decal
  const decal = harness.make("Decal", part) :: Decal

  decal.Name = name

  return decal
end

const function nearColor(a: Color3, b: Color3)
  return math.abs(a.R - b.R) < LOOSE and math.abs(a.G - b.G) < LOOSE and math.abs(a.B - b.B) < LOOSE
end

-- the template's rows as an emit reads them, its force card's beside its own
const function rowsOf(part: BasePart): any
  const ctx = { ref = part, obj = part, effect = forge_mesh }
  const rows = table.clone((reader.resolve(forge_mesh :: any, ctx :: any)))

  for name, track in force_rows.resolve(ctx :: any, part) do
    rows[name] = track
  end

  return rows
end

-- every row and group a hidden rule hides on `part`, by row name or group
-- title, the force card's rows read as that card reads them
const function hiddenOf(part: BasePart): { [string]: boolean }
  const ctx = { ref = part, obj = part, effect = forge_mesh }
  const attrs, props = reader.resolve(forge_mesh :: any, ctx :: any)
  const forces = force_rows.resolve(ctx :: any, part)
  const hidden: { [string]: boolean } = {}

  for _, set in { { forge_mesh.attributes, attrs, props }, { force_rows.rows, forces, {} } } do
    const rows, read, also = set[1], set[2], set[3]

    for name, row in rows do
      if row.hiddenRule ~= nil then
        hidden[name] = row.hiddenRule(ctx, read, also) == true
      end

      if row.readonlyRule ~= nil then
        row.readonlyRule(ctx, read, also)
      end
    end
  end

  const function walk(entries: { any })
    for _, entry in entries do
      if type(entry) ~= "table" or entry.entries == nil then
        continue
      end

      if entry.hidden ~= nil then
        hidden[entry.title] = entry.hidden(ctx, attrs, props) == true
      end

      walk(entry.entries)
    end
  end

  walk(forge_mesh.layout)
  walk(forge_mesh.cards.Flipbook)

  return hidden
end

harness.suite(function()
  harness.describe("a mesh's pieces", function()
    test("an emit spawns EmitCount pieces inside the parent part", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        template(parent, { EmitCount = 5, Shape = "Box", ShapeStyle = "Volume", Speed = STILL })

        const env = effects.emit(0, parent:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(5)

        for _, piece in list do
          const at = parent.CFrame:PointToObjectSpace(piece.CFrame.Position)

          expect(math.abs(at.X) <= 2 + EPSILON).toBe(true)
          expect(math.abs(at.Y) <= 1 + EPSILON).toBe(true)
          expect(math.abs(at.Z) <= 2 + EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("no piece carries the tag", function()
      staged(function(fake)
        const root, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        -- a template with children is cloned whole rather than taken from a stack
        harness.make("SpecialMesh", part)
        part:AddTag(utility.ENABLED_VFX_TAG)
        part:SetAttribute("Rate", 5)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const found = tagged({ root, fake.folder })

        expect(#pieces(fake)).toBe(3)
        expect(#found).toBe(1)
        expect(found[1]).toBe(part)

        for _, piece in pieces(fake) do
          expect(#piece:GetTags()).toBe(0)
          expect(next(piece:GetAttributes())).toBe(nil)
        end

        env:Clear()
      end)
    end)

    test("an attachment parent spawns at the attachment", function()
      staged(function(fake)
        const _, part = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const attachment = harness.make("Attachment", part) :: Attachment

        -- lune works out no world frame for an attachment, so it is written
        attachment.WorldCFrame = CFrame.new(1, 12, 3)

        template(attachment, { EmitCount = 4, SpreadAngle = Vector3.new(30, 30, 0), Speed = STILL })

        const env = effects.emit(0, attachment:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(4)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(1, 12, 3)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("a States piece stands and fades where its list puts it at half its life", function()
      stated({}, RISE, function(piece, part)
        frames(60)

        const want = state_list.pose(spawnedOn(part), vector.create(0, 5, 0), vector.zero).Position

        expect(near(piece.CFrame.Position, want, LOOSE)).toBe(true)

        -- within one write step of the half way fade
        expect(math.abs(piece.Transparency - 0.5) <= 0.02 + EPSILON).toBe(true)
      end)
    end)

    test("a States piece spawns on its parent part's shape, wherever the template sits", function()
      framed(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Motion = "States", Lifetime = NumberRange.new(2, 2), Shape = "Box" })

        part.CFrame = CFrame.new(40, 0, -30)

        stubbed(part, { States = state_list.encode({ stateOf(0) } :: any) }, function()
          const env = effects.emit(0, part)

          frames(1)

          const at = parent.CFrame:PointToObjectSpace(pieces(fake)[1].CFrame.Position)

          expect(math.abs(at.X) <= 2 + LOOSE and math.abs(at.Y) <= 1 + LOOSE and math.abs(at.Z) <= 2 + LOOSE).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("a States piece ignores the flight rows", function()
      stated({ Speed = NumberRange.new(50, 50), Acceleration = Vector3.new(0, -100, 0) }, RISE, function(piece, part)
        frames(60)

        const want = state_list.pose(spawnedOn(part), vector.create(0, 5, 0), vector.zero).Position

        expect(near(piece.CFrame.Position, want, LOOSE)).toBe(true)
      end)
    end)

    test("a States piece leaves Rotation and RotSpeed out of its pose", function()
      const rows = { Rotation = Vector3.new(0, 45, 0), RotSpeed = Vector3.new(0, 90, 0) }

      stated(rows, { stateOf(0) }, function(piece, part)
        frames(30)

        expect(near(piece.CFrame.Position, ATTACHED, LOOSE)).toBe(true)
        expect(near(piece.CFrame.LookVector, part.CFrame.LookVector, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, part.CFrame.UpVector, LOOSE)).toBe(true)
      end)
    end)

    test("SpreadAngle 0 on a Box face leaves a States pose unchanged", function()
      const rows = { Shape = "Box", ShapeStyle = "Surface", EmissionDirection = "Top", EmitCount = 5 }

      launched(rows, Vector3.new(4, 2, 4), function(spawns, part)
        for _, launch in spawns do
          const want = CFrame.new(launch.spawn.Position) * part.CFrame.Rotation * CFrame.new(0, 10, 0)
          const got = launch.piece.CFrame

          expect(near(got.Position, want.Position, EPSILON)).toBe(true)
          expect(near(got.LookVector, want.LookVector, EPSILON)).toBe(true)
          expect(near(got.UpVector, want.UpVector, EPSILON)).toBe(true)
        end
      end)
    end)

    test("Face Outward on a Sphere turns a state along the spawn normal", function()
      const rows = { Shape = "Sphere", ShapeStyle = "Surface", EmissionDirection = "Top", EmitCount = 20 }

      launched(rows, Vector3.new(4, 4, 4), function(spawns, _, parent)
        expect(#spawns).toBe(20)

        for _, launch in spawns do
          const at = launch.spawn.Position
          const outward = (at - parent.CFrame.Position).Unit

          expect((launch.piece.CFrame.Position - at).Unit:Dot(outward) > 0.999).toBe(true)
        end
      end)
    end)

    test("Face Inward flips it", function()
      const rows = {
        Shape = "Sphere",
        ShapeStyle = "Surface",
        ShapeFace = "Inward",
        EmissionDirection = "Top",
        EmitCount = 20,
      }

      launched(rows, Vector3.new(4, 4, 4), function(spawns, _, parent)
        expect(#spawns).toBe(20)

        for _, launch in spawns do
          const at = launch.spawn.Position
          const outward = (at - parent.CFrame.Position).Unit

          expect((launch.piece.CFrame.Position - at).Unit:Dot(outward) < -0.999).toBe(true)
        end
      end)
    end)

    test("SpreadAngle tilts the states in a cone", function()
      const rows = {
        Shape = "Box",
        ShapeStyle = "Surface",
        EmissionDirection = "Top",
        SpreadAngle = Vector3.new(30, 30, 0),
        EmitCount = 50,
      }

      launched(rows, Vector3.new(4, 2, 4), function(spawns, _, parent)
        expect(#spawns).toBe(50)

        const normal = parent.CFrame.UpVector
        local tilted = false

        for _, launch in spawns do
          const rise = (launch.piece.CFrame.Position - launch.spawn.Position).Unit
          const angle = math.deg(math.acos(math.clamp(rise:Dot(normal), -1, 1)))

          expect(angle <= 30 * math.sqrt(2) + 1e-3).toBe(true)

          if angle > 1 then
            tilted = true
          end
        end

        expect(tilted).toBe(true)
      end)
    end)

    test("a randomized offset gives each piece its own place", function()
      const rows = { Shape = "Box", ShapeStyle = "Surface", EmissionDirection = "Top", EmitCount = 20 }
      const list = {
        stateOf(0, {
          positionOffset = vector.zero,
          random = { state = { positionOffset = { start = vector.zero, finish = vector.create(4, 0, 0) } } },
        }),
      }

      launched(rows, Vector3.new(4, 2, 4), function(spawns, _, parent)
        expect(#spawns).toBe(20)

        local low, high = math.huge, -math.huge

        for _, launch in spawns do
          const offset = parent.CFrame:VectorToObjectSpace(launch.piece.CFrame.Position - launch.spawn.Position)

          expect(offset.X >= -EPSILON and offset.X <= 4 + EPSILON).toBe(true)
          expect(math.abs(offset.Y) < EPSILON and math.abs(offset.Z) < EPSILON).toBe(true)
          low = math.min(low, offset.X)
          high = math.max(high, offset.X)
        end

        expect(high - low > 1).toBe(true)
      end, list)
    end)

    test("a mesh with no randomizers draws as before", function()
      const function drawn(count: number)
        const rows = { Shape = "Box", ShapeStyle = "Surface", EmissionDirection = "Top", EmitCount = count }

        return counted(function()
          launched(rows, Vector3.new(4, 2, 4), function() end)
        end)
      end

      -- measured on the runtime before any piece drew its own states
      expect((drawn(4) - drawn(1)) / 3).toBe(PIECE_DRAWS)
    end)

    test("a piece's draw holds across states", function()
      const red, blue = Color3.new(1, 0, 0), Color3.new(0, 0, 1)
      const random = { state = { color = { finish = blue } } }
      const list = {
        stateOf(0, { color = red, random = random }),
        stateOf(1, { color = red, random = random }),
      }

      -- the alpha along red to blue nearest `c`, and how far off that blend it is
      const function alphaOf(c: Color3): (number, number)
        const lab = color.toOklab(c)
        local best, off = 0, math.huge

        for step = 0, 1000 do
          const gap = (color.toOklab(color.blend(red, blue, step / 1000)) - lab).Magnitude

          if gap < off then
            best, off = step / 1000, gap
          end
        end

        return best, off
      end

      stated({}, list, function(piece)
        const early, earlyOff = alphaOf(piece.Color)

        frames(110)

        const late, lateOff = alphaOf(piece.Color)

        expect(earlyOff < LOOSE and lateOff < LOOSE).toBe(true)
        expect(early > 0.001).toBe(true)
        expect(math.abs(early - late) <= 0.002).toBe(true)
      end)
    end)

    test("a pooled piece draws again on its next life", function()
      const list = {
        stateOf(0, {
          positionOffset = vector.zero,
          random = { state = { positionOffset = { start = vector.zero, finish = vector.create(4, 4, 4) } } },
        }),
      }

      const lists = { Part = { "Color", "Size", "Transparency", "Material", "Anchored", "CanCollide", "Locked" } }

      seeding(function()
        framed(function(fake)
          const part = attached({ Motion = "States", Lifetime = NumberRange.new(2, 2) })

          spawning(function(spawned)
            stubbed(part, { States = state_list.encode(list :: any) }, function()
              const env = effects.emit(0, part)

              frames(1)

              const was = spawned[1].CFrame.Position - ATTACHED

              env:Clear()
              frames(1)

              const again = effects.emit(0, part)

              frames(1)

              const now = spawned[2].CFrame.Position - ATTACHED

              expect(fake.stable(spawned[2]) == fake.stable(spawned[1])).toBe(true)
              expect(near(was, now, LOOSE)).toBe(false)
              again:Clear()
            end)
          end)
        end, lists)
      end)
    end)

    test("FacingCamera places a piece where None does and faces it to the camera", function()
      const camera = workspace.CurrentCamera
      const before = camera.CFrame
      const eye = Vector3.new(30, 40, 50)

      camera.CFrame = CFrame.lookAt(eye, Vector3.zero)

      const function placedUnder(mode: string)
        const rows = {
          Shape = "Sphere",
          ShapeStyle = "Surface",
          EmissionDirection = "Top",
          SpreadAngle = Vector3.new(20, 20, 0),
          StateOrientation = mode,
          EmitCount = 10,
        }

        const out = {}
        const spawn = particle_motion.spawn
        local drawn = 0

        -- the shape draws an unseeded point from a generator of its own
        particle_motion.spawn = function(origin: CFrame, size: Vector3, config: any, rng: Random)
          drawn += 1

          return spawn(origin, size, config, rng, drawn)
        end

        const ok, err = pcall(seeding, function()
          launched(rows, Vector3.new(4, 4, 4), function(spawns)
            for i, launch in spawns do
              out[i] = launch.piece.CFrame
            end
          end)
        end)

        particle_motion.spawn = spawn

        if not ok then
          error(err, 0)
        end

        return out
      end

      const ok, err = pcall(function()
        const still = placedUnder("None")
        const facing = placedUnder("FacingCamera")

        expect(#facing).toBe(10)
        expect(#still).toBe(10)

        for i, cf in facing do
          expect(near(cf.Position, still[i].Position, EPSILON)).toBe(true)
          expect(cf.LookVector:Dot((eye - cf.Position).Unit) > 0.999).toBe(true)
        end
      end)

      camera.CFrame = before

      if not ok then
        error(err, 0)
      end
    end)

    test("a FacingCamera piece follows the camera and not its template's turn", function()
      const camera = workspace.CurrentCamera
      const before = camera.CFrame
      const list = { stateOf(0, { rotation = vector.create(0, 0, 0.5) }) }

      camera.CFrame = CFrame.new(0, 0, 50)

      const function drawnOn(yaw: number)
        local drawn: CFrame? = nil

        stated({ StateOrientation = "FacingCamera" }, list, function(piece)
          const function faces(from: Vector3)
            return piece.CFrame.LookVector:Dot((from - piece.CFrame.Position).Unit) > 0.999
          end

          expect(faces(Vector3.new(0, 0, 50))).toBe(true)
          frames(1)
          drawn = piece.CFrame

          camera.CFrame = CFrame.new(50, 0, 0) * CFrame.fromOrientation(0, math.rad(90), 0)
          frames(1)
          expect(faces(Vector3.new(50, 0, 0))).toBe(true)
          camera.CFrame = CFrame.new(0, 0, 50)
        end, function(part)
          part.CFrame = CFrame.new(4, 5, 6) * CFrame.fromOrientation(0, yaw, 0)
        end)

        return drawn :: CFrame
      end

      const ok, err = pcall(function()
        const straight = drawnOn(0)
        const turned = drawnOn(math.rad(40))

        expect(near(straight.LookVector, turned.LookVector, EPSILON)).toBe(true)
        expect(near(straight.UpVector, turned.UpVector, EPSILON)).toBe(true)
      end)

      camera.CFrame = before

      if not ok then
        error(err, 0)
      end
    end)

    test("an unset StateOrientation reads None", function()
      const rows = { Shape = "Sphere", ShapeStyle = "Surface", EmissionDirection = "Top", EmitCount = 5 }

      launched(rows, Vector3.new(4, 4, 4), function(spawns, part, parent)
        expect(rowsOf(part).StateOrientation).toBe("None")

        for _, launch in spawns do
          const turn = particle_motion.launchTurn(launch.spawn, parent.CFrame, Enum.NormalId.Top)
          const want = CFrame.new(launch.spawn.Position) * turn * part.CFrame.Rotation * CFrame.new(0, 10, 0)
          const got = launch.piece.CFrame

          expect(near(got.Position, want.Position, EPSILON)).toBe(true)
          expect(near(got.LookVector, want.LookVector, EPSILON)).toBe(true)
          expect(near(got.UpVector, want.UpVector, EPSILON)).toBe(true)
        end
      end)
    end)

    test("a state's size scales a FileMesh template's mesh, never its part", function()
      const function meshed(part: BasePart)
        const mesh = harness.make("SpecialMesh", part) :: SpecialMesh

        mesh.MeshType = Enum.MeshType.FileMesh
        mesh.Scale = Vector3.new(1, 2, 3)
        part.Size = Vector3.new(2, 2, 2)
      end

      stated({}, { stateOf(0, { size = vector.create(2, 2, 2) }) }, function(piece)
        frames(1)

        const mesh = piece:FindFirstChildOfClass("SpecialMesh") :: SpecialMesh

        expect(near(mesh.Scale, Vector3.new(2, 4, 6), EPSILON)).toBe(true)
        expect(near(piece.Size, Vector3.new(2, 2, 2), EPSILON)).toBe(true)
      end, meshed)
    end)

    test("a state sets a decal by its name, the others keeping the template's own", function()
      const function decaled(part: BasePart)
        decalOn(part, "Base").Transparency = 0.3
        decalOn(part, "Glow").Transparency = 0
      end

      stated({}, { stateOf(0, { decals = { Glow = { transparency = 0.5 } } }) }, function(piece)
        frames(1)

        expect(near1((piece:FindFirstChild("Glow") :: Decal).Transparency, 0.5)).toBe(true)
        expect(near1((piece:FindFirstChild("Base") :: Decal).Transparency, 0.3)).toBe(true)
      end, decaled)
    end)

    test("a Color glow multiplies a state's decal color by its strength", function()
      const function glowing(part: BasePart)
        decalOn(part, "Glow"):SetAttribute("GlowMode", "Color")
      end

      const glow = { glowStrength = 2, color = Color3.new(0.5, 0.25, 0.1) }

      stated({}, { stateOf(0, { decals = { Glow = glow } }) }, function(piece)
        frames(1)

        const decal = piece:FindFirstChild("Glow") :: Decal

        expect(nearColor(decal.Color3, Color3.new(1, 0.5, 0.2))).toBe(true)
      end, glowing)
    end)

    test("a Color glow with no color in the state lights the decal's own", function()
      const function glowing(part: BasePart)
        const decal = decalOn(part, "Glow")

        decal:SetAttribute("GlowMode", "Color")
        decal.Color3 = Color3.new(0.5, 0.25, 0.1)
      end

      stated({}, { stateOf(0, { decals = { Glow = { glowStrength = 2 } } }) }, function(piece)
        frames(1)

        const decal = piece:FindFirstChild("Glow") :: Decal

        expect(nearColor(decal.Color3, Color3.new(1, 0.5, 0.2))).toBe(true)
      end, glowing)
    end)

    test("a Color glow no state names is lit by the template decal's own strength", function()
      const function glowing(part: BasePart)
        const decal = decalOn(part, "Glow")

        decal:SetAttribute("GlowMode", "Color")
        decal:SetAttribute("GlowStrength", 3)
        decal.Color3 = Color3.new(0.2, 0.1, 0.3)
      end

      stated({}, { stateOf(0), stateOf(1, { transparency = 1 }) }, function(piece)
        frames(1)

        const decal = piece:FindFirstChild("Glow") :: Decal

        expect(nearColor(decal.Color3, Color3.new(0.6, 0.3, 0.9))).toBe(true)
      end, glowing)
    end)

    test("an authored Transparency reads as authored under states, which still play the piece", function()
      const authored = value_curve.encode(value_curve.flat(0.7, 1))

      framed(function(fake)
        const part = attached({})

        part:SetAttribute("Motion", "States")
        part:SetAttribute("Lifetime", NumberRange.new(2, 2))

        stubbed(part, { States = state_list.encode(RISE :: any), Transparency = authored }, function()
          const rows = rowsOf(part)

          expect(near1(value_curve.at(rows.Transparency.value, 0.5)[1], 0.7)).toBe(true)

          const env = effects.emit(0, part)

          frames(1)
          expect(pieces(fake)[1].Transparency < 0.1).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("a state's surface multiplies the surface the piece wears", function()
      const function surfaced(part: BasePart)
        (harness.make("SurfaceAppearance", part) :: any).Color = Color3.new(1, 1, 1)
      end

      stated({}, { stateOf(0, { surface = { color = Color3.new(0.5, 0.5, 0.5) } }) }, function(piece)
        frames(1)

        const worn = piece:FindFirstChildOfClass("SurfaceAppearance") :: any

        expect(nearColor(worn.Color, Color3.new(0.5, 0.5, 0.5))).toBe(true)
      end, surfaced)
    end)

    test("a Kill hit ends a States piece early", function()
      const real = collision_common.engine

      collision_common.engine = {
        params = function()
          return { AddToFilter = function() end } :: any
        end,
        tagged = function()
          return {}
        end,
        raycast = function(_, _, to: vector)
          return { Position = Vector3.new(to.x, to.y, to.z), Normal = Vector3.new(0, 1, 0) } :: any
        end,
      }

      -- a launch of no speed, so only the states move the piece into the hit
      const ok, err = pcall(stated, { CollisionMode = "Kill", Speed = STILL }, RISE, function(piece)
        frames(10)

        expect(piece.Parent).toBe(nil)
      end)

      collision_common.engine = real

      if not ok then
        error(err, 0)
      end
    end)

    test("a pinned FacingCamera piece holds its place and still faces the camera", function()
      const real = collision_common.engine
      const camera = workspace.CurrentCamera
      const before = camera.CFrame

      collision_common.engine = {
        params = function()
          return { AddToFilter = function() end } :: any
        end,
        tagged = function()
          return {}
        end,
        raycast = function(_, _, to: vector)
          return { Position = Vector3.new(to.x, to.y, to.z), Normal = Vector3.new(0, 1, 0) } :: any
        end,
      }

      camera.CFrame = CFrame.new(0, 0, 50)

      const rows = { CollisionMode = "Stop", StateOrientation = "FacingCamera", Speed = STILL }
      const ok, err = pcall(stated, rows, RISE, function(piece)
        frames(10)

        const pinned = piece.CFrame.Position
        const eye = Vector3.new(50, 0, 0)

        camera.CFrame = CFrame.lookAt(eye, pinned)
        frames(10)

        expect(near(piece.CFrame.Position, pinned, EPSILON)).toBe(true)
        expect(piece.CFrame.LookVector:Dot((eye - pinned).Unit) > 0.999).toBe(true)
      end)

      collision_common.engine = real
      camera.CFrame = before

      if not ok then
        error(err, 0)
      end
    end)

    test("a Bounce mirrors a States piece's climb back down from the ceiling it meets", function()
      const seen = walledStates({ CollisionMode = "Bounce", Bounce = 1, Friction = 0 }, climb(0), CEILING)

      -- the ceiling is met at frame 60, so frame 60 + k is frame 60 - k
      -- turned back, less the surface offset
      for k = 1, 58 do
        const up, down = seen[60 - k], seen[60 + k]

        expect(near(down, up - Vector3.new(0, 0.01, 0), LOOSE)).toBe(true)
      end

      -- no jump at the hit past one frame's climb and the surface offset
      for k = 2, 119 do
        expect((seen[k] - seen[k - 1]).Magnitude <= 5 * FRAME + 0.01 + LOOSE).toBe(true)
      end

      expect(seen[119].Y < 12.2).toBe(true)
    end)

    test("a Bounce of 0.5 halves how far a States piece goes back out", function()
      const seen = walledStates({ CollisionMode = "Bounce", Bounce = 0.5, Friction = 0 }, climb(0), CEILING)

      for k = 1, 58 do
        const up, down = seen[60 - k], seen[60 + k]
        const want = 17 - 0.01 - (17 - up.Y) * 0.5

        expect(math.abs(down.Y - want) < LOOSE).toBe(true)
      end
    end)

    test("a Friction of 1 stops a bounced States piece along the surface", function()
      const kept = walledStates({ CollisionMode = "Bounce", Bounce = 1, Friction = 0 }, climb(10), CEILING)
      const lost = walledStates({ CollisionMode = "Bounce", Bounce = 1, Friction = 1 }, climb(10), CEILING)
      const hit = lost[60]

      expect(math.abs(hit.X - (ATTACHED.X + 5)) < LOOSE).toBe(true)
      expect(math.abs(kept[119].X - (ATTACHED.X + 10 * 119 / 120)) < LOOSE).toBe(true)

      for k = 61, 119 do
        expect(math.abs(lost[k].X - hit.X) < LOOSE).toBe(true)
        expect(math.abs(lost[k].Y - kept[k].Y) < LOOSE).toBe(true)
      end
    end)

    test("a Stop still pins a States piece at the ceiling it meets", function()
      const seen = walledStates({ CollisionMode = "Stop" }, climb(0), CEILING)

      for k = 60, 119 do
        expect(near(seen[k], Vector3.new(ATTACHED.X, 17, ATTACHED.Z), LOOSE)).toBe(true)
      end
    end)

    test("a States piece bounces again off a second surface its mirrored path meets", function()
      const list = { stateOf(0), stateOf(1, { position = vector.create(0, 20, 0) }) }
      const walls = { { y = 17, normal = -1 }, { y = 14, normal = 1 } }
      const seen = walledStates({ CollisionMode = "Bounce", Bounce = 1, Friction = 0 }, list, walls)

      local turns = 0
      local rising = true

      for k = 2, 119 do
        const y = seen[k].Y

        expect(y <= 17 + LOOSE).toBe(true)

        if k > 30 then
          expect(y >= 14 - LOOSE).toBe(true)
        end

        if (y > seen[k - 1].Y) ~= rising then
          rising = not rising
          turns += 1
        end
      end

      -- up into the ceiling, down to the floor and back up, at least
      expect(turns >= 2).toBe(true)
    end)

    test("a bounced States piece keeps its mirror through a lock and bounces again once let go", function()
      const list = { stateOf(0), stateOf(1, { position = vector.create(0, 20, 0) }) }

      -- a ceiling met at 0.3 s while free, a floor crossed at 0.9 s while
      -- locked and a floor met at 1.3 s once let go
      const walls = { { y = 15, normal = -1 }, { y = 9, normal = 1 }, { y = 5, normal = 1 } }

      -- the lock takes hold at 0.6 s and lets go at 1 s
      const function locking(part: BasePart)
        stepped(part, "LockedToPart", { false, false, true, false }, 0.4)
      end

      const rows = { CollisionMode = "Bounce", Bounce = 1, Friction = 0 }
      const seen = walledStates(rows, list, walls, locking)

      -- never a jump past one frame's move and the surface offset, at the
      -- bounces, the lock or the release
      for k = 2, 119 do
        expect((seen[k] - seen[k - 1]).Magnitude <= 10 * FRAME + 0.01 + LOOSE).toBe(true)
      end

      -- still mirrored down through the floor it crossed while locked
      expect(seen[60].Y < 9).toBe(true)
      expect(seen[60].Y < seen[54].Y).toBe(true)

      -- and turned back up by the floor it met once free
      for k = 2, 119 do
        expect(seen[k].Y >= 5 - LOOSE).toBe(true)
      end

      expect(seen[119].Y > seen[90].Y + 1).toBe(true)
    end)

    test("a States piece reads Bounce where its row stands at the hit", function()
      -- Bounce falls from 1 to 0 over the life, so it is 0.5 at the hit
      const function falling(part: BasePart)
        tweened(part, "Bounce", 1, 0)
      end

      const seen = walledStates({ CollisionMode = "Bounce", Friction = 0 }, climb(0), CEILING, falling)

      for k = 1, 58 do
        const want = 17 - 0.01 - (17 - seen[60 - k].Y) * 0.5

        expect(math.abs(seen[60 + k].Y - want) < LOOSE).toBe(true)
      end
    end)

    test("a States piece locked to its parent never bounces", function()
      const seen =
        walledStates({ CollisionMode = "Bounce", Bounce = 1, Friction = 0, LockedToPart = true }, climb(0), CEILING)

      expect(seen[119].Y > 21.8).toBe(true)
    end)

    test("a locked FacingCamera piece faces the camera after its parent turns", function()
      const camera = workspace.CurrentCamera
      const before = camera.CFrame
      const eye = Vector3.new(0, 10, 60)

      camera.CFrame = CFrame.lookAt(eye, Vector3.new(0, 10, 0))

      const ok, err = pcall(staged, function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {
          Motion = "States",
          StateOrientation = "FacingCamera",
          LockedToPart = true,
          Speed = STILL,
          Lifetime = NumberRange.new(2, 2),
        })

        stubbed(part, { States = state_list.encode(RISE :: any) }, function()
          const env = effects.emit(0, part)

          frames(10)

          parent.CFrame = CFrame.new(0, 10, 0) * CFrame.fromOrientation(0, math.rad(90), math.rad(30))
          frames(1)

          const piece = pieces(fake)[1]
          const at = piece.CFrame.Position

          expect(piece.CFrame.LookVector:Dot((eye - at).Unit) > 0.999).toBe(true)
          env:Clear()
        end)
      end)

      camera.CFrame = before

      if not ok then
        error(err, 0)
      end
    end)

    test("a parent turned since the template was placed turns its states about the spawn", function()
      stated({}, RISE, function(piece, part)
        frames(60)

        const offset = TURN:VectorToWorldSpace(part.CFrame.Rotation:VectorToWorldSpace(Vector3.new(0, 5, 0)))

        expect(near(piece.CFrame.Position, ATTACHED + offset, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, (TURN * part.CFrame.Rotation).UpVector, EPSILON)).toBe(true)
        expect(near(piece.CFrame.LookVector, (TURN * part.CFrame.Rotation).LookVector, EPSILON)).toBe(true)
      end, placedThenTurned)
    end)

    test("a template with no ParentTurn keeps its own world turn under a turned parent", function()
      stated({}, RISE, function(piece, part)
        frames(60)

        const want = state_list.pose(spawnedOn(part), vector.create(0, 5, 0), vector.zero)

        expect(near(piece.CFrame.Position, want.Position, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, want.UpVector, EPSILON)).toBe(true)
      end, function(part)
        (part.Parent :: Attachment).WorldCFrame = CFrame.new(ATTACHED) * TURN
      end)
    end)

    test("a missing or unmoved ParentTurn poses a piece byte-identical to today", function()
      const function poses(dress: ((part: BasePart) -> ())?): { { number } }
        const seen = {}

        seeding(function()
          stated({ EmitCount = 1 }, RISE, function(piece)
            for i = 1, 5 do
              frames(12)
              seen[i] = { piece.CFrame:GetComponents() }
            end
          end, dress)
        end)

        return seen
      end

      const today = poses(nil)

      -- placed against the parent as it stands, then read back a hair off, as
      -- float32 keeps it
      const placed = poses(function(part)
        part:SetAttribute("ParentTurn", parent_turn.measure(CFrame.new(ATTACHED), part.CFrame))
      end)
      const drifted = poses(function(part)
        const hair = CFrame.fromOrientation(2e-7, -3e-7, 1e-7)

        part:SetAttribute("ParentTurn", hair * parent_turn.measure(CFrame.new(ATTACHED), part.CFrame))
      end)

      for i, components in today do
        for k, x in components do
          expect(placed[i][k]).toBe(x)
          expect(drifted[i][k]).toBe(x)
        end
      end
    end)

    test("a locked States piece follows a parent turned mid-life, turn and all", function()
      stated({ LockedToPart = true }, RISE, function(piece, part)
        frames(59)

        const attachment = part.Parent :: Attachment

        attachment.WorldCFrame = CFrame.new(ATTACHED) * TURN
        frames(1)

        const offset = TURN:VectorToWorldSpace(part.CFrame.Rotation:VectorToWorldSpace(Vector3.new(0, 5, 0)))

        expect(near(piece.CFrame.Position, ATTACHED + offset, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, (TURN * part.CFrame.Rotation).UpVector, EPSILON)).toBe(true)
      end, function(part)
        part:SetAttribute("ParentTurn", parent_turn.measure(CFrame.new(ATTACHED), part.CFrame))
      end)
    end)

    test("a Particle mesh under Orientation None wears its parent's turn", function()
      framed(function(fake)
        const part = attached({ Speed = STILL, Orientation = "None" })

        part.CFrame = CFrame.new(4, 5, 6) * CFrame.fromOrientation(0, 0, math.rad(90))
        placedThenTurned(part)

        const env = effects.emit(0, part)

        frames(1)

        const piece = pieces(fake)[1]
        const want = TURN * part.CFrame.Rotation

        expect(near(piece.CFrame.UpVector, want.UpVector, EPSILON)).toBe(true)
        expect(near(piece.CFrame.LookVector, want.LookVector, EPSILON)).toBe(true)
        env:Clear()
      end)
    end)

    test("a template with no part or attachment above it spawns at its own pose", function()
      staged(function(fake)
        const root = harness.make("Folder")
        const part = template(root, { EmitCount = 2, Shape = "Sphere", Speed = STILL })

        part.CFrame = CFrame.new(5, 6, 7)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(2)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(5, 6, 7)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("pieces are released when their life ends", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3, Lifetime = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        scheduler.frame(0.25)
        expect(#pieces(fake)).toBe(3)

        scheduler.frame(0.3)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("a piece takes its transparency from the row, not the template", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        part.Transparency = 1

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(3)

        for _, piece in list do
          expect(piece.Transparency).toBe(0)
        end

        env:Clear()
      end)
    end)

    test("a piece's size is the template's times the Size curve", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const size = value_curve.flat(1, 3)

        size.linked = false
        size.keys[1].value = { 2, 3, 4 }

        const part = template(parent, {})
        const encoded = value_curve.encode(size)

        part.Size = Vector3.new(2, 2, 2)

        -- lune refuses a non utf-8 attribute string, so the stored map is stubbed
        reader.source = function(inst: Instance)
          const map = table.clone(reader.defaultSource(inst))

          if inst == part then
            map.Size = encoded
          end

          return map
        end

        const ok, err = pcall(function()
          const env = effects.emit(0, part)
          const list = pieces(fake)

          expect(#list).toBe(1)
          expect(list[1].Size).toBe(Vector3.new(4, 6, 8))

          env:Clear()
        end)

        reader.source = reader.defaultSource

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("Size follows its curve per axis", function()
      lived({ Size = curveOf(3, { { 0, { 1, 1, 1 } }, { 1, { 2, 1, 3 } } }, false) }, nil, function(piece)
        frames(30)

        expect(near(piece.Size, Vector3.new(3, 2, 4), LOOSE)).toBe(true)
      end)
    end)

    test("Squash stretches up and narrows the rest as an emitter does", function()
      lived({ Squash = curveOf(1, { { 0, { 1 } } }) }, nil, function(piece)
        frames(1)

        expect(near(piece.Size, Vector3.new(1, 4, 1), LOOSE)).toBe(true)
      end)
    end)

    test("Transparency follows its curve, within one write step", function()
      lived({ Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }) }, { DestroyDelay = 1 }, function(piece)
        frames(30)

        expect(math.abs(piece.Transparency - 0.5) < 0.02 + LOOSE).toBe(true)
      end)
    end)

    test("a slow Transparency ramp writes far fewer times than frames and ends exact", function()
      const attributes = { DestroyDelay = 1, Lifetime = NumberRange.new(4, 4) }

      lived({ Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }) }, attributes, function(piece)
        const writes, last = watched(piece, "Transparency", 250)

        expect(writes < 240 / 3).toBe(true)
        expect(last).toBe(1)
      end)
    end)

    test("a curve that reaches an interior key and holds there is written exact as it stops", function()
      const keys = { { 0, { 0 } }, { 0.5, { 1 } }, { 1, { 1 } } }

      lived({ Transparency = curveOf(1, keys) }, { DestroyDelay = 1, Lifetime = NumberRange.new(2, 2) }, function(piece)
        -- 0.5 of a 2 s life, and a frame past it to see the curve stop
        frames(62)

        expect(piece.Transparency).toBe(1)
      end)

      lived({ Size = curveOf(3, { { 0, { 1, 1, 1 } }, { 0.5, { 2, 2, 2 } }, { 1, { 2, 2, 2 } } }) }, {
        DestroyDelay = 1,
        Lifetime = NumberRange.new(2, 2),
      }, function(piece)
        frames(62)

        expect(piece.Size == Vector3.new(4, 4, 4)).toBe(true)
      end)
    end)

    test("a Transparency change under the step writes at most once before the end lands it", function()
      lived({ Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 0.015 } } }) }, { DestroyDelay = 1 }, function(piece)
        const early = watched(piece, "Transparency", 40)

        expect(early <= 1).toBe(true)

        const _, last = watched(piece, "Transparency", 30)

        expect(near1(last, 0.015)).toBe(true)
      end)
    end)

    test("drift past the step writes, measured from the last write", function()
      lived({ Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 0.1 } } }) }, { DestroyDelay = 1 }, function(piece)
        const writes, last = watched(piece, "Transparency", 70)

        expect(writes >= 4 and writes <= 7).toBe(true)
        expect(near1(last, 0.1)).toBe(true)
      end)
    end)

    test("pieces spawned together cross their write steps on many different frames", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(4, 4), EmitCount = 100 })

        stubbed(part, { Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }) }, function()
          const env = effects.emit(0, part)
          const list = pieces(fake)
          const last = {}
          const perFrame = {}

          expect(#list).toBe(100)

          for index, piece in list do
            last[index] = piece.Transparency
          end

          for frame = 1, 230 do
            frames(1)

            for index, piece in list do
              if piece.Transparency ~= last[index] then
                last[index] = piece.Transparency
                perFrame[frame] = (perFrame[frame] or 0) + 1
              end
            end
          end

          local busiest, busy = 0, 0

          for _, count in perFrame do
            busiest = math.max(busiest, count)
            busy += 1
          end

          expect(busiest <= 40).toBe(true)
          expect(busy >= 200).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("the first frame writes whatever the value", function()
      lived({ Transparency = curveOf(1, { { 0, { 0.005 } }, { 1, { 0.01 } } }) }, nil, function(piece)
        expect(near1(piece.Transparency, 0.005)).toBe(true)
      end)
    end)

    test("Size steps are relative, so a small piece still follows small changes", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1), DestroyDelay = 1 })

        part.Size = Vector3.new(0.1, 0.1, 0.1)

        stubbed(part, { Size = curveOf(3, { { 0, { 1, 1, 1 } }, { 1, { 1.05, 1.05, 1.05 } } }) }, function()
          const env = effects.emit(0, part)
          const piece = pieces(fake)[1]
          const writes, last = watched(piece, "Size", 70)

          expect(writes >= 2 and writes <= 5).toBe(true)
          expect(near(last, Vector3.new(0.105, 0.105, 0.105), EPSILON)).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("a Transparency above one is written as it is", function()
      lived({ Transparency = curveOf(1, { { 0, { 1.5 } }, { 1, { 2.5 } } }) }, { DestroyDelay = 1 }, function(piece)
        expect(piece.Transparency).toBe(1.5)

        const _, last = watched(piece, "Transparency", 70)

        expect(last).toBe(2.5)
      end)
    end)

    test("Color follows its gradient", function()
      const red, blue = Color3.new(1, 0, 0), Color3.new(0, 0, 1)
      const gradient = ColorSequence.new(red, blue)

      lived({}, { Color = gradient }, function(piece)
        expect(piece.Color).toBe(red)

        frames(30)

        expect(piece.Color.R < 1 and piece.Color.R > 0).toBe(true)
        expect(piece.Color.B < 1 and piece.Color.B > 0).toBe(true)
      end)
    end)

    test("an envelope draws once per piece", function()
      seeding(function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 2, Speed = STILL, Lifetime = NumberRange.new(1, 1) })

          part.Size = Vector3.new(2, 2, 2)

          stubbed(part, { Size = curveOf(3, { { 0, { 1, 1, 1 }, 0.5 } }) }, function()
            const env = effects.emit(0, part)
            const list = pieces(fake)
            const first = list[1].Size

            frames(5)

            expect(list[1].Size).toBe(first)
            expect(list[1].Size ~= list[2].Size).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a Size tween over the effect gives pieces spawned later bigger curves", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1), EmitDuration = 1, Rate = 4 })

        part.Size = Vector3.new(2, 2, 2)
        tweened(part, "Size", value_curve.encode(value_curve.flat(1, 3)), value_curve.encode(value_curve.flat(2, 3)))

        spawning(function(spawned)
          const env = effects.emit(0, part)
          const sizes = asSpawned(spawned, 66, function(piece: BasePart)
            return piece.Size.X
          end)

          expect(#sizes >= 3).toBe(true)
          expect(near1(sizes[1], 2)).toBe(true)

          for i = 2, #sizes do
            expect(sizes[i] > sizes[i - 1] + 0.1).toBe(true)
          end

          expect(sizes[#sizes] > 3).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("a curve modifier endpoint that is no curve of its row's width plays the row's default", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1) })
        const narrow = value_curve.encode(value_curve.flat(3, 1))

        part.Size = Vector3.new(2, 2, 2)
        tweened(part, "Size", narrow, narrow)
        tweened(part, "Transparency", "no curve", "no curve")

        const warnings = harness.captureWarnings(function()
          const env = effects.emit(0, part)
          const piece = pieces(fake)[1]

          frames(30)

          expect(near(piece.Size, Vector3.new(2, 2, 2), EPSILON)).toBe(true)
          expect(piece.Transparency).toBe(0)

          env:Clear()
        end)

        const said = table.concat(warnings, "\n")

        expect(string.find(said, "Size has a modifier value", 1, true) ~= nil).toBe(true)
        expect(string.find(said, "Transparency has a modifier value", 1, true) ~= nil).toBe(true)
      end)
    end)

    test("a Transparency randomizer gives two pieces different curves", function()
      seeding(function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 2, Speed = STILL, Lifetime = NumberRange.new(1, 1) })
          const clear, opaque = value_curve.flat(0, 1), value_curve.flat(1, 1)

          randomized(part, "Transparency", value_curve.encode(clear), value_curve.encode(opaque))

          const env = effects.emit(0, part)
          const list = pieces(fake)

          expect(#list).toBe(2)

          const a, b = list[1].Transparency, list[2].Transparency

          expect(math.abs(a - b) > EPSILON).toBe(true)
          expect(a >= 0 and a <= 1 and b >= 0 and b <= 1).toBe(true)
          env:Clear()
        end)
      end)
    end)

    test("a Color tween over the effect blends the gradient pieces spawn with", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1), EmitDuration = 1, Rate = 4 })
        const red, blue = Color3.new(1, 0, 0), Color3.new(0, 0, 1)

        tweened(part, "Color", ColorSequence.new(red), ColorSequence.new(blue))

        spawning(function(spawned)
          const env = effects.emit(0, part)
          const colors = asSpawned(spawned, 66, function(piece: BasePart)
            return piece.Color
          end)

          expect(#colors >= 3).toBe(true)
          expect(colors[1]).toBe(red)

          for i = 2, #colors do
            expect(colors[i].R < colors[i - 1].R and colors[i].B > colors[i - 1].B).toBe(true)
          end

          env:Clear()
        end)
      end)
    end)

    test("pinned appearance rows blend nothing and play their curves", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const red, blue = Color3.new(1, 0, 0), Color3.new(0, 0, 1)
        const part = template(parent, {
          EmitCount = 3,
          Speed = STILL,
          Lifetime = NumberRange.new(1, 1),
          DestroyDelay = 1,
          Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, red), ColorSequenceKeypoint.new(1, blue) }),
        })
        const curves, sequences = lerp.ValueCurve, lerp.ColorSequence

        local blends = 0

        part.Size = Vector3.new(2, 2, 2)

        lerp.ValueCurve = function(...)
          blends += 1
          return curves(...)
        end

        lerp.ColorSequence = function(...)
          blends += 1
          return sequences(...)
        end

        const ok, err = pcall(stubbed, part, {
          Size = curveOf(3, { { 0, { 1, 1, 1 } }, { 1, { 2, 2, 2 } } }),
          Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }),
        }, function()
          const env = effects.emit(0, part)
          const list = pieces(fake)

          expect(#list).toBe(3)

          -- halfway, within the steps a write waits for
          frames(30)

          for _, piece in list do
            expect(near(piece.Size, Vector3.new(3, 3, 3), 0.1)).toBe(true)
            expect(math.abs(piece.Transparency - 0.5) < 0.05).toBe(true)
            expect(piece.Color.R < 1 and piece.Color.B > 0).toBe(true)
          end

          -- past the life, held exactly at the curves' ends
          frames(40)

          for _, piece in list do
            expect(piece.Size).toBe(Vector3.new(4, 4, 4))
            expect(piece.Transparency).toBe(1)
            expect(piece.Color).toBe(blue)
          end

          env:Clear()
        end)

        lerp.ValueCurve, lerp.ColorSequence = curves, sequences

        if not ok then
          error(err, 0)
        end

        expect(blends).toBe(0)
      end)
    end)

    test("FacingCamera points at the camera", function()
      const camera = workspace.CurrentCamera
      const before = camera.CFrame

      camera.CFrame = CFrame.new(0, 10, 50)

      lived({}, { Orientation = "FacingCamera" }, function(piece)
        frames(2)

        expect(near(piece.CFrame.LookVector, (Vector3.new(0, 10, 50) - piece.CFrame.Position).Unit, LOOSE)).toBe(true)
      end)

      camera.CFrame = before
    end)

    test("VelocityPerpendicular turns along the flight", function()
      staged(function(fake)
        const part = attached({ Speed = NumberRange.new(10, 10), Orientation = "VelocityPerpendicular" })
        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(2)

        const at = piece.CFrame.Position

        frames(2)

        const heading = (piece.CFrame.Position - at).Unit

        expect(near(piece.CFrame.LookVector, heading, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("degenerate rows do not produce NaN", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.zero)
        const part = template(parent, {
          EmitCount = 4,
          -- a short life, so the spin steps, then the destroy delay
          Lifetime = NumberRange.new(0.05, 0.05),
          DestroyDelay = 0.1,
          ShapeStyle = "Surface",
          SpreadAngle = Vector3.new(180, 180, 0),
          Drag = 1e308,
          Orientation = "VelocityPerpendicular",
          RotSpeed = Vector3.new(1e308, 1e308, 1e308),
          Rotation = Vector3.new(1, 1, 1),
        })

        effects.emit(0, part)

        const list = pieces(fake)

        expect(#list).toBe(4)

        for _, piece in list do
          expect(finite(piece.CFrame)).toBe(true)
          expect(piece.Size == piece.Size).toBe(true)
        end

        scheduler.frame(1 / 60)

        for _, piece in list do
          expect(finite(piece.CFrame)).toBe(true)
          expect(piece.Size == piece.Size).toBe(true)
        end

        scheduler.frame(0.1)
        scheduler.frame(0.1)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)
  end)

  harness.describe("a mesh's flight", function()
    test("a piece flies the particle formula", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          Drag = 0,
          Lifetime = NumberRange.new(1, 1),
        })

        const env = effects.emit(0, part)

        frames(30)

        const list = pieces(fake)
        const start = Vector3.new(1, 12, 3)
        const expected = start + Vector3.new(0, 1, 0) * 10 * 0.5 + Vector3.new(0, -20, 0) * 0.125

        expect(#list).toBe(1)
        expect(near(list[1].CFrame.Position, expected, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a piece oriented None keeps the template's own orientation as it flies", function()
      staged(function(fake)
        const part = attached({ Speed = NumberRange.new(10, 10), Orientation = "None" })
        const turn = CFrame.fromOrientation(0.3, 1, 0.2)

        part.CFrame = CFrame.new(0, 0, 0) * turn

        const env = effects.emit(0, part)

        frames(10)

        const piece = pieces(fake)[1]

        expect(near(piece.CFrame.LookVector, turn.LookVector, EPSILON)).toBe(true)
        expect(near(piece.CFrame.UpVector, turn.UpVector, EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("WindAffectsDrag carries a piece with the wind", function()
      staged(function(fake)
        const wind = workspace.GlobalWind

        workspace.GlobalWind = Vector3.new(10, 0, 0)

        const ok, err = pcall(function()
          const part = attached({ Speed = STILL, Drag = 2, WindAffectsDrag = true })
          const env = effects.emit(0, part)

          frames(30)

          const piece = pieces(fake)[1]
          const at = piece.CFrame.Position

          -- the position steps on the velocity it had, so one more frame reads it
          frames(1)

          const velocity = (piece.CFrame.Position - at) / FRAME

          expect(at.X > 1).toBe(true)
          expect(near(velocity, Vector3.new(5, 0, 0), LOOSE)).toBe(true)

          env:Clear()
        end)

        workspace.GlobalWind = wind

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("turbulence wanders a piece off its path and stays within its amount", function()
      seeding(function()
        staged(function(fake)
          const part = attached({
            Speed = STILL,
            Turbulence = 2,
            TurbulenceFrequency = 3,
            Lifetime = NumberRange.new(3, 3),
          })
          const env = effects.emit(0, part)
          local farthest = 0

          for _ = 1, 90 do
            frames(1)

            const piece = pieces(fake)[1]
            const away = piece.CFrame.Position - Vector3.new(1, 12, 3)

            farthest = math.max(farthest, away.Magnitude)

            expect(math.abs(away.X) <= 2 + EPSILON).toBe(true)
            expect(math.abs(away.Y) <= 2 + EPSILON).toBe(true)
            expect(math.abs(away.Z) <= 2 + EPSILON).toBe(true)
          end

          expect(farthest > 0.05).toBe(true)

          env:Clear()
        end)
      end)
    end)

    test("a modifier lifting Turbulence from 0 wanders a piece", function()
      for _, range in { { 2, 2 }, { 1, 2 } } do
        seeding(function()
          staged(function(fake)
            const part = attached({
              Speed = STILL,
              Turbulence = 0,
              TurbulenceFrequency = 3,
              Lifetime = NumberRange.new(3, 3),
            })

            randomized(part, "Turbulence", range[1], range[2])

            const env = effects.emit(0, part)
            local farthest = 0

            for _ = 1, 60 do
              frames(1)
              farthest = math.max(farthest, (pieces(fake)[1].CFrame.Position - Vector3.new(1, 12, 3)).Magnitude)
            end

            expect(farthest > 0.05).toBe(true)

            env:Clear()
          end)
        end)
      end
    end)

    test("turbulence starts at the spawn and its first frame moves little", function()
      seeding(function()
        staged(function(fake)
          const part = attached({
            EmitCount = 20,
            Speed = STILL,
            Turbulence = 2,
            TurbulenceFrequency = 3,
            Lifetime = NumberRange.new(3, 3),
          })
          const env = effects.emit(0, part)
          const list = pieces(fake)
          local total = 0

          for _, piece in list do
            expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)
          end

          frames(1)

          for _, piece in list do
            total += (piece.CFrame.Position - Vector3.new(1, 12, 3)).Magnitude
          end

          expect(total / #list < 0.2).toBe(true)

          env:Clear()
        end)
      end)
    end)

    test("turbulence 0 is the plain path", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Turbulence = 0, TurbulenceFrequency = 3 })
        const env = effects.emit(0, part)

        frames(30)

        const piece = pieces(fake)[1]

        expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("LockedToPart carries pieces with the parent", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, LockedToPart = true })
        const env = effects.emit(0, part)

        frames(1)

        const piece = pieces(fake)[1]
        const before = piece.CFrame.Position

        parent.CFrame = CFrame.new(5, 10, 0)

        frames(1)

        expect(near(piece.CFrame.Position - before, Vector3.new(5, 0, 0), EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("a piece whose life ends first leaves the world while the other flies on", function()
      seeding(function()
        staged(function(fake)
          const part = attached({ EmitCount = 2, Lifetime = NumberRange.new(0.5, 2) })
          const env = effects.emit(0, part)
          const list = pieces(fake)
          local elapsed = 0

          expect(#list).toBe(2)

          while #pieces(fake) == 2 and elapsed < 2.5 do
            frames(1)
            elapsed += FRAME
          end

          -- held by the effect to its end, both would leave on the same frame
          expect(#pieces(fake)).toBe(1)

          const gone = if list[1].Parent == nil then list[1] else list[2]
          const flying = if gone == list[1] then list[2] else list[1]

          expect(gone.Parent).toBe(nil)
          expect(flying.Parent ~= nil).toBe(true)

          env:Clear()
        end)
      end)
    end)

    test("Speed is the launch speed, TimeScale the clock", function()
      for _, timeScale in { 1, 0.5 } do
        staged(function(fake)
          const part =
            attached({ Speed = NumberRange.new(20, 20), TimeScale = timeScale, Lifetime = NumberRange.new(1, 1) })

          effects.emit(0, part)

          const piece = pieces(fake)[1]

          frames(30)

          -- half a second of the effect's clock at its own pace
          const elapsed = 0.5 * timeScale

          expect(near(piece.CFrame.Position, Vector3.new(1, 12 + 20 * elapsed, 3), LOOSE)).toBe(true)

          local alive = 30 * FRAME

          while piece.Parent ~= nil and alive < 4 do
            frames(1)
            alive += FRAME
          end

          expect(math.abs(alive - 1 / timeScale) < 2 * FRAME).toBe(true)
        end)
      end
    end)

    test("TimeScale 0 releases pieces", function()
      staged(function(fake)
        const part = attached({ EmitCount = 3, TimeScale = 0, Lifetime = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        frames(2)

        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("RotSpeed spins an axis whose rotation rests at 0", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, RotSpeed = Vector3.new(0, 90, 0), Orientation = "None" })
        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(30)

        -- half a second at 90 degrees per second turns the yaw by 45 alone
        const turned = CFrame.fromOrientation(0, math.rad(45), 0)

        expect(near(piece.CFrame.LookVector, turned.LookVector, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, Vector3.new(0, 1, 0), LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a Rotation randomizer draws per axis per piece", function()
      seeding(function()
        staged(function(fake)
          const part = attached({ EmitCount = 4, Speed = STILL })

          randomized(part, "Rotation", Vector3.zero, Vector3.new(90, 90, 90))

          const env = effects.emit(0, part)
          const list = pieces(fake)
          const seen = {}

          expect(#list).toBe(4)

          for _, piece in list do
            const x, y, z = piece.CFrame:ToOrientation()

            -- every axis draws its own, so no two match
            expect(math.abs(x - y) > EPSILON and math.abs(y - z) > EPSILON).toBe(true)

            for _, other in seen do
              expect(near(piece.CFrame.LookVector, other, EPSILON)).toBe(false)
            end

            table.insert(seen, piece.CFrame.LookVector)
          end

          env:Clear()
        end)
      end)
    end)

    test("a locked piece holds its last pose once the parent is destroyed", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, LockedToPart = true, Lifetime = NumberRange.new(1, 1) })

        part.CFrame = CFrame.new(50, 0, 0)

        const env = effects.emit(0, part)

        frames(1)

        const piece = pieces(fake)[1]
        const before = piece.CFrame.Position

        parent:Destroy()

        frames(2)

        expect(near(piece.CFrame.Position, before, EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("a plain LockedToPart rides the parent as a free piece flies, in the parent's frame", function()
      staged(function(fake)
        const start = CFrame.new(0, 10, 0) * CFrame.Angles(0, 0.5, 0)
        const thrust = Vector3.new(3, 0, 1)
        const _, parent = parentPart(start, Vector3.zero)
        const _, still = parentPart(start, Vector3.zero)
        const locked = template(parent, {
          Speed = NumberRange.new(2, 2),
          Lifetime = NumberRange.new(2, 2),
          Acceleration = thrust,
          LockedToPart = true,
        })
        const free = template(still, {
          Speed = NumberRange.new(2, 2),
          Lifetime = NumberRange.new(2, 2),
          Acceleration = start:VectorToWorldSpace(thrust),
        })

        -- a parent of no size launches both pieces from its center alike
        const lockedEnv = effects.emit(0, locked)
        const ridden = pieces(fake)[1]
        const freeEnv = effects.emit(0, free)
        const flown = if pieces(fake)[1] == ridden then pieces(fake)[2] else pieces(fake)[1]
        local worst = 0

        for i = 1, 90 do
          parent.CFrame = start * CFrame.new(i * 0.1, i * 0.05, 0) * CFrame.Angles(0, i * 0.01, 0)
          frames(1)

          const expected = parent.CFrame * start:ToObjectSpace(flown.CFrame)

          worst = math.max(worst, (ridden.CFrame.Position - expected.Position).Magnitude)
        end

        expect(worst < EPSILON).toBe(true)

        lockedEnv:Clear()
        freeEnv:Clear()
      end)
    end)

    test("a tween that frees a locked piece hands it the parent's velocity without a jump", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(2, 2) })

        -- over the effect's 2 s, the lock lets go at 1 s
        tweened(part, "LockedToPart", true, false)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]
        const step = Vector3.new(6, 0, 0) * FRAME
        local x = 0
        local last = piece.CFrame.Position
        local worst = 0

        for _ = 1, 90 do
          x += step.X
          parent.CFrame = CFrame.new(x, 10, 0)
          frames(1)

          const now = piece.CFrame.Position

          worst = math.max(worst, (now - last - step).Magnitude)
          last = now
        end

        expect(worst < LOOSE).toBe(true)

        -- let go, it flies on at the parent's velocity and no longer follows
        parent.CFrame = CFrame.new(x, 20, 0)
        frames(1)

        expect(near(piece.CFrame.Position - last, step, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a tween that locks a free piece grips the parent where it stands, then rides it", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(2, 2) })

        -- over the effect's 2 s, the lock takes hold at 1 s
        tweened(part, "LockedToPart", false, true)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]
        const step = Vector3.new(6, 0, 0) * FRAME
        local x = 0
        local last = piece.CFrame.Position
        local still, riding, worst = 0, 0, 0

        -- a still piece keeps still until the lock grips the moving parent,
        -- then moves with it, never more than one of the parent's steps
        for frame = 1, 90 do
          x += step.X
          parent.CFrame = CFrame.new(x, 10, 0)
          frames(1)

          const moved = piece.CFrame.Position - last

          worst = math.max(worst, moved.Magnitude - step.Magnitude)

          if frame < 55 then
            still = math.max(still, moved.Magnitude)
          elseif frame > 65 then
            riding = math.max(riding, (moved - step).Magnitude)
          end

          last = piece.CFrame.Position
        end

        expect(still < LOOSE).toBe(true)
        expect(riding < LOOSE).toBe(true)
        expect(worst < LOOSE).toBe(true)

        -- and moves with whatever the parent does next
        x += step.X
        parent.CFrame = CFrame.new(x, 20, 0)
        frames(1)

        expect(near(piece.CFrame.Position - last, Vector3.new(step.X, 10, 0), LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a lock and release hands a flying piece back the velocity it had, whatever the parent did", function()
      for _, cycles in { 1, 5 } do
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { Speed = NumberRange.new(3, 3), Lifetime = NumberRange.new(5, 5) })
          const values = { false }

          for _ = 1, cycles do
            table.insert(values, true)
            table.insert(values, false)
          end

          -- each lock and release lands at the middle of its 0.4 s tween,
          -- the first lock at 0.2 s
          stepped(part, "LockedToPart", values, 0.4)

          const env = effects.emit(0, part)
          const piece = pieces(fake)[1]
          local x = 0
          local speed = 6

          const function run(count: number): Vector3
            const from = piece.CFrame.Position

            for _ = 1, count do
              x += speed * FRAME
              parent.CFrame = CFrame.new(x, 10, 0)
              frames(1)
            end

            return (piece.CFrame.Position - from) / (count * FRAME)
          end

          const before = run(10)

          -- held, it rides the parent on top of its own velocity
          run(4)

          expect(near(run(10), before + Vector3.new(6, 0, 0), LOOSE)).toBe(true)

          -- while held, the parent changes its velocity, which the release
          -- hands on as a change since the grip
          if cycles == 1 then
            speed = 9
          end

          -- on past the last release, at 0.8 s a cycle less 0.2 s
          run(math.ceil((0.8 * cycles - 0.2) / FRAME) + 2 - 24)

          const gained = Vector3.new(if cycles == 1 then 3 else 0, 0, 0)

          expect(near(run(10), before + gained, LOOSE)).toBe(true)

          env:Clear()
        end)
      end
    end)
  end)

  harness.describe("a mesh's motion", function()
    test("a target pulls pieces in", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(3, 3), GravityMass = 30000 })
        const goal = harness.make("Part", parent) :: BasePart

        goal.Position = Vector3.new(30, 10, 0)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(1)

            const before = (piece.CFrame.Position - goal.Position).Magnitude

            frames(30)

            expect((piece.CFrame.Position - goal.Position).Magnitude < before - 1).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a destroyed target stops pulling", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(3, 3) })
        const goal = harness.make("Part", parent) :: BasePart
        local open = true

        goal.Position = Vector3.new(30, 10, 0)

        reachable(function()
          return open
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(10)

            open = false

            frames(2)

            const a = piece.CFrame.Position

            frames(1)

            const b = piece.CFrame.Position

            frames(10)

            const c = piece.CFrame.Position

            frames(1)

            const d = piece.CFrame.Position

            expect((b - a).Magnitude > EPSILON).toBe(true)
            expect(near(b - a, d - c, EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a target at the piece adds nothing", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(2, 2), GravitySoftening = 0 })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(1, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)

            frames(20)

            const piece = pieces(fake)[1]

            expect(finite(piece.CFrame)).toBe(true)
            expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a locked piece is pulled toward where the target stands in the world", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(
          parent,
          { Speed = STILL, Lifetime = NumberRange.new(3, 3), LockedToPart = true, GravityMass = 30000 }
        )
        const goal = harness.make("Part") :: BasePart

        goal.Position = Vector3.new(30, 10, 0)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            -- the parent carries the piece past the target before it is pulled
            parent.CFrame = CFrame.new(60, 10, 0)

            frames(1)

            const before = (piece.CFrame.Position - goal.Position).Magnitude

            frames(30)

            expect((piece.CFrame.Position - goal.Position).Magnitude < before - 1).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("an orbit launch at radius 10 stays within 2% of it over five orbits", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(40, 40),
          GravityMass = 1000,
          GravitySoftening = 0,
          OrbitLaunch = true,
        })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(11, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            local lowest, highest = math.huge, 0

            for _ = 1, math.ceil(5 * 2 * math.pi * 60) do
              frames(1)

              const radius = (piece.CFrame.Position - goal.Position).Magnitude

              lowest, highest = math.min(lowest, radius), math.max(highest, radius)
            end

            expect(lowest > 9.8 and highest < 10.2).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("an orbit launch at the center keeps the drawn launch", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(2, 2),
          Force = "Gravity",
          GravityMass = 1,
          OrbitLaunch = true,
        })

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(30)

        -- with no target the force centers on the attachment the piece spawns at
        const moved = piece.CFrame.Position - Vector3.new(1, 12, 3)

        expect(finite(piece.CFrame)).toBe(true)
        expect(moved.Y > 1).toBe(true)

        env:Clear()
      end)
    end)

    test("OrbitLaunchScale shares out the circular speed: below 1 falls in, past 1.41 escapes", function()
      const function flown(scale: number): (number, number)
        local lowest, highest = math.huge, 0

        staged(function(fake)
          const part = attached({
            Speed = NumberRange.new(5, 5),
            Lifetime = NumberRange.new(20, 20),
            GravityMass = 1000,
            GravitySoftening = 0,
            OrbitLaunch = true,
            OrbitLaunchScale = scale,
          })
          const goal = harness.make("Part", part.Parent) :: BasePart

          goal.Position = Vector3.new(11, 12, 3)

          reachable(function()
            return true
          end, function()
            targeting(part, goal, function()
              const env = effects.emit(0, part)
              const piece = pieces(fake)[1]

              -- one orbit at radius 10 takes 2 pi seconds
              for _ = 1, math.ceil(2 * math.pi * 60) do
                frames(1)

                const radius = (piece.CFrame.Position - goal.Position).Magnitude

                lowest, highest = math.min(lowest, radius), math.max(highest, radius)
              end

              env:Clear()
            end)
          end)
        end)

        return lowest, highest
      end

      const circleLow, circleHigh = flown(1)
      const innerLow, innerHigh = flown(0.7)
      const _, outerHigh = flown(1.5)

      expect(circleLow > 9.8 and circleHigh < 10.2).toBe(true)
      expect(innerLow < 9 and innerHigh < 10.2).toBe(true)
      expect(outerHigh > 30).toBe(true)
    end)

    test("a modifier below GravityMass's floor never pushes a piece away", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(2, 2), GravityMass = 1000 })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(11, 12, 3)
        tweened(part, "GravityMass", -30000, -30000)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)

            frames(60)

            expect(near(pieces(fake)[1].CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("an attachment target pulls from where it stands in the world", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(3, 3), GravityMass = 30000 })
        const holder = harness.make("Part", parent)
        const goal = harness.make("Attachment", holder) :: Attachment

        goal.WorldCFrame = CFrame.new(0, 10, 30)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(1)

            const before = piece.CFrame.Position

            frames(30)

            const moved = piece.CFrame.Position - before

            -- the pieces spawn within 2 studs of the axis toward it
            expect(moved.Z > 1).toBe(true)
            expect(math.abs(moved.X) < moved.Z * 0.1 and math.abs(moved.Y) < moved.Z * 0.1).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a model target rings its pieces about its pivot and pivot's up", function()
      staged(function(fake)
        const part = attached({
          Speed = STILL,
          Lifetime = NumberRange.new(4, 4),
          Force = "Orbit",
          OrbitRadius = 5,
          OrbitSpin = 0.5,
          OrbitCapture = 20,
        })
        const goal = harness.make("Model", part.Parent)
        const pivot = forge_mesh.engine.pivot

        -- lune has no GetPivot; the pivot's up runs along x
        forge_mesh.engine.pivot = function(model: Model)
          return if model == goal then CFrame.new(1, 12, 3) * CFrame.Angles(0, 0, -math.pi / 2) else pivot(model)
        end

        const ok, err = pcall(function()
          reachable(function()
            return true
          end, function()
            targeting(part, goal, function()
              const env = effects.emit(0, part)
              const piece = pieces(fake)[1]

              frames(120)

              const offset = piece.CFrame.Position - Vector3.new(1, 12, 3)

              expect(math.abs(offset.X) < LOOSE).toBe(true)
              expect(math.abs(Vector3.new(0, offset.Y, offset.Z).Magnitude - 5) < 0.05).toBe(true)

              env:Clear()
            end)
          end)
        end)

        forge_mesh.engine.pivot = pivot

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("orbit pieces spawned on the axis fill the ring, each at its own angle", function()
      staged(function(fake)
        const part = attached({
          EmitCount = 8,
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(2, 2),
          Force = "Orbit",
          OrbitRadius = 6,
          OrbitSpin = 0.25,
          OrbitCapture = 20,
        })
        const center = Vector3.new(1, 12, 3)

        const env = effects.emit(0, part)

        frames(60)

        const angles = {}

        for _, piece in pieces(fake) do
          const offset = piece.CFrame.Position - center

          table.insert(angles, math.atan2(offset.Z, offset.X))
        end

        expect(#angles).toBe(8)

        for i = 1, #angles do
          for j = i + 1, #angles do
            expect(math.abs(angles[i] - angles[j]) > 1e-3).toBe(true)
          end
        end

        env:Clear()
      end)
    end)

    test("a ring flies the same at 30 and at 144 frames a second", function()
      const function flownAt(rate: number): Vector3
        local at = Vector3.zero

        staged(function(fake)
          const part = attached({
            Speed = STILL,
            Lifetime = NumberRange.new(3, 3),
            Force = "Orbit",
            OrbitRadius = 6,
            OrbitSpin = 0.5,
            OrbitRise = 2,
            OrbitCapture = 3,
          })

          const env = effects.emit(0, part)
          const piece = pieces(fake)[1]

          for _ = 1, 2 * rate do
            scheduler.frame(1 / rate)
          end

          at = piece.CFrame.Position
          env:Clear()
        end)

        return at
      end

      expect(near(flownAt(30), flownAt(144), 1e-3)).toBe(true)
    end)

    test("a radial fall with softening passes through the target and back, never NaN", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(12, 12), GravitySoftening = 1 })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(1, 22, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            local through, back = false, false

            for _ = 1, 600 do
              frames(1)

              expect(finite(piece.CFrame)).toBe(true)

              const y = piece.CFrame.Position.Y

              through = through or y > 30
              back = back or (through and y < 14)
            end

            expect(through).toBe(true)
            expect(back).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a target of mass 0 is the plain path", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          Lifetime = NumberRange.new(1, 1),
          GravityMass = 0,
        })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(30, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)

            frames(30)

            const expected = Vector3.new(1, 12, 3) + Vector3.new(0, 10, 0) * 0.5 + Vector3.new(0, -20, 0) * 0.125

            expect(near(pieces(fake)[1].CFrame.Position, expected, LOOSE)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("Force None leaves a set target alone, the plain path", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          Lifetime = NumberRange.new(1, 1),
          GravityMass = 30000,
          Force = "None",
        })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(30, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)

            frames(30)

            const expected = Vector3.new(1, 12, 3) + Vector3.new(0, 10, 0) * 0.5 + Vector3.new(0, -20, 0) * 0.125

            expect(near(pieces(fake)[1].CFrame.Position, expected, LOOSE)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("OrbitRise climbs a piece on its ring up the target's up axis", function()
      staged(function(fake)
        const part = attached({
          Speed = STILL,
          Lifetime = NumberRange.new(4, 4),
          Force = "Orbit",
          OrbitRadius = 2,
          OrbitSpin = 1,
          OrbitRise = 5,
          OrbitCapture = 3,
        })
        const goal = harness.make("Part", part.Parent) :: BasePart

        -- the piece spawns on the ring, 2 studs out along x
        goal.Position = Vector3.new(-1, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            local turned = 0
            local last = 0

            for _ = 1, 120 do
              frames(1)

              expect(finite(piece.CFrame)).toBe(true)

              const offset = piece.CFrame.Position - goal.Position
              const angle = math.atan2(-offset.Z, offset.X)

              turned += (angle - last + math.pi) % (2 * math.pi) - math.pi
              last = angle
            end

            const offset = piece.CFrame.Position - goal.Position

            expect(math.abs(offset.Y - 10) < LOOSE).toBe(true)
            expect(math.abs(Vector3.new(offset.X, 0, offset.Z).Magnitude - 2) < LOOSE).toBe(true)
            expect(math.abs(turned - 4 * math.pi) < 0.01).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("an orbit from radius 3 settles onto OrbitRadius at OrbitSpin", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(6, 6),
          Force = "Orbit",
          OrbitRadius = 10,
          OrbitSpin = 0.25,
          OrbitCapture = 2,
        })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(-2, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(math.ceil(math.log(70) / 2 * 60) + 1)

            local lowest, highest, turned = math.huge, 0, 0
            local last: number? = nil

            for _ = 1, 120 do
              frames(1)

              const offset = piece.CFrame.Position - goal.Position
              const radius = Vector3.new(offset.X, 0, offset.Z).Magnitude
              const angle = math.atan2(-offset.Z, offset.X)

              lowest, highest = math.min(lowest, radius), math.max(highest, radius)

              if last ~= nil then
                turned += (angle - last + math.pi) % (2 * math.pi) - math.pi
              end

              last = angle

              expect(math.abs(offset.Y) < EPSILON).toBe(true)
            end

            expect(lowest >= 9.9 and highest <= 10.1).toBe(true)
            expect(math.abs(math.deg(turned) - 90 * 119 / 60) < 0.5).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a gone target stops the orbit and the piece flies on as it was", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(3, 3), Force = "Orbit", OrbitRise = 4 })
        const goal = harness.make("Part", part.Parent) :: BasePart
        local open = true

        goal.Position = Vector3.new(-9, 12, 3)

        reachable(function()
          return open
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(20)

            open = false

            frames(2)

            const a = piece.CFrame.Position

            frames(1)

            const b = piece.CFrame.Position

            frames(1)

            const c = piece.CFrame.Position

            expect((b - a).Magnitude > EPSILON).toBe(true)
            expect(near(b - a, c - b, EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("with no target a part emitter's center and up axis are the force's", function()
      staged(function(fake)
        -- turned so its up runs along -x, pieces spawning within 1 stud of the
        -- center that way
        const _, parent = parentPart(CFrame.new(0, 10, 0) * CFrame.Angles(0, 0, math.pi / 2), Vector3.new(4, 2, 4))
        const part = template(parent, {
          Speed = STILL,
          Lifetime = NumberRange.new(6, 6),
          Force = "Orbit",
          OrbitRadius = 10,
          OrbitSpin = 0.25,
          OrbitCapture = 2,
        })

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(1)

        -- the ring sits at the height along the axis the piece spawned at
        const height = -piece.CFrame.Position.X

        frames(180)

        for _ = 1, 30 do
          frames(1)

          const at = piece.CFrame.Position
          const radius = Vector3.new(0, at.Y - 10, at.Z).Magnitude

          expect(math.abs(height) <= 1).toBe(true)
          expect(math.abs(-at.X - height) < LOOSE).toBe(true)
          expect(radius >= 9.9 and radius <= 10.1).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("with no target an attachment emitter's world pose is the ring's center", function()
      staged(function(fake)
        const part = attached({
          Speed = STILL,
          Lifetime = NumberRange.new(4, 4),
          Force = "Orbit",
          OrbitRadius = 6,
          OrbitSpin = 1,
          OrbitRise = 5,
          OrbitCapture = 3,
        })

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(120)

        -- spawned on the axis, drawn out onto the ring as it rises
        const offset = piece.CFrame.Position - Vector3.new(1, 12, 3)

        expect(finite(piece.CFrame)).toBe(true)
        expect(math.abs(offset.Y - 10) < LOOSE).toBe(true)
        expect(math.abs(Vector3.new(offset.X, 0, offset.Z).Magnitude - 6) < 0.06).toBe(true)

        env:Clear()
      end)
    end)

    test("a tween on OrbitRadius over the life widens a piece's ring as it flies", function()
      staged(function(fake)
        const part = attached({
          Speed = STILL,
          Lifetime = NumberRange.new(4, 4),
          Force = "Orbit",
          OrbitSpin = 0.5,
          OrbitRise = 2,
          OrbitCapture = 20,
        })
        const center = Vector3.new(1, 12, 3)

        tweened(part, "OrbitRadius", 2, 10)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        const function radius()
          const offset = piece.CFrame.Position - center

          return Vector3.new(offset.X, 0, offset.Z).Magnitude
        end

        frames(15)

        const early = radius()

        frames(219)

        const late = radius()

        expect(early >= 2 and early <= 3).toBe(true)
        expect(late >= 9.5 and late <= 10.1).toBe(true)

        env:Clear()
      end)
    end)

    test("a randomizer on OrbitRadius gives two pieces their own rings", function()
      seeding(function()
        staged(function(fake)
          const part = attached({
            EmitCount = 2,
            Speed = STILL,
            Lifetime = NumberRange.new(4, 4),
            Force = "Orbit",
            OrbitSpin = 0.5,
            OrbitCapture = 20,
          })
          const center = Vector3.new(1, 12, 3)

          randomized(part, "OrbitRadius", 2, 10)

          const env = effects.emit(0, part)

          frames(90)

          const radii = {}

          for i, piece in pieces(fake) do
            const offset = piece.CFrame.Position - center

            radii[i] = Vector3.new(offset.X, 0, offset.Z).Magnitude
          end

          expect(#radii).toBe(2)
          expect(math.abs(radii[1] - radii[2]) > 0.1).toBe(true)

          for _, r in radii do
            expect(r >= 2 - LOOSE and r <= 10 + LOOSE).toBe(true)
          end

          env:Clear()
        end)
      end)
    end)

    test("a locked orbit with no target rides around its parent wherever it goes", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {
          Speed = STILL,
          Lifetime = NumberRange.new(6, 6),
          LockedToPart = true,
          Force = "Orbit",
          OrbitRadius = 10,
          OrbitSpin = 0.25,
          OrbitCapture = 2,
        })

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(1)

        const height = piece.CFrame.Position.Y

        parent.CFrame = CFrame.new(60, 10, 0)

        frames(180)

        const at = piece.CFrame.Position
        const radius = Vector3.new(at.X - 60, 0, at.Z).Magnitude

        expect(math.abs(at.Y - height) < LOOSE).toBe(true)
        expect(radius >= 9.9 and radius <= 10.1).toBe(true)

        env:Clear()
      end)
    end)

    test("a piece with no target steps as it always did, sub-steps and all", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Acceleration = Vector3.new(3, -20, 1),
          Drag = 1.5,
          Lifetime = NumberRange.new(2, 2),
        })

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        local position = vector.create(1, 12, 3)
        local velocity = vector.create(0, 10, 0)
        local age = 0

        const acceleration = vector.create(3, -20, 1)

        for _, dt in { 1 / 60, 1 / 25, 1 / 90, 1 / 60, 0.2, 1 / 61, 1 / 45, 1 / 60 } do
          scheduler.frame(dt)

          const stepped = math.min(dt, 2 - age)
          const steps = math.clamp(math.ceil(stepped / (1 / 60) - 0.05), 1, 8)
          const h = stepped / steps

          age += stepped

          for _ = 1, steps do
            position, velocity =
              position + velocity * h + acceleration * (0.5 * h * h), (velocity + acceleration * h) * 2 ^ (-1.5 * h)
          end

          expect(near(piece.CFrame.Position, Vector3.new(position.x, position.y, position.z), EPSILON)).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("a piece casts nothing while locked and meets the floor once a tween frees it", function()
      for _, lock in { "plain", "tweened" } do
        framed(function(fake)
          const part = attached({
            CollisionMode = "Stop",
            Acceleration = Vector3.new(0, -4, 0),
            Lifetime = NumberRange.new(4, 4),
            Speed = STILL,
            LockedToPart = true,
          })

          -- over the effect's 4 s the lock lets go at 2 s, 4 studs up, and
          -- the floor is 0.45 s on
          if lock == "tweened" then
            tweened(part, "LockedToPart", true, false)
          end

          walled(part.Parent :: Instance, function(casts)
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(110)

            expect(#casts).toBe(0)

            frames(70)

            if lock == "plain" then
              expect(#casts).toBe(0)
              expect(piece.CFrame.Position.Y < -1).toBe(true)
            else
              expect(#casts > 0).toBe(true)
              expect(math.abs(piece.CFrame.Position.Y) < 0.01).toBe(true)
            end

            env:Clear()
          end)
        end)
      end
    end)

    test("VelocityParallel holds the last flight heading once Stop pins a piece", function()
      falling({ CollisionMode = "Stop", Orientation = "VelocityParallel" }, function(piece)
        frames(30)

        expect(near(piece.CFrame.UpVector, Vector3.new(0, -1, 0), LOOSE)).toBe(true)

        frames(90)

        expect(math.abs(piece.CFrame.Position.Y) < 0.01).toBe(true)
        expect(near(piece.CFrame.UpVector, Vector3.new(0, -1, 0), LOOSE)).toBe(true)
      end)
    end)

    test("Kill ends a piece at the floor", function()
      falling({ CollisionMode = "Kill" }, function(piece)
        local last = piece.CFrame.Position

        for _ = 1, 120 do
          frames(1)

          if piece.Parent == nil then
            break
          end

          last = piece.CFrame.Position
        end

        expect(piece.Parent).toBe(nil)

        -- the frame before the hit, a frame's fall above the floor
        expect(last.Y > 0).toBe(true)
        expect(last.Y < 0.5).toBe(true)
      end)
    end)

    test("Stop pins it", function()
      falling({ CollisionMode = "Stop" }, function(piece)
        frames(90)

        const at = piece.CFrame.Position

        frames(30)

        expect(piece.Parent ~= nil).toBe(true)
        expect(math.abs(at.Y) < 0.01).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)
      end)
    end)

    test("SurfaceAlign Top lays a stopped piece flat over its duration, off the floor by the offset", function()
      const rows = {
        CollisionMode = "Stop",
        Orientation = "VelocityPerpendicular",
        SurfaceAlign = "Top",
        SurfaceAlignDuration = 0.5,
        SurfaceOffset = 0.25,
      }

      falling(rows, function(piece)
        for _ = 1, 120 do
          frames(1)

          if math.abs(piece.CFrame.Position.Y - 0.25) < EPSILON then
            break
          end
        end

        -- it lands as it fell, looking down, and turns from there
        expect(math.abs(piece.CFrame.UpVector.Y) < LOOSE).toBe(true)

        frames(15)

        const halfway = piece.CFrame.UpVector.Y

        expect(halfway > 0.1 and halfway < 0.99).toBe(true)

        frames(30)

        expect(near(piece.CFrame.UpVector, Vector3.new(0, 1, 0), LOOSE)).toBe(true)
        expect(math.abs(piece.CFrame.Position.Y - 0.25) < EPSILON).toBe(true)
      end)
    end)

    test("a killed piece keeps turning onto the floor through its destroy delay", function()
      const rows = {
        CollisionMode = "Kill",
        DestroyDelay = 1,
        Orientation = "VelocityPerpendicular",
        SurfaceAlign = "Front",
        SurfaceAlignDuration = 0.3,
      }

      falling(rows, function(piece)
        frames(120)

        -- it fell looking straight into the floor, so its front turned over
        expect(piece.Parent ~= nil).toBe(true)
        expect(finite(piece.CFrame)).toBe(true)
        expect(near(piece.CFrame.LookVector, Vector3.new(0, 1, 0), LOOSE)).toBe(true)
        expect(math.abs(piece.CFrame.Position.Y) < 0.01).toBe(true)
      end)
    end)

    test("Bounce lifts it back up and a slow bounce stops", function()
      falling({ CollisionMode = "Bounce", Bounce = 0.5, Friction = 0 }, function(piece)
        local landed = false
        local rose = false

        for _ = 1, 100 do
          frames(1)

          if piece.CFrame.Position.Y < 0.5 then
            landed = true
          elseif landed then
            rose = true
          end
        end

        expect(rose).toBe(true)
      end)

      falling({ CollisionMode = "Bounce", Bounce = 0.02 }, function(piece)
        frames(90)

        const at = piece.CFrame.Position

        frames(30)

        expect(math.abs(at.Y) < 0.05).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)
      end)
    end)

    test("Include Tag hits only tagged parts and None hits everything", function()
      -- whether a Kill piece over a floor tagged Ground is gone once it has
      -- fallen past the floor
      const function killed(rows: { [string]: any }, tag: string)
        local gone = false

        framed(function(fake)
          const part = attached(rows)

          part:SetAttribute("CollisionMode", "Kill")
          part:SetAttribute("Acceleration", Vector3.new(0, -20, 0))
          part:SetAttribute("Lifetime", NumberRange.new(3, 3))
          part:SetAttribute("Speed", STILL)

          floored(tag, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(90)

            gone = piece.Parent == nil
            env:Clear()
          end)
        end)

        return gone
      end

      expect(killed({ CollisionFilter = "Include Tag", CollisionFilterTag = "Ground" }, "Ground")).toBe(true)
      expect(killed({ CollisionFilter = "Include Tag", CollisionFilterTag = "Ground" }, "Wall")).toBe(false)
      expect(killed({ CollisionFilter = "Exclude Tag", CollisionFilterTag = "Ground" }, "Ground")).toBe(false)
      expect(killed({ CollisionFilter = "None", CollisionFilterTag = "Ground" }, "Ground")).toBe(true)
      expect(killed({}, "Ground")).toBe(true)
    end)

    test("collision never hits the template or its parent", function()
      framed(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(1, 1),
          ShapeFace = "Inward",
          ShapeStyle = "Surface",
          CollisionMode = "Kill",
        })

        walled(parent, function(filters)
          const env = effects.emit(0, part)

          frames(30)

          expect(pieces(fake)[1].Parent ~= nil).toBe(true)
          expect(#filters > 0).toBe(true)
          expect(table.find(filters[1], parent) ~= nil).toBe(true)
          expect(table.find(filters[1], part) ~= nil).toBe(true)

          env:Clear()
        end)
      end)
    end)
  end)

  harness.describe("a mesh's path", function()
    const TOP = spawnAt(PARENT, "Top")
    const BOTTOM = spawnAt(PARENT, "Bottom")
    const BOX = Vector3.new(4, 2, 4)

    test("a Free path piece follows the drawn curve from its spawn", function()
      pathed({}, path_curve.DEFAULT, function(piece)
        frames(60)

        expect(near(piece.CFrame.Position, freeAt(path_curve.DEFAULT, TOP, 0.5), LOOSE)).toBe(true)
      end)
    end)

    test("Progress paces the piece", function()
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 1 } }, { 1, { 1 } } }) }

      pathed({}, path_curve.DEFAULT, function(piece)
        frames(60)

        expect(near(piece.CFrame.Position, freeAt(path_curve.DEFAULT, TOP, 1), LOOSE)).toBe(true)
      end, { rows = rows })
    end)

    test("a Progress key's band gives each piece of an emit its own pace", function()
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 0.5 }, 0.5 }, { 1, { 1 } } }) }

      spawning(function(spawned)
        pathed({ EmitCount = 2 }, path_curve.DEFAULT, function()
          frames(60)

          expect(#spawned).toBe(2)
          expect(near(spawned[1].CFrame.Position, spawned[2].CFrame.Position, LOOSE)).toBe(false)
        end, { rows = rows })
      end)
    end)

    test("RotSpeed spins a path piece as it walks", function()
      pathed(
        {
          Orientation = "None",
          RotSpeed = Vector3.new(0, 180, 0),
          AfterPath = "Stop",
        },
        path_curve.DEFAULT,
        function(piece)
          const start = piece.CFrame.LookVector

          frames(60)

          expect(near(piece.CFrame.LookVector, -start, LOOSE)).toBe(true)
        end
      )
    end)

    test("Center ends every piece on the emitter's center", function()
      spawning(function(spawned)
        pathed({ PathEnd = "Center", EmitCount = 4 }, path_curve.DEFAULT, function()
          frames(125)

          expect(#spawned).toBe(4)

          for _, piece in spawned do
            expect(near(piece.CFrame.Position, PARENT.Position, LOOSE)).toBe(true)
          end
        end, { size = BOX })
      end)
    end)

    test("EndRadius 3..3 under Center ends 3 studs from the center", function()
      spawning(function(spawned)
        pathed({ PathEnd = "Center", EndRadius = NumberRange.new(3, 3), EmitCount = 4 }, path_curve.DEFAULT, function()
          frames(125)

          for _, piece in spawned do
            expect(math.abs((piece.CFrame.Position - PARENT.Position).Magnitude - 3) < LOOSE).toBe(true)
          end
        end, { size = BOX })
      end)
    end)

    test("Target follows a moving EndPoint", function()
      local goal: BasePart = nil :: any

      pathed({ PathEnd = "Target" }, path_curve.DEFAULT, function(piece)
        frames(60)

        goal.Position += Vector3.new(10, 0, 0)

        frames(65)

        expect(near(piece.CFrame.Position, Vector3.new(30, 10, 0), LOOSE)).toBe(true)
      end, {
        wrap = endingAt(Vector3.new(20, 10, 0), function(made)
          goal = made
        end),
      })
    end)

    test("Target with no EndPoint plays as Free", function()
      pathed({ PathEnd = "Target" }, path_curve.DEFAULT, function(piece)
        frames(60)

        expect(near(piece.CFrame.Position, freeAt(path_curve.DEFAULT, TOP, 0.5), LOOSE)).toBe(true)
      end)
    end)

    test("an EndPoint already gone at emit plays as Free", function()
      pathed({ PathEnd = "Target" }, path_curve.DEFAULT, function(piece)
        frames(60)

        expect(near(piece.CFrame.Position, freeAt(path_curve.DEFAULT, TOP, 0.5), LOOSE)).toBe(true)
      end, {
        wrap = endingAt(Vector3.new(20, 10, 0), function() end, function()
          return false
        end),
      })
    end)

    test("a destroyed EndPoint holds its last pose", function()
      local goal: BasePart = nil :: any
      local open = true

      pathed({ PathEnd = "Target" }, path_curve.DEFAULT, function(piece)
        frames(60)

        open = false
        goal.Position += Vector3.new(10, 0, 0)

        frames(65)

        expect(near(piece.CFrame.Position, Vector3.new(20, 10, 0), LOOSE)).toBe(true)
      end, {
        wrap = endingAt(Vector3.new(20, 10, 0), function(made)
          goal = made
        end, function()
          return open
        end),
      })
    end)

    test("Reverse starts at the end point", function()
      pathed({ PathEnd = "Center", Reverse = true }, path_curve.DEFAULT, function(piece)
        expect(near(piece.CFrame.Position, PARENT.Position, LOOSE)).toBe(true)

        frames(60)

        expect(near(piece.CFrame.Position, PARENT.Position, LOOSE)).toBe(false)
      end, { size = BOX })
    end)

    test("Stop holds the piece at the end and the piece finishes at its path time", function()
      recording(function(lives)
        pathed({ AfterPath = "Stop" }, path_curve.DEFAULT, function(piece)
          expect(lives[piece]).toBe(2)

          frames(150)

          expect(piece.Parent ~= nil).toBe(true)
          expect(near(piece.CFrame.Position, freeAt(path_curve.DEFAULT, TOP, 1), LOOSE)).toBe(true)

          frames(60)

          expect(gone(piece)).toBe(true)
        end)
      end)
    end)

    test("Continue flies on at Speed for FlightTime", function()
      const finish = freeAt(path_curve.DEFAULT, TOP, 1)
      const tangent = (finish - freeAt(path_curve.DEFAULT, TOP, 1 - 1e-4)).Unit

      recording(function(lives)
        pathed(
          {
            AfterPath = "Continue",
            FlightTime = NumberRange.new(1, 1),
            Speed = NumberRange.new(10, 10),
          },
          path_curve.DEFAULT,
          function(piece, part)
            expect(lives[piece]).toBe(3)
            expect(forge_mesh.duration(nil, rowsOf(part))).toBe(3)

            frames(190)

            const flown = piece.CFrame.Position - finish

            expect(math.abs(flown.Magnitude - 10) < 0.05).toBe(true)
            expect(flown.Unit:Dot(tangent) > 0.999).toBe(true)
          end
        )
      end)
    end)

    test("Continue leaves along the end tangent when Progress arrives early and holds", function()
      const finish = freeAt(path_curve.DEFAULT, TOP, 1)
      const tangent = (finish - freeAt(path_curve.DEFAULT, TOP, 1 - 1e-4)).Unit
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 1 } }, { 1, { 1 } } }) }

      pathed(
        {
          AfterPath = "Continue",
          FlightTime = NumberRange.new(1, 1),
          Speed = NumberRange.new(10, 10),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(190)

          const flown = piece.CFrame.Position - finish

          expect(math.abs(flown.Magnitude - 10) < 0.05).toBe(true)
          expect(flown.Unit:Dot(tangent) > 0.999).toBe(true)
        end,
        { rows = rows }
      )
    end)

    test("Continue leaves from where Progress holds short of the end, along the tangent there", function()
      const stopped = freeAt(path_curve.DEFAULT, TOP, 0.5)
      const tangent = (stopped - freeAt(path_curve.DEFAULT, TOP, 0.5 - 1e-4)).Unit
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 0.5 } }, { 1, { 0.5 } } }) }

      pathed(
        {
          AfterPath = "Continue",
          FlightTime = NumberRange.new(1, 1),
          Speed = NumberRange.new(10, 10),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(190)

          const flown = piece.CFrame.Position - stopped

          expect(math.abs(flown.Magnitude - 10) < 0.05).toBe(true)
          expect(flown.Unit:Dot(tangent) > 0.999).toBe(true)
        end,
        { rows = rows }
      )
    end)

    test("Continue leaves along the end tangent when Progress eases into the end", function()
      const finish = freeAt(path_curve.DEFAULT, TOP, 1)
      const tangent = freeWay(path_curve.DEFAULT, TOP, Vector3.new(0, -4, -3))
      const eased = value_curve.decode(curveOf(1, { { 0, { 0 } }, { 1, { 1 } } })) :: value_curve.Curve

      -- fast early, then all but still over the last frames
      eased.keys[1].right = { vector.create(0.2, 1, 0) }
      eased.keys[2].left = { vector.create(-0.6, 0, 0) }

      pathed(
        {
          AfterPath = "Continue",
          Lifetime = NumberRange.new(1, 1),
          FlightTime = NumberRange.new(4, 4),
          Speed = NumberRange.new(20, 20),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(180)

          expect(near(piece.CFrame.Position, finish + tangent * 40, 0.05)).toBe(true)
        end,
        { rows = { Progress = value_curve.encode(eased) } }
      )
    end)

    test("VelocityParallel faces along the path while Progress eases into its end", function()
      const tangent = freeWay(path_curve.DEFAULT, TOP, Vector3.new(0, -4, -3))
      const eased = value_curve.decode(curveOf(1, { { 0, { 0 } }, { 1, { 1 } } })) :: value_curve.Curve

      eased.keys[1].right = { vector.create(0.2, 1, 0) }
      eased.keys[2].left = { vector.create(-0.6, 0, 0) }

      pathed(
        {
          AfterPath = "Stop",
          Orientation = "VelocityParallel",
          Lifetime = NumberRange.new(1, 1),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(50)

          -- the last eased frames, then the hold DestroyDelay keeps
          expect(turnedOff(piece, tangent, 40) < 0.5).toBe(true)
        end,
        { rows = { Progress = value_curve.encode(eased) } }
      )
    end)

    test("VelocityParallel keeps its facing where Progress holds still mid path", function()
      const tangent = freeTangent(path_curve.DEFAULT, TOP, 0.5)
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 0.5 } }, { 1, { 0.5 } } }) }

      pathed(
        {
          AfterPath = "Stop",
          Orientation = "VelocityParallel",
          Lifetime = NumberRange.new(1, 1),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(32)

          expect(turnedOff(piece, tangent, 40) < 0.5).toBe(true)
        end,
        { rows = rows }
      )
    end)

    test("Continue leaves a lopsided curve along its tangent where Progress holds", function()
      const curve = {
        { position = vector.zero, right = vector.create(0, 8, -1) },
        { position = vector.create(0, 0, -10), left = vector.create(0, 1, 1) },
      } :: any
      const stopped = freeAt(curve, TOP, 0.5)
      const tangent = freeTangent(curve, TOP, 0.5)
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 0.5 } }, { 1, { 0.5 } } }) }

      pathed(
        {
          AfterPath = "Continue",
          FlightTime = NumberRange.new(1, 1),
          Speed = NumberRange.new(10, 10),
        },
        curve,
        function(piece)
          frames(150)

          expect(near(piece.CFrame.Position, stopped + tangent * 5, 0.05)).toBe(true)
        end,
        { rows = rows }
      )
    end)

    test("Continue leaves backward along the path when Progress runs back into its end", function()
      const stopped = freeAt(path_curve.DEFAULT, TOP, 0.5)
      const tangent = freeTangent(path_curve.DEFAULT, TOP, 0.5)
      const rows = { Progress = curveOf(1, { { 0, { 0 } }, { 0.5, { 1 } }, { 1, { 0.5 } } }) }

      pathed(
        {
          AfterPath = "Continue",
          FlightTime = NumberRange.new(1, 1),
          Speed = NumberRange.new(10, 10),
        },
        path_curve.DEFAULT,
        function(piece)
          frames(150)

          expect(near(piece.CFrame.Position, stopped - tangent * 5, 0.05)).toBe(true)
        end,
        { rows = rows }
      )
    end)

    test("Continue leaves a path whose end handle was deleted along its last run in", function()
      const curve = {
        { position = vector.zero, right = vector.create(0, 4, -3) },
        { position = vector.create(0, 0, -10) },
      } :: any
      const finish = freeAt(curve, TOP, 1)
      const way = freeWay(curve, TOP, Vector3.new(0, -4, -7))

      pathed(
        { AfterPath = "Continue", FlightTime = NumberRange.new(1, 1), Speed = NumberRange.new(10, 10) },
        curve,
        function(piece)
          frames(150)

          expect(near(piece.CFrame.Position, finish + way * 5, 0.05)).toBe(true)
        end
      )
    end)

    test("Reverse leaves a path whose start handle was deleted along its first run out, backward", function()
      const curve = {
        { position = vector.zero },
        { position = vector.create(0, 0, -10), left = vector.create(0, 4, 3) },
      } :: any
      const finish = freeAt(curve, TOP, 0)
      const way = freeWay(curve, TOP, Vector3.new(0, -4, 7))

      pathed(
        { AfterPath = "Continue", Reverse = true, FlightTime = NumberRange.new(1, 1), Speed = NumberRange.new(10, 10) },
        curve,
        function(piece)
          frames(150)

          expect(near(piece.CFrame.Position, finish + way * 5, 0.05)).toBe(true)
        end
      )
    end)

    test("Continue leaves a path ending on a segment of no length along the segment before it", function()
      const curve = {
        { position = vector.zero, right = vector.create(0, 4, -3) },
        { position = vector.create(0, 0, -10), left = vector.create(0, 4, 3) },
        { position = vector.create(0, 0, -10) },
      } :: any
      const finish = freeAt(curve, TOP, 1)
      const way = freeWay(curve, TOP, Vector3.new(0, -4, -3))

      pathed(
        { AfterPath = "Continue", FlightTime = NumberRange.new(1, 1), Speed = NumberRange.new(10, 10) },
        curve,
        function(piece)
          frames(150)

          expect(near(piece.CFrame.Position, finish + way * 5, 0.05)).toBe(true)
        end
      )
    end)

    test("a fade over life spans the flight", function()
      const rows = { Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }) }

      pathed({ AfterPath = "Continue", FlightTime = NumberRange.new(2, 2) }, path_curve.DEFAULT, function(piece)
        frames(120)

        expect(math.abs(piece.Transparency - 0.5) < 0.03).toBe(true)
      end, { rows = rows })
    end)

    test("Collision Kill ends a path piece at the hit and fires its on-finish emits there", function()
      const real = effects.emitOnFinish
      local fired: Vector3? = nil

      effects.emitOnFinish = function(folder, obj, ...)
        fired = mover.cframe(obj).Position

        return real(folder, obj, ...)
      end

      const ok, err = pcall(function()
        pathed({ EmissionDirection = "Bottom", CollisionMode = "Kill", DestroyDelay = 0 }, DROP, function(piece)
          frames(70)

          expect(gone(piece)).toBe(true)
          expect(fired ~= nil).toBe(true)
          expect(near(fired :: Vector3, Vector3.new(0, 0, 0), 0.01)).toBe(true)
        end, {
          wrap = function(_, parent, run)
            walled(parent, run)
          end,
        })
      end)

      effects.emitOnFinish = real

      if not ok then
        error(err, 0)
      end
    end)

    test("Collision Bounce leaves the path and flies the rest of its life", function()
      pathed(
        { EmissionDirection = "Bottom", CollisionMode = "Bounce", Bounce = 0.5, Friction = 0 },
        DROP,
        function(piece)
          frames(90)

          const before = piece.CFrame.Position

          frames(20)

          const after = piece.CFrame.Position

          -- the path runs on below the floor; the bounce rises at 5 studs a second
          expect(before.Y > 0).toBe(true)
          expect(after.Y > before.Y + 1).toBe(true)
          expect(math.abs(after.X) < EPSILON and math.abs(after.Z) < EPSILON).toBe(true)
        end,
        {
          wrap = function(_, parent, run)
            walled(parent, run)
          end,
        }
      )
    end)

    test("Collision Bounce rebounds off a step that grazes a path's low point", function()
      -- down to a corner 0.2 studs under the floor and back up beside it: the
      -- step that crosses the floor ends past the corner, already climbing
      const dip = {
        { position = vector.zero },
        { position = vector.create(0, 0, -10.2) },
        { position = vector.create(0, 10, 0) },
      } :: any

      pathed(
        {
          EmissionDirection = "Bottom",
          CollisionMode = "Bounce",
          Bounce = 1,
          Friction = 0,
          Lifetime = NumberRange.new(1, 1),
        },
        dip,
        function(piece)
          frames(35)

          expect(piece.CFrame.Position.Y > 1).toBe(true)
        end,
        {
          wrap = function(_, parent, run)
            walled(parent, run)
          end,
        }
      )
    end)

    test("LockedToPart moves a path's start with the parent", function()
      pathed({ LockedToPart = true }, path_curve.DEFAULT, function(piece, _, parent)
        frames(60)

        parent.CFrame = PARENT + Vector3.new(5, 0, 0)

        frames(1)

        const want = freeAt(path_curve.DEFAULT, TOP, 61 / 120) + Vector3.new(5, 0, 0)

        expect(near(piece.CFrame.Position, want, LOOSE)).toBe(true)
      end)
    end)

    test("Lifetime 0 arrives at once and FlightTime 0 flies for no time", function()
      for _, flightTime in { 0, 1 } do
        pathed(
          {
            Lifetime = NumberRange.new(0, 0),
            AfterPath = "Continue",
            FlightTime = NumberRange.new(flightTime, flightTime),
            Speed = NumberRange.new(10, 10),
            PathEnd = "Center",
          },
          path_curve.DEFAULT,
          function(piece)
            expect(finite(piece.CFrame)).toBe(true)

            -- within the second DestroyDelay holds it
            for _ = 1, 50 do
              frames(1)

              expect(finite(piece.CFrame)).toBe(true)
            end
          end
        )
      end
    end)

    test("the flight rows hide under Path unless Continue or Bounce", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const flying = {
          "Speed",
          "Acceleration",
          "Turbulence",
          "TurbulenceFrequency",
          "Drag",
          "WindAffectsDrag",
          "VelocityInheritance",
          "Force",
        }
        const cases = {
          { rows = { Motion = "Path" }, hidden = true },
          { rows = { Motion = "Path", AfterPath = "Continue" }, hidden = false },
          { rows = { Motion = "Path", CollisionMode = "Bounce" }, hidden = false },
          { rows = { Motion = "Particle" }, hidden = false },
        }

        for i, case in cases do
          const rows = table.clone(case.rows)

          rows.Drag = 1
          rows.Turbulence = 1

          const hidden = hiddenOf(template(parent, rows))

          for _, name in flying do
            expect(`{i} {name} {hidden[name] == true}`).toBe(`{i} {name} {case.hidden}`)
          end
        end

        -- under Path Speed is always the exit speed and no orbit launch
        -- reaches a piece
        const launched = { Force = "Gravity", OrbitLaunch = true, AfterPath = "Continue" }
        const walking = table.clone(launched)

        walking.Motion = "Path"

        const path = hiddenOf(template(parent, walking))
        const particle = hiddenOf(template(parent, launched))

        for _, name in { "Speed", "OrbitLaunch", "OrbitLaunchScale" } do
          expect(`{name} {path[name] == true} {particle[name] == true}`).toBe(
            `{name} {name ~= "Speed"} {name == "Speed"}`
          )
        end
      end)
    end)

    test("EndPoint shows only for Target, EndRadius for Center and Target, FlightTime for Continue", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const ends = { Free = { true, true }, Center = { true, false }, Target = { false, false } }

        for kind, want in ends do
          const hidden = hiddenOf(template(parent, { Motion = "Path", PathEnd = kind }))

          expect(`{kind} EndPoint {hidden.EndPoint}`).toBe(`{kind} EndPoint {want[1]}`)
          expect(`{kind} EndRadius {hidden.EndRadius}`).toBe(`{kind} EndRadius {want[2]}`)
        end

        for after, want in { Stop = true, Continue = false } do
          const hidden = hiddenOf(template(parent, { Motion = "Path", AfterPath = after }))

          expect(`{after} FlightTime {hidden.FlightTime}`).toBe(`{after} FlightTime {want}`)
        end

        const path = hiddenOf(template(parent, { Motion = "Path" }))
        const particle = hiddenOf(template(parent, {}))

        for _, name in { "PathEnd", "Reverse", "Bend", "Progress", "AfterPath" } do
          expect(`{name} {path[name]} {particle[name]}`).toBe(`{name} false true`)
        end

        -- the group's title is the hidden Path row's name too, and the group
        -- is walked last
        expect(path.Path).toBe(false)
        expect(particle.Path).toBe(true)
        expect(path.States).toBe(true)
      end)
    end)
  end)

  harness.describe("a mesh's frame set", function()
    test("pieces end at their own drawn lives", function()
      recording(function(lives)
        framed(function(fake)
          const part = attached({ EmitCount = 3, Lifetime = NumberRange.new(0.25, 2) })

          frameSet(part, "lives", 4)

          const env = effects.emit(0, part)
          const list = pieces(fake)
          const gone: { [BasePart]: number } = {}
          local elapsed = 0

          expect(frame_store.find(part, "lives") ~= nil).toBe(true)
          expect(#list).toBe(3)

          while elapsed < 2.5 do
            frames(1)
            elapsed += FRAME

            for _, piece in list do
              if gone[piece] == nil and piece.Parent == nil then
                gone[piece] = elapsed
              end
            end
          end

          for _, piece in list do
            const at = gone[piece]
            const life = lives[piece]

            expect(life ~= nil and at ~= nil and math.abs(at - life) < 2 * FRAME).toBe(true)
          end

          env:Clear()
        end)
      end)
    end)

    test("an unsynced frame set ends with each piece's own Lifetime", function()
      framed(function(fake)
        const part = attached({ Lifetime = NumberRange.new(0.25, 0.25), SyncDuration = false })

        frameSet(part, "own", 4)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(24)

        expect(piece.Parent).toBe(nil)

        env:Clear()
      end)
    end)

    test("unsynced frames longer than the piece hold it still until they end", function()
      framed(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Lifetime = NumberRange.new(0.25, 0.25),
          SyncDuration = false,
          FlipbookChangeDuration = 1,
        })

        frameSet(part, "longer", 4)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(18)

        const at = piece.CFrame.Position

        frames(18)

        expect(piece.Parent ~= nil).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)

        frames(30)

        expect(piece.Parent).toBe(nil)

        env:Clear()
      end)
    end)
  end)

  harness.describe("a mesh's rows", function()
    test("every hidden rule runs on an untouched template", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {})
        const hidden = hiddenOf(part)

        for _, name in
          {
            "Rate",
            "WindAffectsDrag",
            "ShapePartial",
            "ForceTarget",
            "GravityMass",
            "GravitySoftening",
            "OrbitLaunch",
            "OrbitLaunchScale",
            "OrbitRadius",
            "OrbitSpin",
            "OrbitRise",
            "OrbitCapture",
            "TurbulenceFrequency",
            "Mesh Frames",
            "Material Frames",
            "Bounce",
            "Friction",
            "CollisionFilter",
            "CollisionFilterTag",
            "CollisionGroup",
            "CollisionRespectCanCollide",
          }
        do
          expect(`{name} {hidden[name]}`).toBe(`{name} true`)
        end

        expect(hidden.Collision).toBe(false)
      end)
    end)

    test("SpreadAngle and Face show under States, toward the camera too", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        for _, mode in { "None", "FacingCamera", "FacingCameraWorldUp" } do
          const hidden = hiddenOf(template(parent, { Motion = "States", StateOrientation = mode }))

          expect(`{mode} {hidden.SpreadAngle == true} {hidden.ShapeFace == true}`).toBe(`{mode} false false`)
        end
      end)
    end)

    test("EmissionDirection hides only where it moves nothing", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const cases = {
          { rows = { Shape = "Box", ShapeStyle = "Volume" }, hidden = true },
          { rows = { Shape = "Sphere" }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Surface" }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Volume", SpreadAngle = Vector3.new(30, 30, 0) }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Volume", ShapeFace = "Inward" }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Volume", ShapeFace = "InAndOut" }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Volume", Motion = "Particle" }, hidden = false },
          { rows = { Shape = "Box", ShapeStyle = "Volume", StateOrientation = "FacingCamera" }, hidden = true },
          {
            rows = {
              Shape = "Box",
              ShapeStyle = "Volume",
              SpreadAngle = Vector3.new(30, 30, 0),
              StateOrientation = "FacingCamera",
            },
            hidden = false,
          },
        }

        for i, case in cases do
          const rows = table.clone(case.rows)

          rows.Motion = rows.Motion or "States"

          const hidden = hiddenOf(template(parent, rows))

          expect(`{i} {hidden.EmissionDirection}`).toBe(`{i} {case.hidden}`)
        end

        -- a modifier on the spread turns the states whatever it rests at
        const part = template(parent, { Motion = "States", Shape = "Box", ShapeStyle = "Volume" })

        tweened(part, "SpreadAngle", Vector3.zero, Vector3.new(30, 30, 0))
        expect(hiddenOf(part).EmissionDirection).toBe(false)
      end)
    end)

    test("each force shows its own rows and the target's", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const rows = {
          Gravity = { "GravityMass", "GravitySoftening", "OrbitLaunch" },
          Orbit = { "OrbitRadius", "OrbitSpin", "OrbitRise", "OrbitCapture" },
        }

        for force in rows do
          const hidden = hiddenOf(template(parent, { Force = force }))

          expect(`{force} ForceTarget {hidden.ForceTarget}`).toBe(`{force} ForceTarget false`)

          for other, names in rows do
            for _, name in names do
              expect(`{force} {name} {hidden[name]}`).toBe(`{force} {name} {other ~= force}`)
            end
          end
        end
      end)
    end)

    test("the launch rows a force spends are hidden, the spread kept", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const spent = { "Speed", "Acceleration", "Drag", "WindAffectsDrag", "VelocityInheritance" }
        const cases = {
          { rows = {}, hidden = {}, scale = true },
          { rows = { Force = "Gravity" }, hidden = {}, scale = true },
          { rows = { Force = "Gravity", OrbitLaunch = true }, hidden = { Speed = true }, scale = false },
          {
            rows = { Force = "Orbit", Drag = 1 },
            hidden = {
              Speed = true,
              Acceleration = true,
              Drag = true,
              WindAffectsDrag = true,
              VelocityInheritance = true,
            },
            scale = true,
          },
        }

        for i, case in cases do
          const hidden = hiddenOf(template(parent, case.rows))

          for _, name in spent do
            if name == "WindAffectsDrag" and case.rows.Drag == nil then
              continue
            end

            expect(`{i} {name} {hidden[name] == true}`).toBe(`{i} {name} {case.hidden[name] == true}`)
          end

          expect(`{i} SpreadAngle {hidden.SpreadAngle == true}`).toBe(`{i} SpreadAngle false`)
          expect(`{i} OrbitLaunchScale {hidden.OrbitLaunchScale}`).toBe(`{i} OrbitLaunchScale {case.scale}`)
        end
      end)
    end)

    test("the force rows are their own card's, all but Force hidden at None", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const hidden = hiddenOf(template(parent, {}))

        expect(force_rows.layout).toEqual({
          "Force",
          "ForceTarget",
          "GravityMass",
          "GravitySoftening",
          "OrbitLaunch",
          "OrbitLaunchScale",
          "OrbitRadius",
          "OrbitSpin",
          "OrbitRise",
          "OrbitCapture",
        })
        expect(force_rows.rows.Force.choices).toEqual({ "None", "Gravity", "Orbit" })

        for _, entry in forge_mesh.layout do
          expect(type(entry) == "table" and entry.title == "Force").toBe(false)
        end

        for _, name in force_rows.layout do
          expect(`{name} {forge_mesh.attributes[name] == nil}`).toBe(`{name} true`)
          expect(`{name} {hidden[name] == true}`).toBe(`{name} {name ~= "Force"}`)
        end
      end)
    end)

    test("a modifier on a force row plays on the pieces and never on the template", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(2, 2), Force = "Orbit", OrbitCapture = 20 })

        tweened(part, "OrbitRadius", 2, 10)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        const function radius()
          const offset = piece.CFrame.Position - Vector3.new(1, 12, 3)

          return Vector3.new(offset.X, 0, offset.Z).Magnitude
        end

        frames(15)

        const early = radius()

        frames(90)

        expect(part:GetAttribute("OrbitRadius")).toBe(nil)
        expect(radius() > early + 1).toBe(true)

        env:Clear()
      end)
    end)

    test("resize scales the force card's lengths and retime its rates", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(
          parent,
          { OrbitRadius = 4, OrbitRise = 3, OrbitSpin = 0.5, GravitySoftening = 1, GravityMass = 100, Drag = 1 }
        )

        -- lune refuses a non utf-8 attribute string, and an unset Path is
        -- written scaled, so the rows are cached
        attr.cache(part)
        resize.apply(part, 2)

        expect(attr.get(part, "OrbitRadius", nil)).toBe(8)
        expect(attr.get(part, "OrbitRise", nil)).toBe(6)
        expect(attr.get(part, "GravitySoftening", nil)).toBe(2)
        expect(attr.get(part, "GravityMass", nil)).toBe(800)
        expect(attr.get(part, "OrbitSpin", nil)).toBe(0.5)
        expect(attr.get(part, "Drag", nil)).toBe(1)

        retime.apply(part, 2, 0.5)

        expect(attr.get(part, "OrbitSpin", nil)).toBe(1)
        expect(attr.get(part, "GravityMass", nil)).toBe(3200)
        expect(attr.get(part, "Drag", nil)).toBe(2)
      end)
    end)

    test("resize scales a mesh's Size curve and its lanes, never the template", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL })
        const bare = template(parent, { Speed = STILL })
        const mesh = harness.make("SpecialMesh", part) :: SpecialMesh

        part.Size = Vector3.new(2, 3, 4)
        mesh.Scale = Vector3.new(1, 2, 3)

        -- keys that bend through their handles and widen by their envelopes,
        -- so every part of the curve shows in a sample
        const authored = value_curve.flat(1, 3)

        authored.linked = false
        authored.keys = {
          {
            time = 0,
            value = { 1, 2, 0.5 },
            envelope = 0.25,
            left = table.create(3, vector.zero),
            right = { vector.create(0.3, 1, 0), vector.create(0.2, -0.5, 0), vector.create(0.1, 0.25, 0) },
          },
          {
            time = 1,
            value = { 3, 1, 2 },
            envelope = 0.5,
            left = { vector.create(-0.3, 0.5, 0), vector.create(-0.2, 1, 0), vector.create(-0.4, -1, 0) },
            right = table.create(3, vector.zero),
          },
        }

        const stored = value_curve.encode(authored)
        const before = value_curve.decode(stored) :: value_curve.Curve
        const lane = { { kind = "tween", chain = false, start = value.lit(stored), finish = value.lit(stored) } }

        -- lune refuses a non utf-8 attribute string, so the rows are cached
        attr.cache(part)
        attr.cache(bare)
        attr.set(part, "Size", stored)
        attr.set(part, mods.attrName("attribute", "Size"), frame.frame(codec.encode({ v = 1, queue = lane })))

        resize.apply(part, 2)
        resize.apply(bare, 2)

        const after = value_curve.decode(attr.get(part, "Size", nil)) :: value_curve.Curve
        const queue = codec.decode(frame.unframe(attr.get(part, mods.attrName("attribute", "Size"), nil)) :: any)
        const tween = (queue :: any).lanes.start[1]
        const lanes = {
          value_curve.decode(tween.start.v) :: value_curve.Curve,
          value_curve.decode(tween.finish.v) :: value_curve.Curve,
        }

        for _, draws in { { 0, 0 }, { 1, -1 }, { -1, 1 } } do
          for step = 0, 8 do
            const t = step / 8
            const was = value_curve.at(before, t, draws)

            for _, curve in { after, lanes[1], lanes[2] } do
              const now = value_curve.at(curve, t, draws)

              for c = 1, 3 do
                expect(near1(now[c], was[c] * 2)).toBe(true)
              end
            end
          end
        end

        expect(part.Size).toBe(Vector3.new(2, 3, 4))
        expect(mesh.Scale).toBe(Vector3.new(1, 2, 3))

        -- a row resting at its default takes the default scaled
        const flat = value_curve.decode(attr.get(bare, "Size", nil)) :: value_curve.Curve

        for c = 1, 3 do
          expect(near1(value_curve.at(flat, 0.5)[c], 2)).toBe(true)
        end
      end)
    end)

    test("resize scales the positions and sizes of a mesh's states", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Motion = "States" })
        const list = {
          stateOf(0, { position = vector.create(1, 0, 0) }),
          stateOf(1, { position = vector.create(0, 4, -2), size = vector.create(3, 3, 3) }),
        }

        -- lune refuses a non utf-8 attribute string, so the row is cached
        attr.cache(part)
        attr.set(part, "States", state_list.encode(list :: any))

        resize.apply(part, 2)

        const after = state_list.decode(attr.get(part, "States", nil)) :: state_list.List

        expect(after[1].position).toBe(vector.create(2, 0, 0))
        expect(after[2].position).toBe(vector.create(0, 8, -4))
        expect(after[1].size).toBe(vector.create(2, 2, 2))
        expect(after[2].size).toBe(vector.create(6, 6, 6))
      end)
    end)

    test("a piece's own row over its life is sampled evenly, a resting one once", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { OrbitSpin = 3 })

        tweened(part, "GravityMass", 0, 100)

        const attrs = rowsOf(part)
        const ramp = launch_common.over(attrs.GravityMass, 2, 4, function(v)
          return v
        end)

        expect(#ramp).toBe(5)
        expect(near1(ramp[1], 0)).toBe(true)
        expect(near1(ramp[5], 100)).toBe(true)
        expect(ramp[2] > ramp[1] and ramp[3] > ramp[2]).toBe(true)

        const flat = launch_common.over(attrs.OrbitSpin, 2, 4, function(v)
          return v
        end)

        expect(#flat).toBe(1)
        expect(flat[1]).toBe(3)
      end)
    end)

    test("a generator lent to the reads draws a piece's rows the same twice", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = NumberRange.new(1, 100), Lifetime = NumberRange.new(1, 9) })
        const ctx = { ref = part, obj = part, effect = forge_mesh }
        const attrs = reader.resolve(forge_mesh :: any, ctx :: any)

        const function drawn(seed: number)
          mods.random = Random.new(seed)

          const speed, life = launch_common.draw(attrs, 0)

          mods.random = nil

          return speed, life
        end

        const a, b = drawn(7)
        const c, d = drawn(7)
        const e = drawn(8)

        expect(a).toBe(c)
        expect(b).toBe(d)
        expect(a ~= e).toBe(true)
      end)
    end)

    test("LockedToPart hides the Collision group", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        expect(hiddenOf(template(parent, { LockedToPart = true })).Collision).toBe(true)
      end)
    end)

    test("a modifier on LockedToPart keeps the Collision group shown", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { LockedToPart = true })

        tweened(part, "LockedToPart", true, false)

        expect(hiddenOf(part).Collision).toBe(false)
        expect(hiddenOf(template(parent, { LockedToPart = false })).Collision).toBe(false)
      end)
    end)

    test("a Turbulence modifier over a base of 0 shows TurbulenceFrequency", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Turbulence = 0 })

        randomized(part, "Turbulence", 1, 2)

        expect(hiddenOf(part).TurbulenceFrequency).toBe(false)
      end)
    end)

    test("glow rows set on a template reach the look without being forge_mesh rows", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmissiveStrength = 3 })
        const authored = harness.make("SurfaceAppearance", part) :: any

        authored.EmissiveStrength = 2

        const env = effects.emit(0, part)
        const worn = pieces(fake)[1]:FindFirstChildOfClass("SurfaceAppearance") :: any

        expect(forge_mesh.attributes.EmissiveStrength).toBe(nil)
        expect(math.abs(worn.EmissiveStrength - 6) < EPSILON).toBe(true)

        env:Clear()
      end)
    end)

    test("a plain emit carries an edit no signal told of, and a tick keeps its copy until one does", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1) })
        const decal = harness.make("Decal", part) :: Decal
        const set = harness.make("Folder", part)

        decal.Name = "Front"
        decal.Texture = "rbxassetid://1"
        set.Name = "Frames"
        set:SetAttribute("FrameSet", "kept")
        set:AddTag(utility.EMIT_EXCLUDE_TAG)

        -- the texture the piece of one emit shows, its set left behind
        const function shown(emit: () -> () -> ())
          const clear = emit()
          const list = pieces(fake)

          expect(#list).toBe(1)
          expect(list[1]:FindFirstChild("Frames")).toBe(nil)

          const texture = (list[1]:FindFirstChild("Front") :: Decal).Texture

          clear()
          frames(1)

          return texture
        end

        const function plain()
          const env = effects.emit(0, part)

          return function()
            env:Clear()
          end
        end

        const function tick()
          const token = enabled_effects.token()

          enabled_effects.ticker(part, forge_mesh, token, effects)(FRAME)

          return function()
            lifetime.clear(token)
          end
        end

        const function told()
          for source, stale in fake.stale or {} do
            if source == part then
              stale()
            end
          end
        end

        expect(shown(plain)).toBe("rbxassetid://1")

        -- lune fires no signal, so only a plain emit's rebuild sees an edit
        decal.Texture = "rbxassetid://2"

        expect(shown(tick)).toBe("rbxassetid://1")
        expect(shown(plain)).toBe("rbxassetid://2")

        decal.Texture = "rbxassetid://3"
        told()

        expect(shown(tick)).toBe("rbxassetid://3")
      end)
    end)
  end)

  harness.describe("the live piece cap", function()
    const function census()
      return forge_mesh.pieces.live
    end

    test("pieces past the cap are dropped and the count never passes it", function()
      capped(5, function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 8, Lifetime = NumberRange.new(1, 1), Speed = STILL })
          const env = effects.emit(0, part)

          frames(1)
          expect(census()).toBe(5)
          expect(#pieces(fake)).toBe(5)

          -- a second emit finds no room either
          const more = effects.emit(0, part)

          frames(1)
          expect(census()).toBe(5)
          expect(#pieces(fake)).toBe(5)

          more:Clear()
          env:Clear()
          expect(census()).toBe(0)
        end)
      end)
    end)

    test("spawns succeed again once pieces end", function()
      capped(5, function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 8, Lifetime = NumberRange.new(0.5, 0.5), Speed = STILL })

          effects.emit(0, part)
          frames(1)
          expect(census()).toBe(5)

          frames(60)
          expect(census()).toBe(0)

          const again = effects.emit(0, part)

          frames(1)
          expect(census()).toBe(5)
          expect(#pieces(fake)).toBe(5)

          again:Clear()
          expect(census()).toBe(0)
        end)
      end)
    end)

    test("a piece that ends naturally gives its place back", function()
      capped(5, function()
        staged(function()
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 3, Lifetime = NumberRange.new(0.5, 0.5), Speed = STILL })

          effects.emit(0, part)
          frames(1)
          expect(census()).toBe(3)

          frames(60)
          expect(census()).toBe(0)
        end)
      end)
    end)

    test("a Kill on a hit gives its place back", function()
      capped(5, function()
        falling({ CollisionMode = "Kill" }, function(piece)
          expect(census()).toBe(1)

          for _ = 1, 120 do
            frames(1)

            if piece.Parent == nil then
              break
            end
          end

          expect(piece.Parent).toBe(nil)
          expect(census()).toBe(0)
        end)
      end)
    end)

    test("clearing or cancelling an emit gives every place back", function()
      capped(5, function()
        staged(function()
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 4, Lifetime = NumberRange.new(5, 5), Speed = STILL })
          const env = effects.emit(0, part)

          frames(2)
          expect(census()).toBe(4)

          env:Clear()
          expect(census()).toBe(0)
        end)
      end)
    end)

    test("a piece whose step throws gives its place back", function()
      capped(5, function()
        staged(function()
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 3, Lifetime = NumberRange.new(30, 30), Speed = STILL })
          const move = mover.move

          const ok, err = pcall(function()
            effects.emit(0, part)
            frames(2)
            expect(census()).toBe(3)

            mover.move = function()
              error("a step that throws")
            end

            harness.captureWarnings(function()
              frames(2)
            end)
          end)

          mover.move = move

          if not ok then
            error(err, 0)
          end

          expect(census()).toBe(0)
        end)
      end)
    end)

    test("a full house draws nothing more for an emit", function()
      capped(2, function()
        staged(function()
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 6, Lifetime = NumberRange.new(1, 1), Speed = STILL })
          const draw = launch_common.draw
          local draws = 0

          launch_common.draw = function(...)
            draws += 1

            return draw(...)
          end

          const ok, err = pcall(function()
            const env = effects.emit(0, part)

            frames(1)
            env:Clear()
          end)

          launch_common.draw = draw

          if not ok then
            error(err, 0)
          end

          expect(draws).toBe(2)
        end)
      end)
    end)

    test("a template destroyed mid flight lets its pieces fly on and give their places back", function()
      capped(5, function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 4, Lifetime = NumberRange.new(1, 1), Speed = STILL })

          effects.emit(0, part)
          frames(2)
          expect(census()).toBe(4)

          part:Destroy()

          -- the pieces fly on without it, still counted, and give their
          -- places back as their lives end
          frames(10)
          expect(census()).toBe(4)
          expect(#pieces(fake)).toBe(4)

          frames(60)
          expect(census()).toBe(0)
        end)
      end)
    end)
  end)
end)
