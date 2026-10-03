local clock = require("@mod/clock")
local retime = require("@mod/retime")
local lifetime = require("@mod/lifetime")

local numeric_common = require("@mod/common/numeric")

-- the time rows retime scales on an emitter, which a speed above 1 scales here
local TIME_ROWS = retime.PROPERTY_UNITS.ParticleEmitter

type Flight = {
  part: any,
  force: any?,
  linear: Vector3?,
  angular: Vector3?,
  impulse: Vector3?,
  spin: Vector3?,
  launched: Vector3?,
  pushed: number?,
}

local adapters = {}

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

-- what an emitter's TimeScale or time row goes back to once the emits writing
-- it leave, nil while none does, when the emitter's own is the authored
function adapters.authoredOf(obj: any, name: string): any?
  return lifetime.restoreOf(obj, "property", name)
end

-- a particle emitter runs at its TimeScale times the effect's clock: up to 1
-- that is its TimeScale, exact for live particles; above 1 TimeScale rests at
-- 1 and the emitter's time rows take the rest, which reaches new particles
-- only. every write goes through a writer, so of two emits of one emitter
-- the owner's TimeScale and clock are what the emitter runs at, and the last
-- to leave puts the authored back. answers what sets the authored TimeScale
function adapters.particle(scope: lifetime.effect, obj: any, authored: number): (authored: number) -> ()
  local timeline = scope.clock

  -- a NaN or infinite one falls back to what the emitter has, or to 1
  if not numeric_common.finite(authored) then
    local current = adapters.authoredOf(obj, "TimeScale") or obj.TimeScale

    authored = if numeric_common.finite(current) then current else 1
  end

  local timeScale = lifetime.write(scope, obj, "property", "TimeScale")
  local rows: { [string]: lifetime.writer }? = nil
  local retimedBy = 1

  local function apply()
    local total = math.min(authored, 1) * clock.factorOf(timeline)

    lifetime.set(timeScale, math.min(total, 1))

    local by = math.max(total, 1)

    if by == retimedBy then
      return
    end

    retimedBy = by

    local writers = rows

    if writers == nil then
      writers = {}

      for name in TIME_ROWS do
        writers[name] = lifetime.write(scope, obj, "property", name)
      end

      rows = writers
    end

    -- from the rows as authored, never from what the last speed left
    for name, unit in TIME_ROWS do
      local base = adapters.authoredOf(obj, name)

      if base == nil then
        base = obj[name]
      end

      lifetime.set(writers[name], scaled(base, retime.factorOf(unit, by) :: number))
    end
  end

  apply()

  lifetime.hold(scope, clock.watch(timeline, apply))

  return function(value: number)
    if not numeric_common.finite(value) then
      return
    end

    authored = value
    apply()
  end
end

-- a beam's texture scrolls at its TextureSpeed times the effect's clock, so
-- a pause stops it. written at once when the row is animated or the factor is
-- not 1, and on every change of the factor after. answers what sets the
-- authored TextureSpeed
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
-- sets the authored PlaybackSpeed, and what lets the clock go once the sound
-- is done with
function adapters.sound(scope: lifetime.effect, clone: any, authored: number): ((authored: number) -> (), () -> ())
  local timeline = scope.clock
  local paused = false

  local function apply()
    local factor = clock.factorOf(timeline)

    if factor == 0 then
      -- only what plays is paused, so only that is resumed, a sound that has
      -- ended answers IsPaused too
      if not paused and clone.IsPlaying then
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

  local stop = clock.watch(timeline, apply)

  lifetime.hold(scope, stop)

  return function(value: number)
    if not numeric_common.finite(value) then
      return
    end

    authored = value
    apply()
  end,
    stop
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
-- its velocity on resume. answers what launches a part with the impulses of a
-- flight at speed 1, and what the effect calls after it writes one's Size
function adapters.debris(
  scope: lifetime.effect
): ((part: any, impulse: Vector3, spin: Vector3) -> (), (part: any) -> ())
  local timeline = scope.clock
  local flights: { Flight } = {}
  local byPart: { [any]: Flight } = {}

  -- the last factor above 0 the parts flew at
  local launched = clock.factorOf(timeline)
  local moving = if launched > 0 then launched else 1

  -- the engine takes an impulse at its next step, so a part is waiting on its
  -- own while its velocity has not moved off what it read once the impulse
  -- was applied, within the frame of the push and the next, whose watcher
  -- call is the first to see a change made in it. past that it is let go,
  -- so a piece come to rest at the velocity it was launched from is not
  -- launched again
  local function waiting(flight: Flight): boolean
    if flight.impulse == nil then
      return false
    end

    if clock.frame - (flight.pushed :: number) <= 1 and flight.part.AssemblyLinearVelocity == flight.launched then
      return true
    end

    flight.impulse = nil
    flight.spin = nil
    flight.launched = nil
    flight.pushed = nil

    return false
  end

  -- an impulse applied now, at the scale of what the part flies at
  local function push(flight: Flight, impulse: Vector3, spin: Vector3)
    local part = flight.part

    part:ApplyImpulse(impulse)
    part:ApplyAngularImpulse(spin)

    flight.impulse = impulse
    flight.spin = spin
    flight.launched = part.AssemblyLinearVelocity
    flight.pushed = clock.frame
  end

  local function apply(factor: number)
    if factor == 0 then
      for _, flight in flights do
        local part = flight.part

        if flight.linear == nil then
          -- an impulse the step has yet to take is lost on an anchored part,
          -- so a part paused before its step keeps it for the resume
          waiting(flight)

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

        if flight.impulse ~= nil then
          push(flight, flight.impulse * ratio, (flight.spin :: Vector3) * ratio)
        end
      elseif ratio ~= 1 then
        local before = waiting(flight)

        part.AssemblyLinearVelocity *= ratio
        part.AssemblyAngularVelocity *= ratio

        -- what the step has yet to take is topped up to the new speed
        if before then
          local impulse = flight.impulse :: Vector3
          local spin = flight.spin :: Vector3

          part:ApplyImpulse(impulse * (ratio - 1))
          part:ApplyAngularImpulse(spin * (ratio - 1))

          flight.impulse = impulse * ratio
          flight.spin = spin * ratio
          flight.launched = part.AssemblyLinearVelocity
        end
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

  -- the engine takes an impulse at its next step, so a velocity read after
  -- one holds none of it: the impulses are scaled themselves, and a part
  -- launched while paused keeps its own for the resume, as an anchored part
  -- takes none
  local function launch(part: any, impulse: Vector3, spin: Vector3)
    local flight: Flight = { part = part }
    local factor = clock.factorOf(timeline)

    table.insert(flights, flight)
    byPart[part] = flight

    if factor == 0 then
      flight.linear = part.AssemblyLinearVelocity * moving
      flight.angular = part.AssemblyAngularVelocity * moving
      flight.impulse = impulse * moving
      flight.spin = spin * moving
      part.Anchored = true

      return
    end

    -- by what the others fly at, which the watcher rescales from, so a
    -- change this frame the watcher has yet to tell keeps every part in step
    if moving ~= 1 then
      part.AssemblyLinearVelocity *= moving
      part.AssemblyAngularVelocity *= moving
    end

    push(flight, impulse * moving, spin * moving)
    pull(flight, moving)
  end

  -- a part whose size the effect has written weighs something else, so the
  -- force that leaves gravity at the clock's square is worked out again
  local function resized(part: any)
    local flight = byPart[part]

    if flight == nil or flight.force == nil or clock.factorOf(timeline) == 0 then
      return
    end

    pull(flight, moving)
  end

  return launch, resized
end

return adapters
