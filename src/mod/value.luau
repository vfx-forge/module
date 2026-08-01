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

function value.isLit(x: Value): boolean
  return x.t == "lit"
end

function value.isRand(x: Value): boolean
  return x.t == "rand"
end

-- a var resolves to nil in spec 1, so callers fall back to their own default.
-- a rand resolves at its draw, and at its midpoint when nobody drew one, which
-- is both what an editor showing the value wants and a sane pure evaluation
function value.resolve(x: Value, draw: number?): any
  if x.t == "lit" then
    return (x :: any).v
  end

  if x.t == "rand" then
    local r = x :: any
    return r.min + (r.max - r.min) * (draw or 0.5)
  end

  return nil
end

return value
