local Beam = require("@vfx/beam")
local Spin = require("@vfx/spin")
local Mesh = require("@vfx/mesh")
local Sound = require("@vfx/sound")
local Bezier = require("@vfx/bezier")
local Screen = require("@vfx/screen")
local Particle = require("@vfx/particle")
local Lightning = require("@vfx/lightning")
local CameraShake = require("@vfx/camera_shake")
local ShockwaveRing = require("@vfx/shockwave_ring")
local ShockwaveLine = require("@vfx/shockwave_line")
local ShockwaveDebris = require("@vfx/shockwave_debris")

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

local Promise = require("@pkg/Promise")

-- how many throwing writes a driven target gets before the applier gives up on
-- it. an unguarded write throws from inside a render step binding, which never
-- advances the timer that would otherwise end it
local MAX_WRITE_FAILURES = 3

local emitters = {}

-- the reader binds a track on an effect's scope through the same helper every
-- effect steps with, handed in here because the reader stays engine-free
reader.drive = tween.drive

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
-- emitters.dispatch is handed, and services/effects.luau's EffectSelectors
-- never selects a plain descendant Part, so a tween authored on
-- Part.Transparency runs only when that Part is already selected for some other
-- reason. see the 2026-07-25 modifier accordion and runtime design spec,
-- Section 3, "Known limitation, recorded 2026-08-01"
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

function emitters.particle(
  obj: ParticleEmitter,
  scope: types.scope,
  sharedUncMap: { [Instance]: number },
  sharedRefMap: { [Instance]: Instance },
  legacyScale: number
)
  local count = attr.get(obj, "EmitCount", utility.PLUGIN_CONTEXT and 1 or nil)
  local duration = attr.get(obj, "EmitDuration", 0, true)

  if not count or (count <= 0 and duration <= 0) then
    return
  end

  if not obj:IsDescendantOf(workspace) then
    local parent, ancestor = utility.cloneParticleAncestry(obj, sharedRefMap)

    if not parent then
      return
    end

    local clone = obj:Clone()
    clone.Archivable = false
    clone.Parent = parent

    if not sharedUncMap[ancestor] then
      ancestor.Parent = workspace.Terrain
      sharedUncMap[ancestor] = 1
    else
      sharedUncMap[ancestor] += 1
    end

    lifetime.hold(scope, function()
      sharedUncMap[ancestor] -= 1

      if sharedUncMap[ancestor] <= 0 then
        ancestor:Destroy()
      end
    end)

    utility.try(`failed to emit particle with error: %s`, Particle.emit, obj, clone, scope, legacyScale)
  else
    utility.try(`failed to emit particle with error: %s`, Particle.emit, obj, obj, scope, legacyScale)
  end
end

function emitters.beam(obj: Beam, scope: types.scope, legacyScale: number)
  local att0, att1 = obj.Attachment0, obj.Attachment1

  if not att0 or not att1 then
    return
  end

  local clone = obj:Clone()
  clone.Archivable = false
  clone.Parent = workspace.Terrain

  -- clone attachments for beams that scale their length. getting this wrong is
  -- not cosmetic: beam.emit's setLengthScale would move the real attachments
  -- instead of throwaway clones, and the scope teardown that restores them runs
  -- on the emitted beam
  --
  -- anything authored on Length_Scale, a queue or a legacy quad, means the
  -- beam moves attachments, and the draw beam.emit makes for itself is not
  -- the one this decision has to agree with: an authored constant of one
  -- still gets throwaway clones, which costs two attachments and nothing else
  if mods.track(obj, "attribute", "Length_Scale", 1, 1).animated then
    local a, b = att0:Clone(), att1:Clone()

    lifetime.hold(scope, a)
    lifetime.hold(scope, b)

    a.Name = "_ForgeTempAttachment"
    b.Name = "_ForgeTempAttachment"

    a:AddTag(utility.EMIT_EXCLUDE_TAG)
    b:AddTag(utility.EMIT_EXCLUDE_TAG)

    clone.Attachment0 = a
    clone.Attachment1 = b

    a.Parent = att0.Parent
    b.Parent = att1.Parent
  end

  lifetime.hold(scope, clone)

  utility.try(`failed to emit beam with error: %s`, Beam.emit, obj, clone, scope, legacyScale)
end

function emitters.trail(obj: Trail)
  obj.Enabled = true
end

function emitters.bezier(obj: Instance, scope: types.scope, skipEnabledCheck: boolean?)
  local part = obj:FindFirstChildOfClass("Part")

  if not part then
    return
  end

  if not skipEnabledCheck and obj:GetAttribute("Enabled") then
    obj:SetAttribute("Enabled", false)
  end

  local clone = part:Clone()
  clone.Locked = true

  lifetime.hold(scope, clone)

  utility.try(`failed to emit bezier with error: %s`, Bezier.emit, obj, clone, scope, skipEnabledCheck)
end

function emitters.lightning(obj: Instance, scope: types.scope, skipEnabledCheck: boolean?)
  local part = obj:FindFirstChildOfClass("Part")

  if not part then
    return
  end

  if not skipEnabledCheck and obj:GetAttribute("Enabled") then
    obj:SetAttribute("Enabled", false)
  end

  local clone = part:Clone()
  clone.Locked = true

  lifetime.hold(scope, clone)

  utility.try(`failed to emit lightning with error: %s`, Lightning.emit, obj, clone, scope, skipEnabledCheck)
end

function emitters.mesh(
  obj: Instance,
  scope: types.scope,
  shared_part_cache: any,
  legacyScale: number,
  skipEnabledCheck: boolean?
)
  local start = obj:FindFirstChild("Start")

  if not start then
    return
  end

  if not skipEnabledCheck and obj:GetAttribute("Enabled") then
    obj:SetAttribute("Enabled", false)
  end

  local tasks = {}
  local promises = scope.emit.promises

  local useEmitDuration = obj:HasTag(utility.ENABLED_VFX_TAG) and attr.get(obj, "EmitDuration", 0) > 0
  local emitCount = if useEmitDuration and not skipEnabledCheck then 1 else attr.get(obj, "EmitCount", 1)

  for i = 1, emitCount do
    local promise = Promise.new(function(resolve)
      utility.try(
        `failed to emit mesh with error: %s`,
        Mesh.emit,
        obj,
        utility.assembleMeshVFX(start, scope, shared_part_cache),
        scope,
        legacyScale,
        skipEnabledCheck
      )

      resolve()
    end)

    table.insert(tasks, promise)
    table.insert(promises, promise)
  end

  Promise.all(tasks):await()

  -- a settled promise has nothing left to cancel, and a ConstantVFX mesh emits
  -- for as long as it stays enabled, so leaving these in place grew the list
  -- by one per emit for the life of the effect
  for _, promise in tasks do
    local index = table.find(promises, promise)

    if index then
      table.remove(promises, index)
    end
  end
end

function emitters.spin(obj: Model, scope: types.scope)
  if lifetime.lock(scope, obj) then
    return
  end

  utility.try(`failed to emit spinning model with error: %s`, Spin.emit, obj, scope)
end

function emitters.camera_shake(obj: RayValue, scope: types.scope)
  utility.try(`failed to emit camera shake with error: %s`, CameraShake.emit, obj, scope)
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

function emitters.screen(obj: BasePart, scope: types.scope)
  local ok, result = utility.try(`failed to emit screen effect with error: %s`, Screen.emit, obj, scope)

  return if ok then result else false
end

function emitters.shockwave_ring(att: Attachment, obj: Part, scope: types.scope)
  utility.try(`failed to emit shockwave ring with error: %s`, ShockwaveRing.emit, att, obj, scope)
end

function emitters.shockwave_debris(att: Attachment, obj: Part, scope: types.scope)
  utility.try(`failed to emit shockwave debris with error: %s`, ShockwaveDebris.emit, att, obj, scope)
end

function emitters.shockwave_line(att: Attachment, obj: Part, scope: types.scope)
  utility.try(`failed to emit shockwave line with error: %s`, ShockwaveLine.emit, att, obj, scope)
end

function emitters.sound(obj: Sound, scope: types.scope)
  local emitCount = attr.get(obj, "EmitCount", 1, true)

  if emitCount <= 0 then
    return
  end

  utility.try(`failed to emit sound with error: %s`, Sound.emit, obj, scope)
end

-- names a converted effect drives through its own sampler. this mirrors
-- dispatch's branch selection below and has to move with it, which is what the
-- ownership test in tests/roblox/mods.spec.luau exists to catch
local function ownedFor(obj: any, className: string): { [string]: { [string]: boolean } }?
  if className == "Model" then
    return if utility.isMeshVFX(obj) then Mesh.OWNS else Spin.OWNS
  end

  if className == "Beam" then
    return Beam.OWNS
  end

  if className == "Sound" then
    return Sound.OWNS
  end

  if className == "ParticleEmitter" then
    return Particle.OWNS
  end

  if obj:HasTag(utility.BEZIER_TAG) then
    return Bezier.OWNS
  end

  if obj:HasTag(utility.LIGHTNING_TAG) then
    return Lightning.OWNS
  end

  if className == "RayValue" and obj:HasTag(utility.SCREENSHAKE_TAG) then
    return CameraShake.OWNS
  end

  -- the same discriminator dispatch uses for a shockwave: a Part under a tagged
  -- Attachment, told apart by the folder it sits in
  if className == "Part" and utility.findFirstClassWithTag(obj, "Attachment", utility.SHOCKWAVE_TAG) then
    local folder = obj.Parent and obj.Parent.Name or ""

    if folder == "Rings" then
      return ShockwaveRing.OWNS
    elseif folder == "Debris" then
      return ShockwaveDebris.OWNS
    elseif folder == "Lines" then
      return ShockwaveLine.OWNS
    end
  end

  return nil
end

-- picks the emitter for an instance and calls it. wrapped by emitters.dispatch,
-- which owns the prologue
local function route(
  obj: any, -- since we don't use IsA(...), we don't get type narrowing
  scope: types.scope,
  sharedUncMap: { [Instance]: number },
  sharedRefMap: { [Instance]: Instance },
  shared_part_cache: any,
  legacyScale: number
)
  local className = obj.ClassName

  if className == "ParticleEmitter" then
    emitters.particle(obj, scope, sharedUncMap, sharedRefMap, legacyScale)
    return
  elseif className == "Beam" then
    emitters.beam(obj, scope, legacyScale)
    return
  elseif className == "Trail" then
    emitters.trail(obj)
    return
  elseif className == "Sound" then
    emitters.sound(obj, scope)
    return
  elseif className == "RayValue" then
    if obj:HasTag(utility.SCREENSHAKE_TAG) then
      emitters.camera_shake(obj, scope)
    else
      emitters.legacy_child(obj, scope)
    end

    return
  end

  if obj:HasTag(utility.BEZIER_TAG) then
    emitters.bezier(obj, scope)
    return
  end

  if obj:HasTag(utility.LIGHTNING_TAG) then
    emitters.lightning(obj, scope)
    return
  end

  -- a screen effect reached as a DESCENDANT. the top-level loop in
  -- services/effects.luau handles a directly emitted one and never calls
  -- dispatch for it, so without this branch an Enabled BasePart is selected,
  -- handed here, and falls through every case. the predicate mirrors that
  -- loop's, including the shockwave exclusion, so the two paths agree on what
  -- a screen effect is
  if
    obj:IsA("BasePart")
    and obj:GetAttribute("Enabled")
    and not utility.findFirstClassWithTag(obj, "Attachment", utility.SHOCKWAVE_TAG)
  then
    emitters.screen(obj, scope)
    return
  end

  if className == "Model" then
    if utility.isMeshVFX(obj) then
      emitters.mesh(obj, scope, shared_part_cache, legacyScale)
    else
      emitters.spin(obj, scope)
    end

    return
  end

  if className == "Part" then
    local att = utility.findFirstClassWithTag(obj, "Attachment", utility.SHOCKWAVE_TAG)

    if att then
      local name = obj.Parent and obj.Parent.Name or ""

      if name == "Rings" then
        emitters.shockwave_ring(att, obj, scope)
      elseif name == "Debris" then
        emitters.shockwave_debris(att, obj, scope)
      elseif name == "Lines" then
        emitters.shockwave_line(att, obj, scope)
      end
    end
  end
end

-- picks the emitter for an instance and calls it, after the randomizer
-- children under it have drawn and the queues on it have started. a driver is
-- an effect of the same emit, so nothing here has to wait for it: the emit
-- stays open until the last driver ends.
--
-- an instance the registry matched runs its module: every row read once, the
-- applier told which rows the module drives itself, then emit. everything else
-- takes the route below until its module exists
function emitters.dispatch(
  obj: any,
  scope: types.scope,
  sharedUncMap: { [Instance]: number },
  sharedRefMap: { [Instance]: Instance },
  shared_part_cache: any,
  legacyScale: number,
  effect: registry.Module?
)
  processRandomizers(obj)

  if effect then
    local ctx: reader.Ctx = { ref = obj, obj = obj, scope = scope, scale = legacyScale, effect = effect }
    local ok, attrs, props = utility.try(`failed to read {effect.id} with error: %s`, reader.resolve, effect, ctx)

    if not ok then
      return
    end

    emitters.applyMods(obj, scope, ctx.duration :: number, registry.owned(effect))
    utility.try(`failed to emit {effect.id} with error: %s`, effect.emit, ctx, attrs, props)

    return
  end

  emitters.applyMods(obj, scope, fallbackDuration(obj), ownedFor(obj, obj.ClassName))

  route(obj, scope, sharedUncMap, sharedRefMap, shared_part_cache, legacyScale)
end

-- Registry for enabled effects (effects that emit continuously)
type EnabledEffectConfig = {
  check: (obj: Instance) -> boolean,
  emit: (obj: Instance, scope: types.scope, shared_part_cache: any) -> (),
}

emitters.enabled_registry = {
  mesh = {
    check = function(obj: Instance)
      return utility.isMeshVFX(obj)
    end,
    emit = function(obj: Instance, scope: types.scope, shared_part_cache: any)
      emitters.mesh(obj, scope, shared_part_cache, 1, true)
    end,
  },

  bezier = {
    check = function(obj: Instance)
      return obj:HasTag(utility.BEZIER_TAG)
    end,
    emit = function(obj: Instance, scope: types.scope, shared_part_cache: any)
      emitters.bezier(obj, scope, true)
    end,
  },

  lightning = {
    check = function(obj: Instance)
      return obj:HasTag(utility.LIGHTNING_TAG)
    end,
    emit = function(obj: Instance, scope: types.scope, shared_part_cache: any)
      emitters.lightning(obj, scope, true)
    end,
  },
} :: { [string]: EnabledEffectConfig }

return emitters
