local path_curve = require("@mod/common/path_curve")
local state_list = require("@mod/common/state_list")
local value_curve = require("@mod/value_curve")

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
  studsCubedPerSecondSquared = true,
}

-- a module lists its rows in a table that keeps no order, so each row takes a
-- number at construction and the plugin lays rows out by it
local counter = 0

export type Rule = (ctx: any, attrs: any, props: any) -> any

-- the kind a value names, with the engine's two spellings of a vector read as
-- one and a decoded value curve or state list named for itself. the package's
-- only answer to that question: mods re-exports this one
function knob.kindOf(v: any)
  local t = typeof(v)

  if t == "vector" then
    return "Vector3"
  end

  if t == "table" and value_curve.is(v) then
    return "ValueCurve"
  end

  if t == "table" and state_list.is(v) then
    return "StateList"
  end

  if t == "table" and path_curve.is(v) then
    return "Path"
  end

  return t
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
  classes: { string }?,
  channels: number?,
  title: string?,
  details: string?,
  preset: string?,
  units: string?,
  hiddenRule: Rule?,
  readonlyRule: Rule?,
  readonlyReason: string?,
  readonlyKeeps: boolean,
  alphaRow: string?,
  isSlider: boolean,
  dragLower: number?,
  dragUpper: number?,
  isSeed: boolean,
  isMod: boolean,
  modDefault: any,
  homeLane: string?,
  recolors: boolean?,
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
    classes = nil,
    channels = nil,
    title = nil,
    details = nil,
    preset = nil,
    units = nil,
    hiddenRule = nil,
    readonlyRule = nil,
    readonlyReason = nil,
    readonlyKeeps = false,
    alphaRow = nil,
    isSlider = false,
    dragLower = nil,
    dragUpper = nil,
    isSeed = false,
    isMod = false,
    modDefault = nil,
    homeLane = nil,
    recolors = nil,
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

-- what the row rests at where the instance stores nothing usable for it,
-- decided by the rule, for old content that rested somewhere else. the
-- default stays what a new instance rests at, what the plugin shows and the
-- kind a stored value is checked against, so the rule answers the default
-- for anything it does not know as old. a function of the module rather than
-- a method, so the frozen sdk 1, which hands authors knobs, never reaches it
function knob.legacy(row: Knob, rule: Rule): Knob
  row.rule = rule
  return row
end

-- a row the rule makes read only, `reason` the plugin's tooltip on it then
function Knob.readonly(self: Knob, rule: Rule, reason: string?): Knob
  self.readonlyRule = rule
  self.readonlyReason = reason
  self.readonlyKeeps = false
  return self
end

-- a row the rule shows read only that still reads as stored, for a row
-- something else plays over and whose value the author keeps
function Knob.grayed(self: Knob, rule: Rule, reason: string?): Knob
  self.readonlyRule = rule
  self.readonlyReason = reason
  self.readonlyKeeps = true
  return self
end

-- a color row whose editor also edits the named row as its transparency
function Knob.alpha(self: Knob, row: string): Knob
  self.alphaRow = row
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

-- a row the module plays from one of its events and never from the emit: the
-- old shapes and a start lane stored for it are that event's lane, since the
-- module only ever ran them from there
function Knob.lane(self: Knob, event: string): Knob
  self.homeLane = event
  return self
end

-- a row that holds an instance, picked by the artist. it has no default, so
-- an unset row reads nil. classes narrow the pick by IsA, none takes any
function Knob.instance(self: Knob, classes: { string }?): Knob
  self.kind = "Instance"
  self.classes = classes
  return self
end

-- a row that holds a value curve over a piece's life, stored as a string the
-- value_curve codec writes. its default is a decoded curve of this many
-- channels, which an unset or malformed attribute reads as
function Knob.valueCurve(self: Knob, channels: number): Knob
  local default = self.default

  if type(default) == "table" and default.channels ~= channels then
    error(`valueCurve({channels}) row has a default of {default.channels} channels`, 2)
  end

  self.kind = "ValueCurve"
  self.channels = channels
  return self
end

-- a row that holds a mesh's states, stored as a string the state_list codec
-- writes. its default is a decoded list, which an unset or malformed
-- attribute reads as
function Knob.stateList(self: Knob): Knob
  if not state_list.is(self.default) then
    error("stateList() row has a default that is no state list", 2)
  end

  self.kind = "StateList"
  return self
end

-- a row that holds a mesh's path, stored as a string the path_curve codec
-- writes. its default is a decoded curve, which an unset or malformed
-- attribute reads as
function Knob.path(self: Knob): Knob
  if not path_curve.is(self.default) then
    error("path() row has a default that is no path", 2)
  end

  self.kind = "Path"
  return self
end

-- whether a color row follows a recolor, the plugin's color picker or api.recolor. a color row follows one unless
-- it is declared :recolor(false), as a shadow or an outline that keeps its own color would be
function Knob.recolor(self: Knob, on: boolean?): Knob
  self.recolors = on ~= false
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
