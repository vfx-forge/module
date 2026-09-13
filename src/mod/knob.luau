local Knob = {}
Knob.__index = Knob

local knob = {}

knob.UNITS = {
  seconds = true,
  perSecond = true,
  perSecondSquared = true,
  studs = true,
}

-- a module lists its rows in a table that keeps no order, so each row takes a
-- number at construction and the plugin lays rows out by it
local counter = 0

export type Rule = (ctx: any, attrs: any, props: any) -> any

type Fields = {
  default: any,
  rule: Rule?,
  hasDefault: boolean,
  min: any,
  max: any,
  aliases: { string }?,
  options: { string }?,
  label: string?,
  hint: string?,
  curve: string?,
  unit: string?,
  hidden: Rule?,
  readonly: Rule?,
  isMod: boolean,
  modDefault: any,
  order: number,
}

export type Knob = typeof(setmetatable({} :: Fields, Knob))

local function make(default: any): Knob
  counter += 1

  local isRule = type(default) == "function"

  return setmetatable({
    default = if isRule then nil else default,
    rule = if isRule then default else nil,
    hasDefault = default ~= nil and not isRule,
    min = nil,
    max = nil,
    aliases = nil,
    options = nil,
    label = nil,
    hint = nil,
    curve = nil,
    unit = nil,
    hidden = nil,
    readonly = nil,
    isMod = false,
    modDefault = nil,
    order = counter,
  }, Knob)
end

setmetatable(knob, {
  __call = function(_, default: any)
    return make(default)
  end,
})

function knob.is(x: any): boolean
  return type(x) == "table" and getmetatable(x) == Knob
end

function Knob.min(self: Knob, v: any): Knob
  self.min = v
  return self
end

function Knob.max(self: Knob, v: any): Knob
  self.max = v
  return self
end

function Knob.aliases(self: Knob, ...: string): Knob
  self.aliases = { ... }
  return self
end

function Knob.options(self: Knob, list: { string }): Knob
  self.options = list
  return self
end

function Knob.label(self: Knob, text: string): Knob
  self.label = text
  return self
end

function Knob.hint(self: Knob, text: string): Knob
  self.hint = text
  return self
end

function Knob.curve(self: Knob, preset: string): Knob
  self.curve = preset
  return self
end

function Knob.unit(self: Knob, unit: string): Knob
  self.unit = unit
  return self
end

function Knob.hidden(self: Knob, rule: Rule): Knob
  self.hidden = rule
  return self
end

function Knob.readonly(self: Knob, rule: Rule): Knob
  self.readonly = rule
  return self
end

function Knob.mod(self: Knob, default: any): Knob
  self.isMod = true
  self.modDefault = default
  return self
end

function knob.ordered(v: any): boolean
  local t = typeof(v)

  return t == "number" or t == "NumberRange" or t == "Vector3" or t == "vector"
end

local function clampNumber(v: number, lo: any, hi: any): number
  if typeof(lo) == "number" then
    v = math.max(v, lo)
  end

  if typeof(hi) == "number" then
    v = math.min(v, hi)
  end

  return v
end

-- a number bound applies to every field, a bound of the value's own type
-- fieldwise
local function boundAt(bound: any, field: string): number?
  if bound == nil or typeof(bound) == "number" then
    return bound
  end

  return (bound :: any)[field]
end

-- the engine spells the same vector two ways, and only one of them answers to
-- an upper case field. a bound that is a number or nil passes through
local function axis(v: any, upper: string, lower: string): number?
  local t = typeof(v)

  if t == "vector" then
    return (v :: any)[lower]
  end

  if t == "Vector3" then
    return (v :: any)[upper]
  end

  return v
end

function knob.clamp(v: any, lo: any, hi: any): any
  if lo == nil and hi == nil then
    return v
  end

  local t = typeof(v)

  if t == "number" then
    return clampNumber(v, lo, hi)
  end

  if t == "NumberRange" then
    return NumberRange.new(
      clampNumber(v.Min, boundAt(lo, "Min"), boundAt(hi, "Min")),
      clampNumber(v.Max, boundAt(lo, "Max"), boundAt(hi, "Max"))
    )
  end

  if t == "Vector3" or t == "vector" then
    local x = clampNumber(axis(v, "X", "x"), axis(lo, "X", "x"), axis(hi, "X", "x"))
    local y = clampNumber(axis(v, "Y", "y"), axis(lo, "Y", "y"), axis(hi, "Y", "y"))
    local z = clampNumber(axis(v, "Z", "z"), axis(lo, "Z", "z"), axis(hi, "Z", "z"))

    -- built in the spelling it came in, so a clamped value still equals an
    -- unclamped one of the same spelling
    return if t == "vector" then vector.create(x, y, z) else Vector3.new(x, y, z)
  end

  return v
end

return knob
