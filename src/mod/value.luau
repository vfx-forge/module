local lerp = require("@mod/lerp")

-- a modifier value is a tagged union so a future dynamic variable slots in
-- with no format change; only lit is produced in spec 1, var round-trips
-- already
export type Value =
  { t: "lit", v: any }
  | { t: "var", ref: string }
  | { t: "draw", a: any, b: any, weight: (string | buffer)? }
  | { t: "feed", ref: string }

local value = {}

function value.lit(v: any): Value
  return { t = "lit", v = v }
end

-- an endpoint drawn once per emitted instance rather than authored outright,
-- between two values of the row's own type, which is what a legacy NumberRange
-- endpoint means and what an authored randomizer endpoint means. the draw
-- itself is made in mods.sampler and handed to evaluate, so nothing here is
-- random; the weight curve that shapes the draw rides along for the caller
-- that made it to apply
function value.draw(a: any, b: any, weight: (string | buffer)?): Value
  return { t = "draw", a = a, b = b, weight = weight }
end

-- a value that belongs to the emitted instance rather than to this modifier,
-- named so several rows can read the one thing. what a legacy reader reaches
-- for when the value it is synthesizing was drawn ONCE by the effect and used
-- by every knob on the instance, which no per-row draw can reproduce
function value.var(ref: string): Value
  return { t = "var", ref = ref }
end

-- an endpoint fed by a randomizer in the same queue, named by that
-- randomizer's id: it reads the one value the randomizer drew for the emitted
-- instance. only modifiers.evaluate and modifiers.sample can resolve one, since
-- the draw belongs to the queue; everything else reads it as nothing
function value.feed(ref: string): Value
  return { t = "feed", ref = ref }
end

function value.isFeed(x: Value): boolean
  return x.t == "feed"
end

function value.isLit(x: Value): boolean
  return x.t == "lit"
end

function value.isDraw(x: Value): boolean
  return x.t == "draw"
end

function value.isVar(x: Value): boolean
  return x.t == "var"
end

-- the one value an endpoint can resolve to whatever is drawn: a literal's own,
-- or the corner of a draw whose two corners agree. nil for a var, and for a
-- draw that can land anywhere between two values
function value.fixed(x: Value?): any
  if x == nil then
    return nil
  end

  if x.t == "lit" then
    return (x :: any).v
  end

  if x.t == "draw" then
    local d = x :: any

    return if d.a == d.b then d.a else nil
  end

  return nil
end

-- a draw resolves at its alpha, and at its midpoint when nobody drew one, which
-- is both what an editor showing the value wants and a sane pure evaluation.
--
-- a var names a value that belongs to the whole emitted instance rather than to
-- one modifier, so it resolves against an environment the caller supplies. that
-- is the difference between a var and a draw: two rows each holding a draw draw
-- twice, two rows naming the same var read one value. it stays nil when nobody
-- supplies an environment or the name is not in it, which is what every caller
-- already handled, since nil is all a var ever gave back
function value.resolve(x: Value, alpha: number?, env: { [string]: any }?): any
  if x.t == "lit" then
    return (x :: any).v
  end

  if x.t == "draw" then
    local d = x :: any

    return lerp.any(d.a, d.b, alpha or 0.5)
  end

  if x.t == "var" then
    return if env then env[(x :: any).ref] else nil
  end

  return nil
end

return value
