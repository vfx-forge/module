local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local modifiers = require("@mod/modifiers")
local legacy_mods = require("@mod/legacy_mods")

local mods = {}

-- split by target source so the runtime knows whether to write ref[name] or
-- ref:SetAttribute(name, v), and so an instance carrying both a property and
-- an attribute of one name never confuses the two
mods.PREFIX = {
  property = "ForgePropMods_",
  attribute = "ForgeAttrMods_",
}

function mods.attrName(source: string, name: string): string
  return mods.PREFIX[source] .. name
end

-- everything a queue needs that belongs to ONE emitted instance: the draws,
-- made here, and the environment a `var` resolves against, which the caller
-- supplies because it is shared with the other queues on that instance. both
-- travel together because both decide what the span is
export type Rolls = {
  draws: { [number]: modifiers.Draw },
  picks: { [number]: modifiers.Picks },
  env: { [string]: any }?,
  envelope: number,
}

-- how long a queue runs on its own terms, for a caller with no effect duration
-- to lend it. a delay pushes what follows it out, so the answer is the far end
-- of the queue rather than its longest single duration, and a caller whose
-- delay is drawn per instance passes the rolls in so the span is the one THIS
-- instance will run
function mods.span(queue: { any }, fallback: number, rolls: Rolls?): (number, number)
  local picks = if rolls then rolls.picks else nil

  -- schedule seeds a linked modifier's run from the fallback, so a nan one
  -- poisons every offset in the queue and the span comes back nan. zero makes
  -- the frontier the far end of the authored durations instead
  if fallback ~= fallback then
    fallback = 0
  end

  local _, frontier, linked = modifiers.schedule(queue, picks, fallback, if rolls then rolls.env else nil)

  -- an effect turns this straight into a tween's duration, and a tween that
  -- never ends holds the emit open for good. nothing an author can mean by a
  -- span is infinite, so an unusable one falls back the same way an empty one does
  if frontier ~= frontier or frontier <= 0 or frontier == math.huge then
    return fallback, linked
  end

  return frontier, linked
end

-- a queue that waits and does nothing else. its delays still push a clock
-- around, but nothing in it produces a value, so driving it writes the target's
-- own value back every frame for the length of the waits and holds the emit
-- open while it does. mods.driver's sample(0) guard catches the base-only case
-- on an attribute, whose base is usually nil, but not on a property, whose base
-- is whatever it currently holds
function mods.inert(queue: { any }): boolean
  local waits = false

  for _, m in queue do
    if m.kind == "delay" then
      waits = true
      continue
    end

    if not modifiers.BASE_KINDS[m.kind] then
      return false
    end
  end

  return waits
end

-- the framed attribute decoded on its own, with no legacy fallback. an EMPTY
-- queue is a tombstone the authoring side writes deliberately, so a caller
-- asking whether anything is authored here has to tell it apart from an absent
-- attribute, which mods.read cannot once it has fallen through
function mods.framed(ref: Instance, source: string, name: string): { any }?
  local raw = ref:GetAttribute(mods.attrName(source, name))

  if not frame.isFramed(raw) then
    return nil
  end

  local body = frame.unframe(raw)

  if body == nil then
    logger.warn(`{name} carries a framed modifier queue that could not be read`)
    return nil
  end

  local ok, decoded = pcall(codec.decode, body)

  if ok and decoded then
    return decoded.queue
  end

  logger.warn(`failed to decode the modifier queue on {name}`)

  return nil
end

function mods.read(ref: Instance, source: string, name: string): { any }?
  local queue = mods.framed(ref, source, name)

  if queue ~= nil then
    return queue
  end

  return legacy_mods.read(ref, source, name)
end

-- the value a target already carries, which is what a base entry resolves to
local function baseOf(ref: Instance, source: string, name: string): any
  if source ~= "property" then
    return ref:GetAttribute(name)
  end

  local ok, current = pcall(function()
    return (ref :: any)[name]
  end)

  return if ok then current else nil
end

-- whether a randomizer draws each axis on its own rather than one alpha for the
-- whole vector. only the shape that ASKS for it does, which is a legacy Min/Max
-- pair: a pair names a box, and a size drawn inside it keeps its own
-- proportions, where one alpha would only ever scale a copy of the same shape.
-- two endpoints name a segment instead, so a RayValue randomizer child and an
-- authored one keep drawing along it, exactly as the legacy randomizer always
-- did for the same data.
--
-- both ends have to resolve to vectors, because evaluate's per-component branch
-- needs two to interpolate between. resolved rather than read raw, so a var
-- endpoint is judged on what it holds for this instance
local function componentEnds(m: any, env: { [string]: any }?): boolean
  if not m.perComponent then
    return false
  end

  local startVal = if m.start then value.resolve(m.start, nil, env) else nil
  local finishVal = if m.finish then value.resolve(m.finish, nil, env) else nil

  return typeof(startVal) == "Vector3" and typeof(finishVal) == "Vector3"
end

-- randomizer alphas, rand endpoints, delayed waits and the envelope offset are
-- all drawn HERE, once, which is once per emitted instance. that makes "one
-- draw per instance" structural rather than a rule every call site has to
-- remember. it is its own function because a drawn delay moves the far end of
-- the queue, so a caller that needs the SPAN first has to draw before it can
-- ask for one, and then hand the same rolls to the sampler
function mods.roll(queue: { any }, env: { [string]: any }?): Rolls
  local rng = Random.new()
  local draws = {}
  local picks = {}

  for i, m in queue do
    if m.kind == "randomizer" then
      local first = rng:NextNumber()

      -- the first draw stays the first call either way, so a queue that does
      -- not draw per component keeps the draw order it always had
      if componentEnds(m, env) then
        draws[i] = { first, rng:NextNumber(), rng:NextNumber() }
      else
        draws[i] = first
      end
    end

    local startRand = m.start ~= nil and value.isRand(m.start)
    local finishRand = m.finish ~= nil and value.isRand(m.finish)
    local waitRand = type(m.wait) == "table" and value.isRand(m.wait)

    if startRand or finishRand or waitRand then
      picks[i] = {
        start = if startRand then rng:NextNumber() else nil,
        finish = if finishRand then rng:NextNumber() else nil,
        wait = if waitRand then rng:NextNumber() else nil,
      }
    end
  end

  return { draws = draws, picks = picks, env = env, envelope = rng:NextNumber() * 2 - 1 }
end

-- a caller that already read the queue, to span it or to test it, passes it
-- back in rather than paying a second base64 plus buffer decode for the same
-- attribute, and passes its rolls back in so the span it computed and the
-- sampler it gets are drawn from the same hat
function mods.sampler(
  ref: Instance,
  source: string,
  name: string,
  duration: number,
  preread: { any }?,
  rolls: Rolls?,
  linked: number?
): ((number) -> any)?
  local queue = preread or mods.read(ref, source, name)

  if queue == nil or #queue == 0 then
    return nil
  end

  local rolled = rolls or mods.roll(queue)
  -- `duration` is the reach, which a delay inflates. seeding the linked run
  -- from it would stretch every modifier that names no duration and leave a
  -- delayed one short of its finish, so a caller that knows what it lent says so
  local lent = if linked ~= nil then linked else duration
  local offsets, _, resolved = modifiers.schedule(queue, rolled.picks, lent, rolled.env)

  local ctx: modifiers.Ctx = {
    duration = duration,
    base = baseOf(ref, source, name),
    draws = rolled.draws,
    picks = rolled.picks,
    offsets = offsets,
    linked = resolved,
    env = rolled.env,
    envelope = rolled.envelope,
  }

  return function(elapsed: number)
    return modifiers.evaluate(queue, elapsed, ctx)
  end
end

-- everything an effect module needs to drive one target: the sampler, and the
-- span it should run over, which is the queue's own far end and falls back only
-- when no modifier names a duration. nil when nothing is authored, so the
-- caller keeps whatever legacy path it had.
--
-- Call this BEFORE any non-soft attr.get on that name's quad keys. attr.get
-- writes its default back, so reading X_Start creates it, and readQuad then
-- finds a quad nobody authored.
--
-- `env` is what a `var` in this queue resolves against, and an effect passes the
-- SAME table to every knob it drives on one emitted instance. that is how one
-- drawn lifetime means one moment to all of them: a rand in each queue would
-- draw once per queue and break them apart.
function mods.driver(
  ref: Instance,
  source: string,
  name: string,
  fallback: number,
  want: string?,
  env: { [string]: any }?
): (((number) -> any)?, number)
  local queue = mods.read(ref, source, name)

  if queue == nil or #queue == 0 then
    return nil, fallback
  end

  -- a legacy quad with only one half authored cannot say what the other half
  -- was, because that default is the effect's own and legacy_mods copied the
  -- authored half over it. handing back no driver runs the effect's legacy
  -- branch, which still has the real default. this is the only shape where
  -- refusing to drive is more faithful than driving
  if #queue == 1 and queue[1].partial then
    return nil, fallback
  end

  if mods.inert(queue) then
    return nil, fallback
  end

  -- drawn before the span rather than inside the sampler, because a delay whose
  -- wait is drawn decides how far the queue reaches
  local rolls = mods.roll(queue, env)
  local span, linked = mods.span(queue, fallback, rolls)
  local sample = mods.sampler(ref, source, name, span, queue, rolls, linked)

  -- a queue of nothing but base kinds evaluates to ctx.base and stops there,
  -- and for a forge knob like Speed that base is an attribute nobody ever
  -- wrote. the curve editor stores exactly that shape when it authors a curve
  -- on a target with no legacy quad behind it. handing an effect a sampler
  -- that only ever returns nil is worse than handing it none, because every
  -- conversion assigns the first sample straight into its own arithmetic
  if sample == nil then
    return nil, fallback
  end

  local first = sample(0)

  if first == nil then
    return nil, fallback
  end

  -- a knob that names the type it wants is handed no driver when the queue
  -- samples another one. the effect assigns a sample straight into its own
  -- arithmetic, and a stepper that throws is never cleaned up: tween only runs
  -- its cleanup on a frame the counter returns from normally, so one wrong type
  -- repeats the same error every frame for as long as the scope lives
  if want ~= nil and typeof(first) ~= want then
    return nil, fallback
  end

  return sample, span
end

export type Track = {
  at: (elapsed: number) -> any,
  span: number,
  animated: boolean,
}

-- one warning per knob per instance: a mismatch repeats on every emit of the
-- same template, and the first one already says everything
local WARNED: { [Instance]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function warnOnce(ref: Instance, name: string, message: string)
  local seen = WARNED[ref]

  if seen == nil then
    seen = {}
    WARNED[ref] = seen
  end

  if seen[name] then
    return
  end

  seen[name] = true
  logger.warn(message)
end

-- the default for a knob that rests on a ramp rather than a value: what the
-- effect used to tween between when nothing was authored. a value when both
-- ends agree, so a knob at rest costs no stepper
function mods.ramp(startV: any, finishV: any): any
  if startV == finishV then
    return startV
  end

  return {
    {
      kind = "tween",
      chain = false,
      start = value.lit(startV),
      finish = value.lit(finishV),
      curve = curves.default(),
    },
  }
end

-- the default for a knob drawn once per emitted instance between two corners,
-- which is what a Min and Max pair or a NumberRange attribute always meant. a
-- vector pair draws each axis on its own
function mods.draw(minV: any, maxV: any): { any }
  return {
    {
      kind = "randomizer",
      chain = false,
      start = value.lit(minV),
      finish = value.lit(maxV),
      perComponent = true,
    },
  }
end

local function constant(default: any, span: number): Track
  return {
    at = function()
      return default
    end,
    span = span,
    animated = false,
  }
end

-- the value a knob wants, with the engine's two spellings of a vector read as
-- one kind
local function kindOf(v: any): string
  local t = typeof(v)

  return if t == "vector" then "Vector3" else t
end

local function sampleQueue(
  ref: Instance,
  source: string,
  name: string,
  queue: { any },
  span: number,
  env: { [string]: any }?
): (((number) -> any)?, number)
  local rolls = mods.roll(queue, env)
  local reach, linked = mods.span(queue, span, rolls)
  local sample = mods.sampler(ref, source, name, reach, queue, rolls, linked)

  if sample == nil or sample(0) == nil then
    return nil, span
  end

  return sample, reach
end

-- the one way an effect reads an animated knob. it always answers: what rests
-- when nothing usable is authored, else a sampler over the queue's own reach.
-- a default given as a queue is what runs when nothing is authored, for a knob
-- whose resting state is a ramp or a draw rather than a value
function mods.track(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?
): Track
  local fallback: { any }? = if type(default) == "table" then default else nil
  local rest: any = if fallback then nil else default

  local fillStart: value.Value? = nil
  local fillFinish: value.Value? = nil
  local want: string? = nil

  if fallback then
    local first = fallback[1]

    fillStart = first and first.start
    fillFinish = first and first.finish

    if fillStart and value.isLit(fillStart) then
      want = kindOf(value.resolve(fillStart))
    end
  else
    fillStart = legacy_mods.endpoint(source, name, default)
    fillFinish = fillStart

    if default ~= nil then
      want = kindOf(default)
    end
  end

  local function resting(): Track
    if fallback == nil then
      return constant(rest, span)
    end

    local sample, reach = sampleQueue(ref, source, name, fallback, span, env)

    if sample == nil then
      return constant(nil, span)
    end

    return { at = sample, span = reach, animated = true }
  end

  local queue = mods.read(ref, source, name)

  if queue == nil or #queue == 0 or mods.inert(queue) then
    return resting()
  end

  -- a half quad is completed from the default, which is the effect's own and is
  -- exactly what the legacy branch would have read for the missing half
  if #queue == 1 and queue[1].partial then
    queue = legacy_mods.complete(queue, fillStart, fillFinish)
  end

  local sample, reach = sampleQueue(ref, source, name, queue, span, env)

  if sample == nil then
    return resting()
  end

  if want ~= nil and kindOf(sample(0)) ~= want then
    warnOnce(ref, name, `{name} samples a {kindOf(sample(0))} where the effect wants a {want}`)
    return resting()
  end

  return { at = sample, span = reach, animated = true }
end

return mods
