local lerp = require("@mod/lerp")
local path = require("@mod/common/path")
local value = require("@mod/value")

local modifiers = {}

-- the [0,1] draw behind each drawn endpoint of one modifier, made once per
-- emitted instance beside ctx.draws. an offset's draw is drawn the same way
export type Picks = { start: number?, finish: number?, offset: number? }

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

-- how far through its own run a modifier is, given an elapsed already measured
-- from where its offset put it, so a negative one means it has not started. a
-- nil duration means it runs for ctx.linked, the offset-free span, so an offset
-- moves a modifier without changing how long it takes once it starts
local function durationOf(m: any, ctx: Ctx): number?
  local d = m.duration

  if typeof(d) ~= "number" then
    d = if typeof(ctx.linked) == "number" then ctx.linked else ctx.duration
  end

  return if typeof(d) == "number" and d > 0 then d else nil
end

local function progressOf(m: any, elapsed: number, ctx: Ctx): number
  local d = durationOf(m, ctx)

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
local function steppedProgress(m: any, elapsed: number, ctx: Ctx): number
  local progress = progressOf(m, elapsed, ctx)
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
    local d = durationOf(m, ctx)

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

  return progressOf(m, math.floor(elapsed * fps) / fps, ctx)
end

-- an entry carries its offset in `offset`, a Value, so a drawn one is the same
-- draw tag every other randomizable number here uses. a plain number is
-- honoured too, since that is how an offset reads if you write one by hand
function modifiers.offsetOf(m: any, picks: Picks?, env: { [string]: any }?): number
  local offset = m.offset

  if type(offset) == "table" then
    offset = value.resolve(offset, picks and picks.offset, env)
  end

  if typeof(offset) ~= "number" then
    return 0
  end

  -- an offset that is not finite cannot place anything on a clock, and it would
  -- carry through mods.span into tween.timer, which then never satisfies
  -- elapsed >= duration and never finishes the emit
  if offset ~= offset or offset == math.huge then
    return 0
  end

  return math.max(offset, 0)
end

-- where each modifier begins once its own offset is counted, and how far the
-- queue reaches in all. one walk, so evaluate and mods.span can never disagree
-- about when an offset modifier starts.
--
-- `fallback` is the duration a caller is prepared to lend the queue, and it
-- only ever affects the reach. a caller that just wants the offsets leaves it
-- out. the offsets come back nil for a queue that offsets nothing, which is
-- every queue authored so far, so the common path carries no table and reads
-- none per frame
function modifiers.schedule(
  queue: { any },
  picks: { [number]: Picks }?,
  fallback: number?,
  env: { [string]: any }?
): ({ [number]: number }?, number, number)
  -- the longest duration the queue NAMES, which is what a modifier that names
  -- none runs for. taken from durations alone, with no offset in it: an offset
  -- lengthens the run of the queue, but it must not stretch the modifier it
  -- moves, and it must not reach backwards and stretch one that ran before it
  local linked = 0

  for _, m in queue do
    -- an infinite duration is excluded rather than allowed to win: it would
    -- make every modifier that names no duration read a progress of zero and
    -- sit on its start value for the whole run
    if typeof(m.duration) == "number" and m.duration ~= math.huge and m.duration > linked then
      linked = m.duration
    end
  end

  if linked <= 0 then
    linked = if typeof(fallback) == "number" then fallback else 0
  end

  local offsets: { [number]: number }? = nil
  local frontier = 0

  for i, m in queue do
    -- a base entry is not on the clock, but a duration on one still lengthened
    -- the run before offsets existed and has to keep doing so
    if modifiers.BASE_KINDS[m.kind] then
      if typeof(m.duration) == "number" and m.duration > frontier then
        frontier = m.duration
      end

      continue
    end

    local offset = modifiers.offsetOf(m, if picks then picks[i] else nil, env)

    -- an entry that is not moved is absent from the table rather than written
    -- down as the zero it is
    if offset > 0 then
      offsets = offsets or {}
      offsets[i] = offset
    end

    -- a modifier naming no duration of its own runs for the offset-free span,
    -- wherever its offset placed it, so its reach is that span past its start
    local d = if typeof(m.duration) == "number" then m.duration else linked

    if offset + d > frontier then
      frontier = offset + d
    end
  end

  return offsets, frontier, linked
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
  local walked = offsets ~= nil

  for i, m in queue do
    if modifiers.BASE_KINDS[m.kind] then
      continue
    end

    -- the offsets are worked out once per emitted instance in mods.sampler; a
    -- caller evaluating a queue directly pays for that walk here, and only if
    -- the queue moves anything at all
    if not walked and m.offset ~= nil then
      offsets = modifiers.schedule(queue, ctx.picks, nil, ctx.env)
      walked = true
    end

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

    local offset = if offsets then offsets[i] or 0 else 0
    local progress = steppedProgress(m, elapsed - offset, ctx)
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
