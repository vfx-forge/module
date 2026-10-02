local clock = require("@mod/clock")
local retime = require("@mod/retime")
local lifetime = require("@mod/lifetime")

-- the time rows retime scales on an emitter, which a speed above 1 scales here
local TIME_ROWS = retime.PROPERTY_UNITS.ParticleEmitter

type Original = { users: number, rows: { [string]: any } }

type Flight = {
  part: any,
  force: any?,
  linear: Vector3?,
  angular: Vector3?,
}

local adapters = {}

-- what an emitter's time rows held before any emit retimed them, kept while
-- one still has them retimed, so the last to let go puts them back however
-- many emits of one in-place emitter overlap
local ORIGINALS = setmetatable({} :: { [any]: Original }, { __mode = "k" })

-- how an adapter makes the instances it adds, replaceable so a spec can stand
-- one in
function adapters.create(class: string): any
  return Instance.new(class)
end

local function scaled(v: any, f: number): any
  if typeof(v) == "NumberRange" then
    return NumberRange.new(v.Min * f, v.Max * f)
  end

  return v * f
end

local function retimeRows(obj: any, by: number, held: boolean): boolean
  local original = ORIGINALS[obj]

  if original == nil then
    if by == 1 then
      return held
    end

    local rows = {}

    for name in TIME_ROWS do
      rows[name] = obj[name]
    end

    original = { users = 0, rows = rows }
    ORIGINALS[obj] = original
  end

  if not held then
    original.users += 1
  end

  for name, unit in TIME_ROWS do
    obj[name] = scaled(original.rows[name], retime.factorOf(unit, by) :: number)
  end

  return true
end

local function releaseRows(obj: any)
  local original = ORIGINALS[obj]

  if original == nil then
    return
  end

  original.users -= 1

  if original.users > 0 then
    return
  end

  ORIGINALS[obj] = nil

  for name, value in original.rows do
    obj[name] = value
  end
end

-- a particle emitter runs at its TimeScale times the effect's clock: up to 1
-- that is its TimeScale, exact for live particles; above 1 TimeScale rests at
-- 1 and the emitter's time rows take the rest, which reaches new particles
-- only. answers what sets the authored TimeScale. the rows and the TimeScale
-- go back when the effect ends
function adapters.particle(scope: lifetime.effect, obj: any, authored: number): (authored: number) -> ()
  local timeline = scope.clock
  local retimedBy = 1
  local held = false

  local function apply()
    local total = math.min(authored, 1) * clock.factorOf(timeline)

    obj.TimeScale = math.min(total, 1)

    local by = math.max(total, 1)

    if by == retimedBy then
      return
    end

    retimedBy = by
    held = retimeRows(obj, by, held)
  end

  apply()

  lifetime.hold(scope, clock.watch(timeline, apply))

  lifetime.hold(scope, function()
    obj.TimeScale = math.min(authored, 1)

    if held then
      releaseRows(obj)
    end
  end)

  return function(value: number)
    authored = value
    apply()
  end
end

-- a beam's texture scrolls at its TextureSpeed times the effect's clock, so
-- a pause stops it. written at once only when it differs from what the beam
-- already holds. answers what sets the authored TextureSpeed
function adapters.beam(scope: lifetime.effect, obj: any, base: number, animated: boolean): (base: number) -> ()
  local timeline = scope.clock

  local function apply()
    obj.TextureSpeed = base * clock.factorOf(timeline)
  end

  if animated or clock.factorOf(timeline) ~= 1 then
    apply()
  end

  lifetime.hold(scope, clock.watch(timeline, apply))

  return function(value: number)
    base = value
    apply()
  end
end

-- a sound plays at its PlaybackSpeed times the effect's clock, tape style, so
-- its pitch follows, and pauses while the clock stands still. answers what
-- sets the authored PlaybackSpeed
function adapters.sound(scope: lifetime.effect, clone: any, authored: number): (authored: number) -> ()
  local timeline = scope.clock
  local paused = false

  local function apply()
    local factor = clock.factorOf(timeline)

    if factor == 0 then
      if not paused then
        paused = true
        clone:Pause()
      end

      return
    end

    clone.PlaybackSpeed = authored * factor

    if paused then
      paused = false
      clone:Resume()
    end
  end

  apply()

  lifetime.hold(scope, clock.watch(timeline, apply))

  return function(value: number)
    authored = value
    apply()
  end
end

-- the force that leaves a launched part falling under gravity times the
-- clock's square, the pull a slowed or hurried fall feels. none is made at 1
local function pull(flight: Flight, factor: number)
  local part = flight.part
  local force = flight.force

  if force == nil then
    if factor == 1 then
      return
    end

    local attachment = adapters.create("Attachment")
    attachment.Parent = part

    force = adapters.create("VectorForce")
    force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = true
    force.Parent = part

    flight.force = force
  end

  force.Force = Vector3.new(0, part.AssemblyMass * workspace.Gravity * (1 - factor * factor), 0)
end

-- debris flies under the engine's physics, which has no time scale: a part is
-- launched at the clock's speed and falls under its square, a change in speed
-- rescales every part in flight, and a pause anchors each one and gives it back
-- its velocity on resume. answers what files a part once it is launched
function adapters.debris(scope: lifetime.effect): (part: any) -> ()
  local timeline = scope.clock
  local flights: { Flight } = {}

  -- the last factor above 0 the parts flew at
  local launched = clock.factorOf(timeline)
  local moving = if launched > 0 then launched else 1

  local function apply(factor: number)
    if factor == 0 then
      for _, flight in flights do
        local part = flight.part

        if flight.linear == nil then
          flight.linear = part.AssemblyLinearVelocity
          flight.angular = part.AssemblyAngularVelocity
          part.Anchored = true
        end
      end

      return
    end

    local ratio = factor / moving
    moving = factor

    for _, flight in flights do
      local part = flight.part
      local linear = flight.linear

      if linear ~= nil then
        part.Anchored = false
        part.AssemblyLinearVelocity = linear * ratio
        part.AssemblyAngularVelocity = (flight.angular :: Vector3) * ratio

        flight.linear = nil
        flight.angular = nil
      elseif ratio ~= 1 then
        part.AssemblyLinearVelocity *= ratio
        part.AssemblyAngularVelocity *= ratio
      end

      pull(flight, factor)
    end
  end

  lifetime.hold(
    scope,
    clock.watch(timeline, function(factor: number)
      apply(factor)
    end)
  )

  return function(part: any)
    local flight: Flight = { part = part }
    local factor = clock.factorOf(timeline)

    table.insert(flights, flight)

    if factor == 0 then
      flight.linear = part.AssemblyLinearVelocity * moving
      flight.angular = part.AssemblyAngularVelocity * moving
      part.Anchored = true

      return
    end

    if factor ~= 1 then
      part.AssemblyLinearVelocity *= factor
      part.AssemblyAngularVelocity *= factor
    end

    pull(flight, factor)
  end
end

return adapters
