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

local pool = require("@srv/pool")

local timing_common = require("@mod/common/timing")

-- how many throwing writes a driven target gets before the applier gives up on
-- it, where a throw left to the scheduler would end the driver on the first
local MAX_WRITE_FAILURES = 3

local emitters = {}

-- the span each instance's effect was last dispatched with, which an effect
-- emitted beside it rather than nested in it can place its end against
local SPANS = setmetatable({} :: { [Instance]: number }, { __mode = "k" })

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

  -- every legacy entry ran from the emit on its own clock, so the last of them
  -- is the one that actually drove the target and its own flag decides
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

  -- every lane of the row, built against a span, in place of the queue's
  -- start lane alone
  track: mods.Track?,

  -- called once, when the driver has written its first value
  took: (() -> ())?,

  -- filled with a stop, which ends the driver where it is
  handle: { stop: (() -> ())? }?,

  -- called once the driver is let go, however it ends
  ended: (() -> ())?,

  -- the holder of the copy it drives, which ends the driver before it lets
  -- the copy go back to the pool, so no write lands on a copy another effect
  -- has taken since
  owner: any?,
}

-- an effect gives its pool takes back among its cleanups and a plain holder
-- in reverse order, so a deferred callback on one and a later entry in the
-- other both run while the copy is still this emit's
local function before(owner: any, release: () -> ())
  if type(owner) == "table" and owner.emit ~= nil then
    lifetime.defer(owner, release)
  else
    table.insert(owner, release)
  end
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
  duration: number,
  opts: DriveOpts?
)
  local track = if opts ~= nil then opts.track else nil
  local rolls, span, linked, sample

  if track ~= nil then
    span = math.max(track.span, track.reach("start"))
    linked = 0
    sample = function(elapsed: number)
      return track.at(elapsed)
    end
  else
    -- an old tween naming no start runs from what the target holds now
    queue = legacy_mods.fromRest(queue, currentOf(target, source, name))
    rolls = mods.roll(queue)
    span, linked = mods.span(queue, duration, rolls)
    sample = mods.sampler(target, source, name, span, queue, rolls, linked)
  end

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
  local speedAt, speedUntil, lead = nil, nil, 0

  if rolls ~= nil then
    speedAt, speedUntil, lead = speedOf(queue, rolls, linked)
  end

  local fx = lifetime.effect(scope.emit, scope.depth, scope.effects)

  if opts ~= nil and opts.owner ~= nil then
    before(opts.owner, function()
      lifetime.kill(fx)
    end)
  end

  lifetime.run(fx, function(driver)
    local failures = 0
    local wall = 0

    if opts ~= nil and opts.ended ~= nil then
      lifetime.hold(driver, opts.ended)
    end

    -- joined at its first write and let go with the driver, so a clear puts
    -- the target back too
    local writer = lifetime.write(driver, target, source, name, rule, start)

    local length = timing_common.duration(span)
    local ended = lifetime.join(driver)
    local counted = lifetime.add(ended)
    local elapsed = 0
    local ticking

    -- false once the target has refused too many writes to go on
    local function write(v: any): boolean
      if v ~= nil and took ~= nil then
        lifetime.set(writer, v)

        local first = took
        took = nil
        first()
      elseif v ~= nil and not lifetime.set(writer, v) then
        failures += 1

        if failures >= MAX_WRITE_FAILURES then
          logger.warn(`stopped driving {name} on {target:GetFullName()} after {failures} failed writes`)
          return false
        end
      end

      return true
    end

    -- how far the ramp's own clock moves this frame, nil once it is over
    local function advance(deltaTime: number): number?
      local waiting = elapsed < lead

      if not waiting then
        wall += deltaTime
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

    -- set on the step that writes the lane's last value, which is let go a
    -- step later, so even a lane shorter than a frame is drawn before its end
    -- rule puts the target back
    local finished = false

    -- each value at the end of its frame, as a tween samples, so a lane keeps
    -- time with the effect's own tracks
    ticking = lifetime.step(driver, function(deltaTime: number)
      if finished then
        stop()
        return
      end

      local moved = advance(deltaTime)

      if moved == nil then
        stop()
        return
      end

      elapsed = math.clamp(elapsed + moved, 0, math.max(length, 0.001))

      if not write(sample(elapsed)) then
        stop()
        return
      end

      finished = timing_common.done(elapsed, length)
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
  -- that made it until the next frame and a clear still gives it back. It
  -- writes the instance dispatch was handed, before the effect reads it,
  -- which may be a piece an effect took from the pool and lets go before
  -- that next frame. A copy taken whole (a mesh's, a bezier's or a
  -- shockwave piece's emitNested) holds this randomizer, a child, so the
  -- pool destroys it as its holder lets go. A single taken alone and kept
  -- on a stack (lightning's Head mode moves the nested children onto its
  -- first segment and emits from it) may be taken by another effect in the
  -- same frame: the pool drops every writer on a piece it keeps, this one
  -- too, so its give-back never reaches the next holder (emitters.spec)
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

    local target, read = utility.driverOf(child)

    if read == nil or not read.random then
      continue
    end

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
-- read once rather than once more here. `from` is the instance the queues are
-- stored on when `obj` is a copy an effect plays on, and `owner` the holder of
-- that copy (DriveOpts.owner)
function emitters.applyMods(
  obj: Instance,
  scope: types.scope,
  duration: number,
  owned: { [string]: { [string]: boolean } }?,
  reflected: registry.Reflected?,
  map: { [string]: any }?,
  from: Instance?,
  owner: any?
)
  const stored = from or obj
  const opts = if owner ~= nil then { owner = owner } else nil

  for key in (if map ~= nil then map else attr.map(stored)) do
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

    local lanes = mods.read(stored, source :: string, name :: string)
    -- the applier has no clock to fire an event from and no drawn lifetime to
    -- place an end against, so it drives the one lane that starts at the emit.
    -- an outlasting entry is the piece's own driver's, started with its
    -- children
    local queue = if lanes ~= nil then mods.applied(lanes).start else nil

    if queue == nil or #queue == 0 or mods.inert(queue) then
      continue
    end

    drive(obj, source :: string, name :: string, queue, scope, duration, opts)
  end
end

emitters.drive = drive

type Lasting = { { source: string, name: string, queue: { any } } }

-- the attributes each instance's last dispatch read, which every piece it
-- copies asks its outlasting entries of, and what those are, worked out once
-- per such read: false when there is none. both weak, the second by the map,
-- which nothing in its answer names
const READ: { [Instance]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any
const LASTING: { [any]: Lasting | false } = setmetatable({}, { __mode = "k" }) :: any

-- every outlasting queue stored on `from`, as the target each drives
function emitters.outlasting(from: Instance): Lasting?
  const map = READ[from] or attr.map(from)
  const known = LASTING[map]

  if known ~= nil then
    return if known == false then nil else known
  end

  local out: Lasting? = nil

  for key, raw in map do
    if type(raw) ~= "string" then
      continue
    end

    for source, prefix in mods.PREFIX do
      if string.sub(key, 1, #prefix) ~= prefix then
        continue
      end

      const name = string.sub(key, #prefix + 1)
      const lanes = mods.framed(from, source, name, map)
      const groups = if lanes ~= nil then mods.outlasting(lanes) else nil

      for _, queue in groups or {} do
        out = out or {}
        table.insert(out :: Lasting, { source = source, name = name, queue = queue })
      end
    end
  end

  LASTING[map] = out or false

  return out
end

-- the outlasting queues stored on the instance a piece was copied from,
-- driven on the piece as the old child each came from drove: a driver of its
-- own on the emit of the piece's children, holding the piece up until it ends
-- and putting back what its reset says as it does. an entry naming no
-- duration runs over `span`, the effect's, as it would on the row's own track,
-- and a share is a share of it
function emitters.outlast(
  piece: Instance,
  queues: { { source: string, name: string, queue: { any } } },
  scope: types.scope,
  span: number?
)
  const over = if typeof(span) == "number" and span > 0 and span ~= math.huge then span else 1

  for _, held in queues do
    drive(piece, held.source, held.name, held.queue, scope, over)
  end
end

-- the span of the effect an animator's end lane is placed against: the one
-- whose nested children it plays among, else the last dispatch of `host`
function emitters.hostSpan(scope: types.scope, host: Instance?): number?
  local nested = scope.emit.host

  if nested ~= nil and nested.span ~= nil then
    return nested.span
  end

  return if host ~= nil then SPANS[host] else nil
end

-- the properties of `obj` that a Property Animator under it drives, which the
-- effect on `obj` leaves to it: an animator is the explicit ask. one that
-- names another target in its Target row claims nothing here
function emitters.animated(obj: Instance): { [string]: boolean }?
  if obj:FindFirstChildWhichIsA("RayValue") == nil then
    return nil
  end

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

    -- a handle to an instance no longer in the place reads as empty, as the
    -- animator itself reads it, and leaves the parent its target
    local named = if typeof(target) == "InstanceHandle" then (target :: any):Get() else nil

    if named ~= nil and not named:IsDescendantOf(game) then
      named = nil
    end

    if target ~= nil and named ~= nil and named ~= obj then
      continue
    end

    claimed = claimed or {}
    (claimed :: any)[name] = true
  end

  return claimed
end

-- whether `obj` is a mesh piece's copy of the Start side of its model's decal
-- pair, the decal the mesh plays its color on. the pair's shape is checked
-- before the registry is asked, and the model as the copy's template names it
const function meshDecal(obj: Instance): boolean
  const side = obj.Parent

  if side == nil or side.Name ~= "Start" then
    return false
  end

  const template = pool.templateOf(obj)
  const start = if template ~= nil then template.Parent else nil
  const model = if start ~= nil then start.Parent else nil

  if template == nil or model == nil or not model:IsA("Model") or model.Parent == game then
    return false
  end

  const goal = model:FindFirstChild("End")
  const twin = if goal ~= nil then goal:FindFirstChild(template.Name) else nil

  if twin == nil or not twin:IsA("Decal") or attr.get(model, "Flipbook", false, true) == true then
    return false
  end

  const module = registry.of(model)

  return module ~= nil and module.id == "mesh"
end

-- whether `obj` is a decal on a piece of the Mesh effect, which plays the
-- decal's color on the piece's own copy
const function forgeMeshDecal(obj: Instance): boolean
  const template = pool.templateOf(obj)
  const owner = if template ~= nil then template.Parent else nil

  if owner == nil or not owner:IsA("BasePart") then
    return false
  end

  const module = registry.of(owner)

  return module ~= nil and module.id == "forge_mesh"
end

-- what the effect on `obj` leaves to another writer: whatever an animator
-- under it drives, and a decal's Color3 where its mesh plays it, multiplying it
-- by the strength when it glows by its color. a mesh plays its pair's color in
-- every glow mode, so the color and the mesh's own tracks share one clock
function emitters.claims(obj: Instance): { [string]: boolean }?
  const animated = emitters.animated(obj)

  if not obj:IsA("Decal") then
    return animated
  end

  if attr.get(obj, "GlowMode", "None", true) ~= "Color" and not meshDecal(obj) and not forgeMeshDecal(obj) then
    return animated
  end

  const claimed = if animated ~= nil then animated else {}

  claimed.Color3 = true

  return claimed
end

-- a legacy tween RayValue emitted on its own: the queue it spells drives
-- whatever it targets, under a lock so two emits of one template cannot drive
-- the same target twice. a randomizer RayValue is applied by the prologue of
-- its parent's dispatch and does nothing here
function emitters.legacy_child(obj: RayValue, scope: types.scope)
  local target, read = utility.driverOf(obj)

  if read == nil or read.random then
    return
  end

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

    SPANS[obj] = ctx.duration
    READ[obj] = map
    scope.span = ctx.duration

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

    -- an animator's lane map is its target's row, which the animator plays
    local animates = obj:HasTag(utility.PROPERTY_ANIMATOR_TAG)

    if not constant and not animates and (not own or reflected ~= nil) then
      -- an effect that plays on a copy hands each copy over once it has made
      -- it, or the queues would drive the instance it was copied from
      local copies = effect.copies

      if type(copies) == "function" then
        copies = copies(obj)
      end

      if copies then
        ctx.copied = function(copy: Instance, holder: any)
          if copy == obj then
            emitters.applyMods(obj, scope, ctx.duration :: number, owned, reflected, map)
          else
            emitters.applyMods(copy, scope, ctx.duration :: number, owned, reflected, map, obj, holder)
          end
        end
      else
        emitters.applyMods(obj, scope, ctx.duration :: number, owned, reflected, map)
      end
    end

    utility.try(`failed to emit {effect.id} with error: %s`, effect.emit, ctx, attrs, props)

    return
  end

  const claimed = emitters.claims(obj)

  emitters.applyMods(obj, scope, fallbackDuration(obj), if claimed ~= nil then { property = claimed } else nil)

  -- a legacy tween RayValue emitted on its own is the one effect left with no
  -- module: it drives what it targets. anything else nothing classifies is
  -- only a carrier of queues, which the applier has just started
  if obj:IsA("RayValue") then
    emitters.legacy_child(obj, scope)
  end
end

return emitters
