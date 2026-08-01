local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
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

function mods.read(ref: Instance, source: string, name: string): { any }?
  local raw = ref:GetAttribute(mods.attrName(source, name))

  if frame.isFramed(raw) then
    local body = frame.unframe(raw)

    if body == nil then
      logger.warn(`{name} carries a framed modifier queue that could not be read`)
    else
      local ok, decoded = pcall(codec.decode, body)

      if ok and decoded then
        return decoded.queue
      end

      logger.warn(`failed to decode the modifier queue on {name}`)
    end
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

-- randomizer and envelope values are drawn HERE, once, which is once per
-- emitted instance. that makes "one draw per instance" structural rather than
-- a rule every call site has to remember
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

  for i, m in queue do
    if m.kind == "randomizer" then
      draws[i] = rng:NextNumber()
    end
  end

  local ctx: modifiers.Ctx = {
    duration = duration,
    base = baseOf(ref, source, name),
    draws = draws,
    envelope = rng:NextNumber() * 2 - 1,
  }

  return function(elapsed: number)
    return modifiers.evaluate(queue, elapsed, ctx)
  end
end

return mods
