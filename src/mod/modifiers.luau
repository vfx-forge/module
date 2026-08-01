local lerp = require("@mod/lerp")
local path = require("@mod/common/path")

local modifiers = {}

export type Ctx = {
  duration: number,
  base: any?,
  draws: { [number]: number }?,
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

-- how far through its own run a modifier is, where a nil duration means it
-- runs over the effect's own
local function progressOf(m: any, elapsed: number, ctx: Ctx): number
  local d = m.duration or ctx.duration

  if d == nil or d <= 0 then
    return 1
  end

  return math.clamp(elapsed / d, 0, 1)
end

-- sample a serialized curve (a Path2D control-point buffer or string) at
-- progress in [0,1], mirroring mod/tween.luau's runtime semantics exactly
function modifiers.alphaFromCurve(curve: string | buffer, progress: number): number
  return path.alphaAt(curve, progress)
end

function modifiers.evaluate(queue: { any }, elapsed: number, ctx: Ctx): any
  local prevOut: any = ctx.base
  local haveOut = ctx.base ~= nil

  for i, m in queue do
    if modifiers.BASE_KINDS[m.kind] then
      continue
    end

    local startVal: any = nil

    if m.chain and haveOut then
      startVal = prevOut
    elseif m.start then
      startVal = m.start.v
    end

    local finishVal = if m.finish then m.finish.v else startVal

    local progress = progressOf(m, elapsed, ctx)
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
