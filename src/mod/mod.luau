local value = require("@mod/value")
local curves = require("@mod/curves")

local Spec = {}
Spec.__index = Spec

local mod = {}

export type Spec = typeof(setmetatable(
  {} :: {
    side: "from" | "to",
    endpoint: any,
    opts: { duration: any, curve: any, delay: any, lane: string? },
  },
  Spec
))

local function make(side: "from" | "to", endpoint: any): Spec
  return setmetatable({
    side = side,
    endpoint = endpoint,
    opts = { duration = nil, curve = nil, delay = nil, lane = nil },
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

function Spec.curve(self: Spec, preset: any): Spec
  self.opts.curve = preset
  return self
end

function Spec.delay(self: Spec, s: any): Spec
  self.opts.delay = s
  return self
end

function Spec.lane(self: Spec, name: string): Spec
  self.opts.lane = name
  return self
end

local function pick(x: any, ctx: any, attrs: any, props: any)
  if type(x) == "function" then
    return x(ctx, attrs, props)
  end

  return x
end

-- the entry a default modifier runs over a row resting at `rest`, with the
-- row's own state as the end the spec did not name. nil when the two ends agree
-- and the entry begins at that rest, so a row at rest costs no stepper. an
-- authored duration of zero is a
-- phase that snaps, not an unnamed one, so only a missing or negative span
-- falls back to the module's clock, and a phase snapping FROM somewhere to
-- where the row already stands is the row's own value and no entry at all
local function entryOf(spec: Spec, ctx: any, attrs: any, props: any, rest: any, rowCurve: string?): any?
  local endpoint = pick(spec.endpoint, ctx, attrs, props)

  if endpoint == nil then
    return nil
  end

  -- a `to` on a lane the module fires begins where the row stands rather than
  -- at its resting value, which is the only reading under which a phase
  -- composes over whatever ran before it. a `from` names its own start, so it
  -- never chains, and on the emit's own lane the row stands at its rest anyway
  local onward = spec.side == "to" and spec.opts.lane ~= nil and spec.opts.lane ~= "start"

  -- an endpoint standing where the row rests moves nothing only for an entry
  -- that begins at that rest. a chained one begins wherever the lanes before it
  -- left the row, so it is the phase that carries the row back and is kept
  if not onward and endpoint == rest then
    return nil
  end

  local runFor = pick(spec.opts.duration, ctx, attrs, props)
  local duration = if typeof(runFor) == "number" and runFor >= 0 then runFor else nil

  if spec.side == "from" and duration == 0 then
    return nil
  end

  local curve = pick(spec.opts.curve, ctx, attrs, props)

  return {
    kind = "tween",
    chain = onward,
    duration = duration,
    start = if onward then nil else value.lit(if spec.side == "from" then endpoint else rest),
    finish = value.lit(if spec.side == "from" then rest else endpoint),
    curve = curves.preset(if curve ~= nil then curve else rowCurve),
  }
end

-- the lane map a row's default modifiers run, one entry per spec in the lane
-- that spec named. nil when no spec has anything to say, so a row at rest costs
-- no sampler at all
function mod.lanes(
  specs: { Spec },
  ctx: any,
  attrs: any,
  props: any,
  rest: any,
  rowCurve: string?
): { [string]: { any } }?
  local out: { [string]: { any } } = {}
  local filled = false

  for _, spec in specs do
    local entry = entryOf(spec, ctx, attrs, props, rest, rowCurve)

    if entry == nil then
      continue
    end

    local lane = spec.opts.lane or "start"
    local queue = out[lane]

    if queue == nil then
      queue = {}
      out[lane] = queue
    end

    local wait = pick(spec.opts.delay, ctx, attrs, props)

    if typeof(wait) == "number" and wait > 0 then
      table.insert(queue, { kind = "delay", chain = false, wait = value.lit(wait) })
    end

    table.insert(queue, entry)
    filled = true
  end

  return if filled then out else nil
end

return mod
