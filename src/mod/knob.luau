local Knob = {}
Knob.__index = Knob

local knob = {}

knob.UNITS = {
  seconds = true,
  perSecond = true,
  perSecondSquared = true,
  studs = true,
  studsPerSecond = true,
  studsPerSecondSquared = true,
}

-- a module lists its rows in a table that keeps no order, so each row takes a
-- number at construction and the plugin lays rows out by it
local counter = 0

export type Rule = (ctx: any, attrs: any, props: any) -> any

-- the kind a value names, with the engine's two spellings of a vector read as
-- one. the package's only answer to that question: mods re-exports this one
function knob.kindOf(v: any)
  local t = typeof(v)

  return if t == "vector" then "Vector3" else t
end

-- never a name a chain method also answers to: an unset field of that name
-- would read as the method itself through Knob's own __index, not as nil
type Fields = {
  default: any,
  rule: Rule?,
  hasDefault: boolean,
  kind: string?,
  lower: any,
  upper: any,
  names: { string },
  choices: { string }?,
  title: string?,
  details: string?,
  preset: string?,
  units: string?,
  hiddenRule: Rule?,
  readonlyRule: Rule?,
  isSlider: boolean,
  dragLower: number?,
  dragUpper: number?,
  isSeed: boolean,
  isMod: boolean,
  modDefault: any,
  order: number,
}

export type Knob = typeof(setmetatable({} :: Fields, Knob))

local function make(default: any): Knob
  counter += 1

  local isRule = type(default) == "function"
  local hasDefault = default ~= nil and not isRule

  return setmetatable({
    default = if isRule then nil else default,
    rule = if isRule then default else nil,
    hasDefault = hasDefault,
    -- kept beside the default, which never changes after construction, so a
    -- reader asking what the row wants pays no typeof per read
    kind = if hasDefault then knob.kindOf(default) else nil,
    lower = nil,
    upper = nil,
    names = {},
    choices = nil,
    title = nil,
    details = nil,
    preset = nil,
    units = nil,
    hiddenRule = nil,
    readonlyRule = nil,
    isSlider = false,
    dragLower = nil,
    dragUpper = nil,
    isSeed = false,
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

function knob.is(x: any)
  return type(x) == "table" and getmetatable(x) == Knob
end

function Knob.min(self: Knob, v: any): Knob
  self.lower = v
  return self
end

function Knob.max(self: Knob, v: any): Knob
  self.upper = v
  return self
end

function Knob.aliases(self: Knob, ...: string): Knob
  self.names = { ... }
  return self
end

function Knob.options(self: Knob, list: { string }): Knob
  self.choices = list
  return self
end

function Knob.label(self: Knob, text: string): Knob
  self.title = text
  return self
end

function Knob.hint(self: Knob, text: string): Knob
  self.details = text
  return self
end

function Knob.curve(self: Knob, preset: string): Knob
  self.preset = preset
  return self
end

function Knob.unit(self: Knob, unit: string): Knob
  self.units = unit
  return self
end

function Knob.hidden(self: Knob, rule: Rule): Knob
  self.hiddenRule = rule
  return self
end

function Knob.readonly(self: Knob, rule: Rule): Knob
  self.readonlyRule = rule
  return self
end

-- a number row drawn as a slider, dragged from low to high, each its min or
-- max when left out. a typed value still clamps to min and max
function Knob.slider(self: Knob, low: number?, high: number?): Knob
  self.isSlider = true
  self.dragLower = low
  self.dragUpper = high
  return self
end

-- a number row drawn as a seed: the field and a reroll beside it, since the
-- one thing anyone does with a seed is try another. any number is a seed in
-- luau, so the row keeps the knob's own bounds and no others
function Knob.seed(self: Knob): Knob
  self.isSeed = true
  return self
end

-- a row may declare more than one default modifier, since its phases can run
-- from different triggers. an authored lane map replaces only the default
-- lanes it names
function Knob.mod(self: Knob, ...: any): Knob
  self.isMod = true

  if select("#", ...) > 0 then
    self.modDefault = { ... }
  end

  return self
end

-- shared by every effect's rows, whose unset rules read through it, and an
-- author's sdk.knob hands it out
table.freeze(Knob)

function knob.ordered(v: any)
  local t = typeof(v)

  return t == "number" or t == "NumberRange" or t == "Vector3" or t == "vector"
end

local function clampNumber(v: number, lo: any, hi: any)
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

function knob.clamp(v: any, lo: any, hi: any)
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
