local value = require("@mod/value")
local curves = require("@mod/curves")

local Spec = {}
Spec.__index = Spec

local mod = {}

export type Spec = typeof(setmetatable(
  {} :: {
    side: "from" | "to",
    endpoint: any,
    opts: { duration: any, curve: string?, start: any },
  },
  Spec
))

local function make(side: "from" | "to", endpoint: any): Spec
  return setmetatable({
    side = side,
    endpoint = endpoint,
    opts = { duration = nil, curve = nil, start = nil },
  }, Spec)
end

function mod.from(a: any): Spec
  return make("from", a)
end

function mod.to(b: any): Spec
  return make("to", b)
end

function mod.is(x: any)
  return type(x) == "table" and getmetatable(x) == Spec
end

function Spec.duration(self: Spec, d: any): Spec
  self.opts.duration = d
  return self
end

function Spec.curve(self: Spec, preset: string): Spec
  self.opts.curve = preset
  return self
end

function Spec.start(self: Spec, s: any): Spec
  self.opts.start = s
  return self
end

local function pick(x: any, ctx: any, attrs: any, props: any)
  if type(x) == "function" then
    return x(ctx, attrs, props)
  end

  return x
end

-- the queue a default modifier runs over a row resting at `rest`, with the
-- row's own state as the end the spec did not name. nil when the two ends
-- agree, so a row at rest costs no stepper
function mod.queue(spec: Spec, ctx: any, attrs: any, props: any, rest: any, rowCurve: string?): { any }?
  local endpoint = pick(spec.endpoint, ctx, attrs, props)

  if endpoint == nil or endpoint == rest then
    return nil
  end

  local startV = if spec.side == "from" then endpoint else rest
  local finishV = if spec.side == "from" then rest else endpoint

  local runFor = pick(spec.opts.duration, ctx, attrs, props)
  local wait = pick(spec.opts.start, ctx, attrs, props)

  local out = {}

  if typeof(wait) == "number" and wait > 0 then
    table.insert(out, { kind = "delay", chain = false, wait = value.lit(wait) })
  end

  table.insert(out, {
    kind = "tween",
    chain = false,
    duration = if typeof(runFor) == "number" and runFor > 0 then runFor else nil,
    start = value.lit(startV),
    finish = value.lit(finishV),
    curve = curves.preset(spec.opts.curve or rowCurve),
  })

  return out
end

return mod
