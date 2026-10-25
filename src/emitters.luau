local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local value = require("@mod/value")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local modifiers = require("@mod/modifiers")
local legacy_mods = require("@mod/legacy_mods")

local timing_common = require("@mod/common/timing")

-- how many throwing writes a driven target gets before the applier gives up on
-- it, where a throw left to the scheduler would end the driver on the first
local MAX_WRITE_FAILURES = 3

local emitters = {}

-- the reader binds a track on an effect's scope through the same helper every
-- effect steps with, handed in here because the reader stays engine-free
reader.bind = tween.drive

-- a property that does not exist throws on the read, so a failed read reports
-- as nil and every caller treats that as "nothing there"
local function currentOf(obj: Instance, source: string, name: string): any
  if source ~= "property" then
    return attr.get(obj, name, nil, true)
  end

  local ok, current = pcall(function()
    return (obj :: any)[name]
  end)

  return if ok then current else nil
end

-- a property whose current value is a different type will never accept the
-- write
local function canDrive(obj: Instance, source: string, name: string, v: any): boolean
  if source ~= "property" then
    return true
  end

  return typeof(currentOf(obj, source, name)) == typeof(v)
end

-- a legacy RayValue child carried a ResetOnFinish flag, default true, and the
-- target went back on finish: a tween to its authored _START_VALUE when it had
-- one and otherwise to the value the target held before, a randomizer always
-- to that value. legacy_mods lifts the flag onto its entries as `reset`, and
-- it becomes the writer's end rule: false keeps the last value, a tween with a
-- start value leaves that behind. a queue authored in the modifier panel
-- carries no `reset`, and its target goes back to what it held before
local function endOf(queue: { any }): (string?, any)
  local rule: string? = nil
  local start = nil

  -- legacy entries never chain, so the last of them is the one that actually
  -- drove the target and its own flag is the one that decides
  for _, m in queue do
    if m.reset == nil then
      continue
    end

    if m.reset == false then
      rule = "keep"
      start = nil
    elseif m.kind ~= "randomizer" and m.start ~= nil then
      rule = "start"
      start = value.resolve(m.start)
    else
      rule = nil
      start = nil
    end
  end

  return rule, start
end

-- the clock the applier falls back to when no modifier on a queue names a
-- duration of its own. no forge schema authors a bare Duration as an effect
-- clock, but a legacy tweener RayValue carries one as its own span, stored as
-- a NumberRange that collapses to Min. the read is soft because a fallback is
-- not authored data and must never be stamped onto a dispatched instance
local function fallbackDuration(obj: Instance): number
  return attr.get(obj, "Duration", 1, true, function(v)
    if typeof(v) == "NumberRange" and v.Min > 0 then
      return v.Min
    end

    if typeof(v) == "number" and v > 0 then
      return v
    end

    return 1
  end)
end

-- the speed ramp a legacy tween child carried, as a multiplier on the clock
-- the timer counts, how long that ramp runs, and the lead it sits behind: where
-- its entry starts, placed by the same walk the sampler places it with, so the
-- waits and the entries ahead of it count and a parallel entry keeps only its
-- own delay. it goes by wall time the way the child's own speed tween did,
-- beside the tween it scales
local function speedOf(
  queue: { any },
  rolls: mods.Rolls,
  linked: number
): (((wall: number) -> number)?, number?, number)
  for i, m in queue do
    local ramp = m.speed

    if type(ramp) ~= "table" then
      continue
    end

    local function speedAt(wall: number): number
      local progress = if ramp.duration > 0 then math.clamp(wall / ramp.duration, 0, 1) else 1
      return utility.lerp(ramp.start, ramp.finish, modifiers.alphaFromCurve(ramp.curve, progress))
    end

    local offsets = modifiers.schedule(queue, rolls.picks, linked, rolls.env)

    return speedAt, ramp.duration, if offsets ~= nil then offsets[i] or 0 else 0
  end

  return nil, nil, 0
end

export type DriveOpts = {
  -- the end rule in place of the one the queue's own entries spell
  rule: string?,

  -- called once, when the driver has written its first value
  took: (() -> ())?,

  -- filled with a stop, which ends the driver where it is
  handle: { stop: (() -> ())? }?,
}

-- drives one queue on one target as a child effect of the same emit, so the
-- emit stays open while the driver runs and a clear stops it with everything
-- else. `duration` is the clock the queue falls back to when nothing in it
-- names one
local function drive(
  target: Instance,
  source: string,
  name: string,
  queue: { any },
  scope: types.scope,
  duration: number,
  opts: DriveOpts?
)
  local rolls = mods.roll(queue)
  local span, linked = mods.span(queue, duration, rolls)
  local sample = mods.sampler(target, source, name, span, queue, rolls, linked)

  if sample == nil then
    return
  end

  local first = sample(0)

  if first ~= nil and not canDrive(target, source, name, first) then
    return
  end

  local rule, start = endOf(queue)

  if opts ~= nil and opts.rule ~= nil then
    rule = opts.rule
    start = nil
  end

  local took = if opts ~= nil then opts.took else nil
  local speedAt, speedUntil, lead = speedOf(queue, rolls, linked)

  local fx = lifetime.effect(scope.emit, scope.depth, scope.effects)

  lifetime.run(fx, function(driver)
    local failures = 0
    local wall = 0

    -- joined at its first write and let go with the driver, so a clear puts
    -- the target back too
    local writer = lifetime.write(driver, target, source, name, rule, start)

    local length = timing_common.duration(span)
    local ended = lifetime.join(driver)
    local counted = lifetime.add(ended)
    local elapsed = 0
    local ticking

    -- how far the ramp's own clock moves this frame, nil once it is over
    local function advance(deltaTime: number): number?
      local waiting = elapsed < lead

      if not waiting then
        wall += deltaTime
      end

      local v = sample(elapsed)

      if v ~= nil and took ~= nil then
        lifetime.set(writer, v)

        local first = took
        took = nil
        first()
      elseif v ~= nil and not lifetime.set(writer, v) then
        failures += 1

        if failures >= MAX_WRITE_FAILURES then
          logger.warn(`stopped driving {name} on {target:GetFullName()} after {failures} failed writes`)
          return nil
        end
      end

      -- a delay ahead of the ramp is a wall-clock wait the ramp never touches.
      -- the multiplier belongs to what runs after the wait, and the ramp's own
      -- clock only starts turning once that does, so the wait passes at plain
      -- frame time and leaves the ramp where it began
      if waiting then
        return deltaTime
      end

      local scaled = if speedAt then deltaTime * speedAt(wall) else deltaTime

      -- a legacy speed ramp is allowed to rest at zero or below, and that is
      -- where the tween it scales stopped. a zero read while the ramp is still
      -- moving is not the end, so the driver only gives up once the ramp has
      -- settled there
      return if scaled > 0 or (speedUntil ~= nil and wall < speedUntil) then scaled else nil
    end

    local stopped = false

    local function stop()
      if stopped then
        return
      end

      stopped = true
      ticking:Disconnect()
      counted()
    end

    ticking = lifetime.step(driver, function(deltaTime: number)
      local moved = advance(deltaTime)

      if moved == nil or timing_common.done(elapsed, length) then
        stop()
        return
      end

      elapsed = math.clamp(elapsed + moved, 0, math.max(length, 0.001))
    end)

    if opts ~= nil and opts.handle ~= nil then
      opts.handle.stop = stop
    end

    lifetime.awaitJoin(ended)
  end)
end

-- a randomizer child is applied before the effect it sits under reads its
-- target, through a writer on an effect of its own that ends on the next frame,
-- after that effect has read the drawn value: a reset one gives the target back
-- then, one that keeps leaves the draw. driving it through the driver would
-- write one frame later than the effect needs
local function applyRandomizer(target: Instance, child: legacy_mods.Child, scope: types.scope)
  local queue = child.queue
  local rolls = mods.roll(queue)
  local sample = mods.sampler(target, child.source, child.name, 0, queue, rolls, 0)

  if sample == nil then
    return
  end

  local drawn = sample(0)

  if drawn == nil or not canDrive(target, child.source, child.name, drawn) then
    return
  end

  -- an effect of its own on the same emit, so the draw outlives the dispatch
  -- that made it until the next frame and a clear still gives it back
  local fx = lifetime.effect(scope.emit, scope.depth, scope.effects)
  local rule = endOf(queue)
  local writer = lifetime.write(fx, target, child.source, child.name, rule)

  local function finish()
    lifetime.leave(writer)
    lifetime.release(fx)
  end

  if not lifetime.set(writer, drawn) then
    finish()
    return
  end

  task.defer(finish)
end

-- the randomizer children directly under an instance, applied before its
-- effect runs. an instance that is itself a randomizer counts as its own child,
-- which is how one is emitted on its own
local function processRandomizers(obj: Instance, scope: types.scope)
  local children = obj:GetChildren()

  if obj:IsA("RayValue") then
    table.insert(children, obj)
  end

  for _, child in children do
    if not child:IsA("RayValue") or child:HasTag(utility.SCREENSHAKE_TAG) then
      continue
    end

    local read = legacy_mods.readChild(child)

    if read == nil or not read.random then
      continue
    end

    local target = utility.getTarget(child)

    if target then
      utility.try(`failed to apply a randomizer with error: %s`, applyRandomizer, target, read, scope)
    end
  end
end

-- drives every Forge*Mods_* target on an instance that no effect module claims,
-- with no effect code written for that target. it only ever sees what
-- emitters.dispatch is handed, and the registry scan never selects a plain
-- descendant Part, so a tween authored on Part.Transparency runs only when
-- that Part is already selected for some other reason, a known limitation.
-- `owned` is keyed by source first, then name, because a name alone is not a
-- target: an instance can carry both a property and an attribute called Scale,
-- which is the ambiguity the two prefixes exist to remove
-- every target it drives is written through a writer, so two emits driving one
-- hand it over, and the last to end puts back what it held before.
-- `reflected`, a custom effect's mirrored properties, limits it to the panel
-- queues on those: true for every property, or the set it names. `map` is the
-- attributes a reader already read off the instance, so one with a module is
-- read once rather than once more here
function emitters.applyMods(
  obj: Instance,
  scope: types.scope,
  duration: number,
  owned: { [string]: { [string]: boolean } }?,
  reflected: registry.Reflected?,
  map: { [string]: any }?
)
  for key in (if map ~= nil then map else attr.map(obj)) do
    local source: string? = nil
    local name: string? = nil

    for candidate, prefix in mods.PREFIX do
      if string.sub(key, 1, #prefix) == prefix then
        source = candidate
        name = string.sub(key, #prefix + 1)
      end
    end

    if source == nil or name == nil then
      continue
    end

    if reflected ~= nil and (source ~= "property" or (reflected ~= true and not reflected[name :: string])) then
      continue
    end

    local claimed = owned and owned[source :: string]

    if claimed and claimed[name :: string] then
      continue
    end

    local lanes = mods.read(obj, source :: string, name :: string)
    -- the applier has no clock to fire an event from and no drawn lifetime to
    -- place an end against, so it drives the one lane that starts at the emit
    local queue = if lanes ~= nil then lanes.start else nil

    if queue == nil or #queue == 0 or mods.inert(queue) then
      continue
    end

    drive(obj, source :: string, name :: string, queue, scope, duration)
  end
end

emitters.drive = drive

-- the properties of `obj` that a Property Animator under it drives, which the
-- effect on `obj` leaves to it: an animator is the explicit ask. one that
-- names another target in its Target row claims nothing here
function emitters.claims(obj: Instance): { [string]: boolean }?
  local claimed: { [string]: boolean }? = nil

  for _, child in obj:GetChildren() do
    if not child:IsA("RayValue") or not child:HasTag(utility.PROPERTY_ANIMATOR_TAG) then
      continue
    end

    local name = child:GetAttribute("Property")
    local target = child:GetAttribute("Target")

    if type(name) ~= "string" or name == "" then
      continue
    end

    if target ~= nil and (typeof(target) ~= "InstanceHandle" or (target :: any):Get() ~= obj) then
      continue
    end

    claimed = claimed or {}
    (claimed :: any)[name] = true
  end

  return claimed
end

-- a legacy tween RayValue emitted on its own: the queue it spells drives
-- whatever it targets, under a lock so two emits of one template cannot drive
-- the same target twice. a randomizer RayValue is applied by the prologue of
-- its parent's dispatch and does nothing here
function emitters.legacy_child(obj: RayValue, scope: types.scope)
  local read = legacy_mods.readChild(obj)

  if read == nil or read.random then
    return
  end

  local target = utility.getTarget(obj)

  if not target or lifetime.lock(scope, obj) then
    return
  end

  drive(target, read.source, read.name, read.queue, scope, fallbackDuration(obj))
end

-- picks the emitter for an instance and calls it, after the randomizer
-- children under it have drawn and the queues on it have started. a driver is
-- an effect of the same emit, so nothing here has to wait for it: the emit
-- stays open until the last driver ends.
--
-- an instance the registry matched runs its module: every row read once, the
-- applier told which rows the module drives itself, then emit. everything
-- else gets only the applier and, for a legacy RayValue, its own drive.
-- `constant` marks an emit the ConstantVFX tick started, which a module reads
-- as ctx.constant. such a tick runs on a clock where an emit runs once, and
-- the randomizer draw and the applier belong to an emit, so it gets neither
function emitters.dispatch(
  obj: any,
  scope: types.scope,
  shared: reader.Shared,
  effect: registry.Module?,
  constant: boolean?
)
  -- a custom effect's instance plays through its rows alone: a randomizer
  -- child or a queue no row of it owns is the old format's leftover there,
  -- save a panel queue on a property it mirrors
  local own = effect ~= nil and registry.isCustom(effect)
  local reflected = if own then registry.reflected(effect :: registry.Module) else nil

  if not constant and not own then
    processRandomizers(obj, scope)
  end

  if effect then
    local ctx: reader.Ctx = {
      ref = obj,
      obj = obj,
      scope = scope,
      effect = effect,
      shared = shared,
      constant = constant,
    }
    local ok, attrs, props, map = utility.try(`failed to read {effect.id} with error: %s`, reader.resolve, effect, ctx)

    if not ok then
      return
    end

    local claimed = emitters.claims(obj)
    local owned = registry.owned(effect)

    if claimed ~= nil then
      local merged = table.clone(owned or {})
      local names = table.clone(merged.property or {})
      local quieted = table.clone(props)

      for name in claimed do
        names[name] = true

        -- the module's own tween of it writes nothing, leaving the animator
        -- the only writer
        local track = quieted[name]

        if type(track) == "table" then
          local quiet = table.clone(track)
          quiet.claimed = true
          quieted[name] = quiet
        end
      end

      props = table.freeze(quieted)

      merged.property = names
      owned = merged
    end

    if not constant and (not own or reflected ~= nil) then
      emitters.applyMods(obj, scope, ctx.duration :: number, owned, reflected, map)
    end

    utility.try(`failed to emit {effect.id} with error: %s`, effect.emit, ctx, attrs, props)

    return
  end

  emitters.applyMods(obj, scope, fallbackDuration(obj), nil)

  -- a legacy tween RayValue emitted on its own is the one effect left with no
  -- module: it drives what it targets. anything else nothing classifies is
  -- only a carrier of queues, which the applier has just started
  if obj:IsA("RayValue") then
    emitters.legacy_child(obj, scope)
  end
end

return emitters
