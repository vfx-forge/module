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

-- how many throwing writes a driven target gets before the applier gives up on
-- it. an unguarded write throws from inside a render step binding, which never
-- advances the timer that would otherwise end it
local MAX_WRITE_FAILURES = 3

local emitters = {}

-- the reader binds a track on an effect's scope through the same helper every
-- effect steps with, handed in here because the reader stays engine-free
reader.bind = tween.drive

-- the attribute arm goes through the cache-aware write, so a driven or restored
-- attribute lands where every reader on this path looks for it
local function writeTarget(obj: Instance, source: string, name: string, v: any)
  if source == "property" then
    (obj :: any)[name] = v
  else
    attr.set(obj, name, v)
  end
end

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
-- one and otherwise to the value the target held at emit time, a randomizer
-- always to that pre-drive value. legacy_mods lifts the flag onto its entries
-- as `reset`, and those two collapse to one rule. a queue authored in the
-- modifier panel carries no `reset` at all and gets no restore, because the
-- panel presents a modifier as what the value IS
local function resetTo(queue: { any }, snapshot: any): (boolean, any)
  local wants = false
  local restore = snapshot

  -- legacy entries never chain, so the last of them is the one that actually
  -- drove the target and its own flag is the one that decides
  for _, m in queue do
    if m.reset ~= true then
      continue
    end

    wants = true
    restore = if m.kind ~= "randomizer" and m.start ~= nil then value.resolve(m.start) else snapshot
  end

  return wants, restore
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

-- a wait the queue spells out as a literal, for the reach a ramp sits behind.
-- anything drawn per instance is not a fixed lead and counts as none, which is
-- also what a nan wait has to mean, since no clock can wait one out
local function litWait(m: any): number
  if type(m.wait) ~= "table" or not value.isLit(m.wait) then
    return 0
  end

  local waited = value.resolve(m.wait)

  if type(waited) ~= "number" or waited ~= waited or waited <= 0 then
    return 0
  end

  return waited
end

-- the speed ramp a legacy tween child carried, as a multiplier on the clock
-- the timer counts, how long that ramp runs, and the lead it sits behind: the
-- waits of every delay ahead of it, which belong to no ramp. it goes by wall
-- time the way the child's own speed tween did, beside the tween it scales
local function speedOf(queue: { any }): (((wall: number) -> number)?, number?, number)
  local lead = 0

  for _, m in queue do
    local ramp = m.speed

    if type(ramp) ~= "table" then
      if m.kind == "delay" then
        lead += litWait(m)
      end

      continue
    end

    local function speedAt(wall: number): number
      local progress = if ramp.duration > 0 then math.clamp(wall / ramp.duration, 0, 1) else 1
      return utility.lerp(ramp.start, ramp.finish, modifiers.alphaFromCurve(ramp.curve, progress))
    end

    return speedAt, ramp.duration, lead
  end

  return nil, nil, 0
end

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
  duration: number
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

  local wants, restore = resetTo(queue, currentOf(target, source, name))
  local speedAt, speedUntil, lead = speedOf(queue)

  local fx = lifetime.effect(scope.emit, scope.depth, scope.effects)

  lifetime.run(fx, function(driver)
    local failures = 0
    local wall = 0

    -- the restore rides the record rather than the line after the timer, so a
    -- clear runs it too. a release fires this whether the driver reached its
    -- own end or was cancelled, which is what the legacy child did by holding
    -- its restore in the scope
    if wants and restore ~= nil then
      lifetime.defer(driver, function()
        pcall(writeTarget, target, source, name, restore)
      end)
    end

    tween.timer(span, function(deltaTime, elapsed)
      local waiting = elapsed < lead

      if not waiting then
        wall += deltaTime
      end

      local v = sample(elapsed)

      if v ~= nil and not pcall(writeTarget, target, source, name, v) then
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
      -- moving is not the end, so the timer only gives up once the ramp has
      -- settled there
      return if scaled > 0 or (speedUntil ~= nil and wall < speedUntil) then scaled else nil
    end, nil, driver, utility.RENDER_PRIORITY + driver.depth)
  end)
end

-- a randomizer child is applied before the effect it sits under reads its
-- target, and with `reset` the target goes back on the next frame, after that
-- effect has read the drawn value. driving it through the timer would do the
-- same one frame later than the effect needs
local function applyRandomizer(target: Instance, child: legacy_mods.Child)
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

  local wants, restore = resetTo(queue, currentOf(target, child.source, child.name))

  if not pcall(writeTarget, target, child.source, child.name, drawn) then
    return
  end

  if wants and restore ~= nil then
    task.defer(function()
      pcall(writeTarget, target, child.source, child.name, restore)
    end)
  end
end

-- the randomizer children directly under an instance, applied before its
-- effect runs. an instance that is itself a randomizer counts as its own child,
-- which is how one is emitted on its own
local function processRandomizers(obj: Instance)
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
      utility.try(`failed to apply a randomizer with error: %s`, applyRandomizer, target, read)
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
function emitters.applyMods(
  obj: Instance,
  scope: types.scope,
  duration: number,
  owned: { [string]: { [string]: boolean } }?
)
  for _, key in attr.keys(obj) do
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

    local claimed = owned and owned[source :: string]

    if claimed and claimed[name :: string] then
      continue
    end

    local queue = mods.read(obj, source :: string, name :: string)

    if queue == nil or #queue == 0 or mods.inert(queue) then
      continue
    end

    drive(obj, source :: string, name :: string, queue, scope, duration)
  end
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
  legacyScale: number,
  effect: registry.Module?,
  constant: boolean?
)
  if not constant then
    processRandomizers(obj)
  end

  if effect then
    local ctx: reader.Ctx = {
      ref = obj,
      obj = obj,
      scope = scope,
      scale = legacyScale,
      effect = effect,
      shared = shared,
      constant = constant,
    }
    local ok, attrs, props = utility.try(`failed to read {effect.id} with error: %s`, reader.resolve, effect, ctx)

    if not ok then
      return
    end

    if not constant then
      emitters.applyMods(obj, scope, ctx.duration :: number, registry.owned(effect))
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
