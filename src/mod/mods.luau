local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
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

-- how long a queue runs on its own terms, for a caller with no effect
-- duration to lend it
function mods.span(queue: { any }, fallback: number): number
  local longest = 0

  for _, m in queue do
    if typeof(m.duration) == "number" and m.duration > longest then
      longest = m.duration
    end
  end

  if longest <= 0 then
    return fallback
  end

  return longest
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

-- randomizer alphas, rand endpoints and the envelope offset are all drawn
-- HERE, once, which is once per emitted instance. that makes "one draw per
-- instance" structural rather than a rule every call site has to remember
-- a caller that already read the queue, to span it or to test it, passes it
-- back in rather than paying a second base64 plus buffer decode for the same
-- attribute
function mods.sampler(
  ref: Instance,
  source: string,
  name: string,
  duration: number,
  preread: { any }?
): ((number) -> any)?
  local queue = preread or mods.read(ref, source, name)

  if queue == nil or #queue == 0 then
    return nil
  end

  local rng = Random.new()
  local draws = {}
  local picks = {}

  for i, m in queue do
    if m.kind == "randomizer" then
      draws[i] = rng:NextNumber()
    end

    local startRand = m.start ~= nil and value.isRand(m.start)
    local finishRand = m.finish ~= nil and value.isRand(m.finish)

    if startRand or finishRand then
      picks[i] = {
        start = if startRand then rng:NextNumber() else nil,
        finish = if finishRand then rng:NextNumber() else nil,
      }
    end
  end

  local ctx: modifiers.Ctx = {
    duration = duration,
    base = baseOf(ref, source, name),
    draws = draws,
    picks = picks,
    envelope = rng:NextNumber() * 2 - 1,
  }

  return function(elapsed: number)
    return modifiers.evaluate(queue, elapsed, ctx)
  end
end

-- everything an effect module needs to drive one target: the sampler, and the
-- span it should run over, which is the queue's own longest duration and falls
-- back only when no modifier names one. nil when nothing is authored, so the
-- caller keeps whatever legacy path it had.
--
-- Call this BEFORE any non-soft attr.get on that name's quad keys. attr.get
-- writes its default back, so reading X_Start creates it, and readQuad then
-- finds a quad nobody authored.
function mods.driver(ref: Instance, source: string, name: string, fallback: number): (((number) -> any)?, number)
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

  local span = mods.span(queue, fallback)
  local sample = mods.sampler(ref, source, name, span, queue)

  -- a queue of nothing but base kinds evaluates to ctx.base and stops there,
  -- and for a forge knob like Speed that base is an attribute nobody ever
  -- wrote. the curve editor stores exactly that shape when it authors a curve
  -- on a target with no legacy quad behind it. handing an effect a sampler
  -- that only ever returns nil is worse than handing it none, because every
  -- conversion assigns the first sample straight into its own arithmetic
  if sample == nil or sample(0) == nil then
    return nil, fallback
  end

  return sample, span
end

return mods
