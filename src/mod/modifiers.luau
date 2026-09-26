local lerp = require("@mod/lerp")
local path = require("@mod/common/path")
local value = require("@mod/value")

local modifiers = {}

-- the [0,1] draw behind each drawn endpoint of one modifier, made once per
-- emitted instance beside ctx.draws. a delay's wait is drawn the same way
export type Picks = { start: number?, finish: number?, wait: number? }

-- a randomizer's draw is one alpha, except over a Vector3, where it is one
-- alpha PER COMPONENT: a legacy Min/Max pair over a size means three
-- independent draws, so a part comes out with its own proportions rather than
-- as a scaled copy of every other one
export type Draw = number | { number }

export type Ctx = {
  duration: number,
  base: any?,
  draws: { [number]: Draw }?,
  picks: { [number]: Picks }?,
  offsets: { [number]: number }?,
  lengths: { [number]: number }?,
  linked: number?,
  env: { [string]: any }?,
  envelope: number?,
}

-- a base entry stores the row's authored value rather than modifying it. the
-- instance already carries that value, so ctx.base seeds the chain and the
-- entry itself evaluates to nothing
modifiers.BASE_KINDS = {
  sequence = true,
  gradient = true,
}

-- envelope widths are f32 per keypoint in ALPHA units, because the authoring
-- side divides each NumberSequenceKeypoint.Envelope by the value range before
-- storing it. sampling walks the array linearly across [0,1]
local function envelopeAt(buf: buffer, progress: number): number
  local n = math.floor(buffer.len(buf) / 4)

  if n == 0 then
    return 0
  end

  if n == 1 then
    return buffer.readf32(buf, 0)
  end

  local pos = math.clamp(progress, 0, 1) * (n - 1)
  local i = math.floor(pos)

  if i >= n - 1 then
    return buffer.readf32(buf, (n - 1) * 4)
  end

  local a = buffer.readf32(buf, i * 4)
  local b = buffer.readf32(buf, (i + 1) * 4)

  return a + (b - a) * (pos - i)
end

-- how long a modifier runs once it starts. a nil duration is the run
-- schedule worked out for it, which is what is left of the effect after the
-- modifiers before it; a caller that scheduled nothing falls back to
-- ctx.linked, then to the effect's whole duration
local function durationOf(m: any, i: number, ctx: Ctx, lengths: { [number]: number }?): number?
  local d = m.duration

  if typeof(d) ~= "number" then
    d = if lengths and lengths[i] then lengths[i] elseif typeof(ctx.linked) == "number" then ctx.linked else ctx.duration
  end

  return if typeof(d) == "number" and d > 0 then d else nil
end

-- how far through its own run a modifier is, given an elapsed already measured
-- from where schedule put it, so a negative one means it has not started
local function progressOf(d: number?, elapsed: number): number
  -- a step function still steps where it was placed rather than at zero
  if d == nil then
    return if elapsed < 0 then 0 else 1
  end

  return math.clamp(elapsed / d, 0, 1)
end

-- a rate that CHANGES across the run cannot quantize onto a fixed grid. the
-- grid moves with it, and a moved grid is not monotonic: ramping 20fps to
-- 22fps, elapsed 0.60 floors to 0.600 and elapsed 0.61 floors to 0.591, so the
-- knob rewinds a hundredth of its travel. It happens at every rate change,
-- which on a ramp is continuously.
--
-- What is monotonic is the number of steps ELAPSED, which is the integral of the
-- rate: phase(t) = integral of fps, strictly increasing while fps > 0, so
-- floor(phase) only ever climbs. The step you are on is floor(phase), and the
-- moment it began is phase inverted at that count.
--
-- The integral is separable, which is what makes it cheap. With fps ramping from
-- `from` to `to` along a curve, fps(p) = from + (to - from) * alpha(p), so
--
--   Phase(p) = from * p + (to - from) * A(p),  A(p) = integral of alpha
--
-- and A depends on the CURVE ALONE. Not on the endpoints, not on the duration
-- (which only scales the step count), so one table serves every instance
-- sampling that curve whatever lifetime it drew. Cached here the way
-- path.bezier_cache caches the curve itself: a memo, so evaluate stays a pure
-- function of its inputs.
--
-- 128 rather than 32, which a gentle ramp is perfectly happy with: a rate that
-- LEAPS inside one cell puts a large slice of the whole integral in that cell,
-- and the trapezoid error over it lands the steps around the leap visibly wrong.
-- Measured at 0.35ms to build against 0.09ms, once per curve, on lune's slower
-- Newton-solve path; Studio takes the LUT and is faster than both.
local PHASE_SAMPLES = 128

modifiers.phase_cache = {} :: { [string]: any }

-- the shaping alpha, held inside [0,1]. a curve is free to overshoot, and one
-- shaping a tween is MEANT to: anticipation dips below its start before it
-- leaves. a rate has no such reading. an alpha of -0.1 across a 2-to-60 ramp is
-- a rate of -4 steps per second, and a phase that falls is a phase whose floor
-- falls with it, so the knob reaches its finish a third of the way in and then
-- rewinds two thirds of its travel in one frame. clamped, the rate stays
-- between the two ends it was given, and the integral only ever climbs
local function clampedAlpha(curve: string | buffer, progress: number): number
  return math.clamp(modifiers.alphaFromCurve(curve, progress), 0, 1)
end

local function alphaIntegral(curve: string | buffer): { number }
  local key = if typeof(curve) == "buffer" then buffer.tostring(curve) else curve
  local table_ = modifiers.phase_cache[key]

  if table_ then
    return table_
  end

  -- trapezoid over a uniform grid. A[i] is the integral up to i / PHASE_SAMPLES,
  -- so A[1] is zero and the last entry is the whole area
  local out = { 0 }
  local previous = clampedAlpha(curve, 0)

  for i = 1, PHASE_SAMPLES do
    local current = clampedAlpha(curve, i / PHASE_SAMPLES)

    out[i + 1] = out[i] + (previous + current) / 2 / PHASE_SAMPLES
    previous = current
  end

  modifiers.phase_cache[key] = out

  return out
end

-- the ramp a modifier names, or nil when its fps is a plain number or nothing at
-- all. `to` alone is what separates a ramp from a flat rate: equal ends are a
-- constant however it was authored, and take the cheap path
local function fpsRamp(fps: any): { from: number, to: number, curve: (string | buffer)? }?
  if type(fps) ~= "table" then
    return nil
  end

  local from, to = fps.from, fps.to

  if typeof(from) ~= "number" or typeof(to) ~= "number" or from <= 0 or to <= 0 or from == to then
    return nil
  end

  if from ~= from or to ~= to or from == math.huge or to == math.huge then
    return nil
  end

  return { from = from, to = to, curve = fps.curve }
end

-- Phase(p), in steps per unit of duration. A linear ramp needs no table at all,
-- since the integral of p is p squared over two
local function phaseAt(ramp: any, area: { number }?, p: number): number
  if area == nil then
    return ramp.from * p + (ramp.to - ramp.from) * p * p / 2
  end

  local pos = math.clamp(p, 0, 1) * PHASE_SAMPLES
  local i = math.min(math.floor(pos), PHASE_SAMPLES - 1)
  local a = area[i + 1] + (area[i + 2] - area[i + 1]) * (pos - i)

  return ramp.from * p + (ramp.to - ramp.from) * a
end

-- Phase inverted: the progress at which `steps` steps have elapsed. Phase climbs
-- monotonically, so the grid it was sampled on brackets the answer and the
-- interval it lands in is solved straight
local function progressAtPhase(ramp: any, area: { number }?, steps: number): number
  local lo, hi = 0, PHASE_SAMPLES

  while hi - lo > 1 do
    local mid = (lo + hi) // 2

    if phaseAt(ramp, area, mid / PHASE_SAMPLES) <= steps then
      lo = mid
    else
      hi = mid
    end
  end

  local a = phaseAt(ramp, area, lo / PHASE_SAMPLES)
  local b = phaseAt(ramp, area, hi / PHASE_SAMPLES)

  if b <= a then
    return lo / PHASE_SAMPLES
  end

  return (lo + (steps - a) / (b - a)) / PHASE_SAMPLES
end

-- how often a modifier is allowed to move, in steps per second. a knob with no
-- fps runs at whatever rate its effect steps at, which is the frame rate; naming
-- one holds it on each step until the next is due, which is what a stylized
-- flipbook-looking phase wants.
--
-- the LAST step is exempt, always. quantizing the whole run leaves a phase whose
-- duration is not a whole number of steps short of its finish for good: 0.1s at
-- 12fps steps at 0, and 1/12 is past the end, so the knob would sit at 83% of
-- its travel and stay there. a modifier that never reaches what it was told to
-- reach is worse than one that arrives a fraction of a step early
local function steppedProgress(m: any, d: number?, elapsed: number): number
  local progress = progressOf(d, elapsed)
  local fps = m.fps

  if progress >= 1 then
    return progress
  end

  -- a progress that is not a number lands on no step at all: the phase table
  -- indexed at NaN is a nil, and the arithmetic on it throws. naming a rate
  -- must not turn a clock nobody can read into an error, so the knob stays
  -- where an unstepped progress would have put it
  if progress ~= progress then
    return progress
  end

  if type(fps) == "table" then
    local ramp = fpsRamp(fps)

    -- an endless duration divides into nothing: floor(inf * 0) is NaN, and a
    -- NaN step count inverts to a NaN progress, which lerps to a value nothing
    -- can be set to. the flat grid below reads it correctly, as a run that is
    -- nought percent through at every elapsed
    if ramp and d ~= nil and d ~= math.huge then
      local tbl = if ramp.curve then alphaIntegral(ramp.curve) else nil
      local steps = math.floor(d * phaseAt(ramp, tbl, progress))

      return progressAtPhase(ramp, tbl, steps / d)
    end

    -- a ramp whose ends agree is a constant rate however it was authored, and
    -- takes the cheap grid below rather than a table integrating a flat line
    fps = fps.from
  end

  if typeof(fps) ~= "number" or fps ~= fps or fps <= 0 or fps == math.huge then
    return progress
  end

  return progressOf(d, math.floor(elapsed * fps) / fps)
end

-- a delay carries its wait in `wait`, a Value, so a drawn one is the same draw
-- tag every other randomizable number here uses, and so a runtime that predates
-- the kind sees a modifier with no start and passes the previous value through
-- untouched. a plain number in `duration` is honoured too, since that is how a
-- delay reads if you write one by hand
function modifiers.waitOf(m: any, picks: Picks?, env: { [string]: any }?): number
  local wait = m.wait

  if type(wait) == "table" then
    wait = value.resolve(wait, picks and picks.wait, env)
  end

  if typeof(wait) ~= "number" then
    wait = m.duration
  end

  if typeof(wait) ~= "number" then
    return 0
  end

  -- a wait that is not finite cannot place anything on a clock, and it would
  -- carry through mods.span into tween.timer, which then never satisfies
  -- elapsed >= duration and never finishes the emit. the arithmetic here
  -- propagates a NaN where the comparison it replaced used to reject one
  if wait ~= wait or wait == math.huge then
    return 0
  end

  return math.max(wait, 0)
end

-- where each modifier begins, how long one naming no duration runs, and how
-- far the queue reaches in all. one walk, so evaluate and mods.span can never
-- disagree about when a modifier starts.
--
-- modifiers run one after another: each starts where the one before it ends,
-- so an offset is the sum of the durations and the waits ahead of it. a delay
-- still means wait this long before what follows. a modifier naming no
-- duration runs out whatever is left of `fallback`, the effect's duration, so
-- one after it starts at the effect's end; with no effect duration to lend it
-- runs for `linked`, the longest duration the queue names. a caller whose
-- queue starts partway through the effect passes `left`, the time the effect
-- has left from there, and that is what such a modifier runs out instead. a
-- randomizer naming no duration takes none: it draws at its start and the next
-- one starts there. a legacy entry marked `parallel` keeps the old reading: it starts at
-- the plain waits ahead of it plus the wait of a parallel delay right before
-- it, and moves nothing after it.
--
-- `lengths` holds the run of every modifier naming no duration, by index, and
-- is nil when there is none. `offsets` is nil only for a queue with nothing on
-- the clock
function modifiers.schedule(
  queue: { any },
  picks: { [number]: Picks }?,
  fallback: number?,
  env: { [string]: any }?,
  left: number?
): ({ [number]: number }?, number, number, { [number]: number }?)
  -- the longest duration the queue NAMES, which is what a modifier naming none
  -- runs for when nobody lends an effect duration
  local linked = 0

  for _, m in queue do
    -- an infinite duration is excluded rather than allowed to win: it would
    -- make every modifier that names no duration read a progress of zero and
    -- sit on its start value for the whole run
    if m.kind ~= "delay" and typeof(m.duration) == "number" and m.duration ~= math.huge and m.duration > linked then
      linked = m.duration
    end
  end

  local lent = if typeof(fallback) == "number" and fallback > 0 then fallback else nil
  local told = if typeof(left) == "number" and left == left then left else nil

  if linked <= 0 then
    linked = if lent then lent else 0
  end

  local offsets: { [number]: number }? = nil
  local lengths: { [number]: number }? = nil
  local offset = 0
  local frontier = 0
  -- the wait of a parallel delay, which moves the one entry after it alone
  local held: number? = nil

  for i, m in queue do
    -- a base entry is not on the clock, but a duration on one still lengthened
    -- the run before delays existed and has to keep doing so
    if modifiers.BASE_KINDS[m.kind] then
      if typeof(m.duration) == "number" and m.duration > frontier then
        frontier = m.duration
      end

      continue
    end

    if m.kind == "delay" and m.parallel then
      local w = modifiers.waitOf(m, if picks then picks[i] else nil, env)
      held = if w ~= math.huge then w else nil

      continue
    end

    if m.kind == "delay" then
      -- waitOf makes every wait finite on its own, but a sum of finite waits
      -- need not be. an infinite offset would make the span infinite too, and a
      -- knob whose span never ends holds its emit open for good, which is the
      -- hang the per-wait guard exists to prevent. a sum that cannot grow leaves
      -- the offset where it was rather than poisoning every modifier after it
      local sum = offset + modifiers.waitOf(m, if picks then picks[i] else nil, env)

      if sum ~= math.huge then
        offset = sum
      end

      continue
    end

    -- a parallel entry ran on its own clock from the emit: the waits of plain
    -- delays ahead of it move it, and a parallel delay moves only the entry
    -- right after it. everything else starts where the queue has got to
    local at = if m.parallel then offset + (held or 0) else offset
    held = nil

    offsets = offsets or {}
    offsets[i] = at

    local d = m.duration

    if typeof(d) ~= "number" then
      -- a randomizer draws its value where it starts and takes no time, so the
      -- next modifier starts right there. anything else runs out the time the
      -- caller says is left from where the queue starts, else what remains of
      -- the effect, or the named fallback without one
      if m.kind == "randomizer" and not m.parallel then
        d = 0
      elseif told ~= nil and not m.parallel then
        d = math.max(told - offset, 0)
      else
        d = if lent and not m.parallel then math.max(lent - offset, 0) else linked
      end

      lengths = lengths or {}
      lengths[i] = d
    end

    -- a duration that is not a number moves nothing after it rather than
    -- carrying a nan into every offset that follows
    if d ~= d or d < 0 then
      d = 0
    end

    if at + d > frontier then
      frontier = at + d
    end

    if not m.parallel then
      offset += d
    end
  end

  return offsets, frontier, linked, lengths
end

-- sample a serialized curve (a Path2D control-point buffer or string) at
-- progress in [0,1], mirroring mod/tween.luau's runtime semantics exactly
function modifiers.alphaFromCurve(curve: string | buffer, progress: number): number
  return path.alphaAt(curve, progress)
end

-- a randomizer over two Vector3s, drawn once per component. a weight curve
-- shapes each draw the same way it shapes a single one, so an axis is
-- distributed the way the author asked, independently of the other two
local function componentDraw(m: any, startVal: any, finishVal: any, draws: { number }): any
  local out = {}

  for axis = 1, 3 do
    local draw = draws[axis] or 0.5
    local alpha = if m.weight then modifiers.alphaFromCurve(m.weight, draw) else draw
    local a = if axis == 1 then startVal.X elseif axis == 2 then startVal.Y else startVal.Z
    local b = if axis == 1 then finishVal.X elseif axis == 2 then finishVal.Y else finishVal.Z

    out[axis] = a + (b - a) * alpha
  end

  return Vector3.new(out[1], out[2], out[3])
end

-- an endpoint's own pick, shaped by the weight curve the endpoint carries
-- before it is resolved, the same way a randomizer entry's draw is shaped. a
-- lit and a var carry none, so they cost one nil test
local function endpointAt(x: any, pick: number?, env: { [string]: any }?): any
  if pick ~= nil and x.weight ~= nil then
    pick = modifiers.alphaFromCurve(x.weight, pick)
  end

  return value.resolve(x, pick, env)
end

function modifiers.evaluate(queue: { any }, elapsed: number, ctx: Ctx): any
  local prevOut: any = ctx.base
  local haveOut = ctx.base ~= nil
  local offsets = ctx.offsets
  local lengths = ctx.lengths
  local ran = false

  -- the offsets are worked out once per emitted instance in mods.sampler. a
  -- caller evaluating a queue directly pays for that walk here, lending the
  -- effect's duration it passed in
  if offsets == nil and #queue > 1 then
    local scheduled

    offsets, _, _, scheduled = modifiers.schedule(queue, ctx.picks, ctx.duration, ctx.env)
    lengths = lengths or scheduled
  end

  for i, m in queue do
    if modifiers.BASE_KINDS[m.kind] then
      continue
    end

    -- a delay contributes no value at all, so it leaves prevOut alone and a
    -- chain reaches across it
    if m.kind == "delay" then
      continue
    end

    local offset = if offsets then offsets[i] or 0 else 0

    -- a modifier that has not started yet leaves the value to the ones before
    -- it. the first one on the clock has nothing before it, so it holds its
    -- start while it waits, and a parallel entry holds its start the way every
    -- legacy entry always did
    if ran and elapsed < offset and not m.parallel then
      continue
    end

    ran = true

    -- endpoints go through the resolver rather than a raw field read, so a
    -- drawn endpoint lands on the pick the sampler made for it, shaped by its
    -- own weight, and a var still resolves to nothing
    local picks = if ctx.picks then ctx.picks[i] else nil

    local startVal: any = nil

    if m.chain and haveOut then
      startVal = prevOut
    elseif m.start then
      startVal = endpointAt(m.start, picks and picks.start, ctx.env)
    end

    local finishVal = if m.finish then endpointAt(m.finish, picks and picks.finish, ctx.env) else startVal

    local progress = steppedProgress(m, durationOf(m, i, ctx, lengths), elapsed - offset)
    local alpha: number

    if m.kind == "randomizer" then
      -- evaluate stays pure, so it never builds a Random of its own. the draw
      -- arrives from the sampler, made once per emitted instance
      local draw = if ctx.draws then ctx.draws[i] else nil

      -- one alpha per component, which is what a legacy Min/Max pair over a
      -- size means: three independent draws rather than one scaling all three
      -- together. the envelope has no say here, because it deviates a single
      -- alpha and there is no single alpha to deviate
      if type(draw) == "table" and typeof(startVal) == "Vector3" and typeof(finishVal) == "Vector3" then
        prevOut = componentDraw(m, startVal, finishVal, draw)
        haveOut = true
        continue
      end

      if type(draw) ~= "number" then
        draw = 0.5
      end

      alpha = if m.weight then modifiers.alphaFromCurve(m.weight, draw :: number) else draw :: number
    elseif m.kind == "tween" then
      alpha = if m.curve then modifiers.alphaFromCurve(m.curve, progress) else progress
    else
      -- unknown kind: pass the value through unchanged, round trip with no eval
      if startVal ~= nil then
        prevOut = startVal
      end

      haveOut = prevOut ~= nil
      continue
    end

    if m.envelope and ctx.envelope then
      alpha = math.clamp(alpha + envelopeAt(m.envelope, progress) * ctx.envelope, 0, 1)
    end

    prevOut = lerp.any(startVal, finishVal, alpha)
    haveOut = true
  end

  return prevOut
end

return modifiers
