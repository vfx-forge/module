-- a modifier value is a tagged union so a future dynamic variable slots in
-- with no format change; only lit is produced in spec 1, var round-trips
-- already
export type Value = { t: "lit", v: any } | { t: "var", ref: string } | { t: "rand", min: number, max: number }

local value = {}

function value.lit(v: any): Value
  return { t = "lit", v = v }
end

-- an endpoint drawn once per emitted instance rather than authored outright,
-- which is what a legacy NumberRange endpoint means. numeric by construction,
-- because every knob that authors one holds a NumberRange. the draw itself is
-- made in mods.sampler and handed to evaluate, so nothing here is random
function value.rand(min: number, max: number): Value
  return { t = "rand", min = min, max = max }
end

-- a value that belongs to the emitted instance rather than to this modifier,
-- named so several rows can read the one thing. what a legacy reader reaches
-- for when the value it is synthesizing was drawn ONCE by the effect and used
-- by every knob on the instance, which no per-row rand can reproduce
function value.var(ref: string): Value
  return { t = "var", ref = ref }
end

function value.isLit(x: Value): boolean
  return x.t == "lit"
end

function value.isRand(x: Value): boolean
  return x.t == "rand"
end

function value.isVar(x: Value): boolean
  return x.t == "var"
end

-- a rand resolves at its draw, and at its midpoint when nobody drew one, which
-- is both what an editor showing the value wants and a sane pure evaluation.
--
-- a var names a value that belongs to the whole emitted instance rather than to
-- one modifier, so it resolves against an environment the caller supplies. that
-- is the difference between a var and a rand: two rows each holding a rand draw
-- twice, two rows naming the same var read one value. it stays nil when nobody
-- supplies an environment or the name is not in it, which is what every caller
-- already handled, since nil is all a var ever gave back
function value.resolve(x: Value, draw: number?, env: { [string]: any }?): any
  if x.t == "lit" then
    return (x :: any).v
  end

  if x.t == "rand" then
    local r = x :: any
    return r.min + (r.max - r.min) * (draw or 0.5)
  end

  if x.t == "var" then
    return if env then env[(x :: any).ref] else nil
  end

  return nil
end

return value
