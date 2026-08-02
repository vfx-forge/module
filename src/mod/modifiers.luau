local lerp = require("@mod/lerp")
local path = require("@mod/common/path")
local value = require("@mod/value")

local modifiers = {}

-- the [0,1] draw behind each rand endpoint of one modifier, made once per
-- emitted instance beside ctx.draws. a delay's wait is drawn the same way
export type Picks = { start: number?, finish: number?, wait: number? }

export type Ctx = {
  duration: number,
  base: any?,
  draws: { [number]: number }?,
  picks: { [number]: Picks }?,
  offsets: { [number]: number }?,
  envelope: number?,
}

-- a base entry stores the row's authored value rather than modifying it. the
-- instance already carries that value, so ctx.base seeds the chain and the
-- entry itself evaluates to nothing
modifiers.BASE_KINDS = {
  sequence = true,
  gradient = true,
}

local function typeLerp(a: any, b: any, t: number): any
  local fn = (lerp :: any)[typeof(a)]

  if fn then
    return fn(a, b, t)
  end

  return lerp.Other(a, b, t)
end

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
-- from where the delays before it put it, so a negative one means it has not
-- started. a nil duration means it runs over the effect's own, and a delayed
-- modifier gets what is LEFT of the effect's: it starts late and still has to
-- finish by the end of the run rather than that much past it
local function progressOf(m: any, elapsed: number, ctx: Ctx, offset: number): number
  local d = m.duration

  if typeof(d) ~= "number" then
    d = if typeof(ctx.duration) == "number" then ctx.duration - offset else nil
  end

  -- a step function still steps where it was placed rather than at zero
  if typeof(d) ~= "number" or d <= 0 then
    return if elapsed < 0 then 0 else 1
  end

  return math.clamp(elapsed / d, 0, 1)
end

-- a delay carries its wait in `wait`, a Value, so a drawn one is the same rand
-- tag every other randomizable number here uses, and so a runtime that predates
-- the kind sees a modifier with no start and passes the previous value through
-- untouched. a plain number in `duration` is honoured too, since that is how a
-- delay reads if you write one by hand
function modifiers.waitOf(m: any, picks: Picks?): number
  local wait = m.wait

  if type(wait) == "table" then
    wait = value.resolve(wait, picks and picks.wait)
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

-- where each modifier begins once the delays before it are counted, and how far
-- the queue reaches in all. one walk, so evaluate and mods.span can never
-- disagree about when a delayed modifier starts.
--
-- `fallback` is the duration a caller is prepared to lend the queue, and it
-- only ever affects the reach. a caller that just wants the offsets leaves it
-- out. the offsets come back nil for a queue that delays nothing, which is
-- every queue authored so far, so the common path carries no table and reads
-- none per frame
function modifiers.schedule(
  queue: { any },
  picks: { [number]: Picks }?,
  fallback: number?
): ({ [number]: number }?, number)
  local offsets: { [number]: number }? = nil
  local offset = 0
  local frontier = 0

  for i, m in queue do
    -- a base entry is not on the clock, but a duration on one still lengthened
    -- the run before delays existed and has to keep doing so
    if modifiers.BASE_KINDS[m.kind] then
      if typeof(m.duration) == "number" and m.duration > frontier then
        frontier = m.duration
      end

      continue
    end

    -- a delay shifts what follows by its own wait and by nothing else, so a
    -- modifier's offset is the SUM of the waits before it rather than anything
    -- to do with how long its neighbours run. that is the only reading under
    -- which one wait means the same moment to knobs whose own phases differ in
    -- length, which is what an effect drawing a single lifetime per emitted
    -- instance needs, and it is also what lets a phase be delayed to a moment
    -- BEFORE the phase it chains from has finished
    if m.kind == "delay" then
      offset += modifiers.waitOf(m, if picks then picks[i] else nil)
      offsets = offsets or {}
      continue
    end

    -- nothing ahead of the first delay is moved, so its absence from the table
    -- reads as the zero it is
    if offsets then
      offsets[i] = offset
    end

    local d = m.duration

    -- a modifier naming no duration of its own runs to the end of the run. at
    -- offset zero that means it can never extend the run, which is what the
    -- reach already said before delays existed. after a delay it starts late,
    -- so the run has to be long enough for it to still get a full turn
    if typeof(d) ~= "number" then
      d = if offset > 0 then fallback else nil
    end

    if typeof(d) == "number" and offset + d > frontier then
      frontier = offset + d
    end
  end

  return offsets, frontier
end

-- sample a serialized curve (a Path2D control-point buffer or string) at
-- progress in [0,1], mirroring mod/tween.luau's runtime semantics exactly
function modifiers.alphaFromCurve(curve: string | buffer, progress: number): number
  return path.alphaAt(curve, progress)
end

function modifiers.evaluate(queue: { any }, elapsed: number, ctx: Ctx): any
  local prevOut: any = ctx.base
  local haveOut = ctx.base ~= nil
  local offsets = ctx.offsets

  for i, m in queue do
    if modifiers.BASE_KINDS[m.kind] then
      continue
    end

    -- a delay contributes no value at all, so it leaves prevOut alone and a
    -- chain reaches across it. the offsets it imposes are worked out once per
    -- emitted instance in mods.sampler; a caller evaluating a queue directly
    -- pays for that walk here, and only if the queue actually delays something
    if m.kind == "delay" then
      if offsets == nil then
        offsets = modifiers.schedule(queue, ctx.picks)
      end

      continue
    end

    -- endpoints go through value.resolve rather than a raw field read, so a
    -- rand endpoint lands on the draw the sampler made for it and a var still
    -- resolves to nothing
    local picks = if ctx.picks then ctx.picks[i] else nil

    local startVal: any = nil

    if m.chain and haveOut then
      startVal = prevOut
    elseif m.start then
      startVal = value.resolve(m.start, picks and picks.start)
    end

    local finishVal = if m.finish then value.resolve(m.finish, picks and picks.finish) else startVal

    local offset = if offsets then offsets[i] or 0 else 0
    local progress = progressOf(m, elapsed - offset, ctx, offset)
    local alpha: number

    if m.kind == "randomizer" then
      -- evaluate stays pure, so it never builds a Random of its own. the draw
      -- arrives from the sampler, made once per emitted instance
      local draw = if ctx.draws then ctx.draws[i] else nil

      if draw == nil then
        draw = 0.5
      end

      alpha = if m.weight then modifiers.alphaFromCurve(m.weight, draw) else draw
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

    prevOut = typeLerp(startVal, finishVal, alpha)
    haveOut = true
  end

  return prevOut
end

return modifiers
