local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local logger = require("@mod/logger")
local legacy_mods = require("@mod/legacy_mods")

local reader = {}

export type Module = {
  id: string,
  display: { name: string, icon: string?, order: number? },
  classifier: string,
  components: string?,
  attributes: { [string]: knob.Knob },
  properties: { [string]: knob.Knob },
  layout: { any }?,
  duration: knob.Rule?,
  emit: (ctx: any, attrs: any, props: any) -> (),
  selected: ((ctx: any) -> ())?,
}

export type Ctx = {
  ref: Instance,
  obj: Instance,
  scope: any?,
  scale: number,
  effect: Module?,
  duration: number?,
}

export type Track = {
  at: (elapsed: number) -> any,
  duration: number,
  animated: boolean,
  value: any,
  apply: (self: Track, write: (v: any) -> ()) -> (),
}

-- where the walk takes an instance's attributes from. replaceable, for a host
-- that keeps effect values somewhere other than attributes
function reader.defaultSource(inst: Instance): { [string]: any }
  return attr.map(inst)
end

reader.source = reader.defaultSource

-- what apply binds a track with. the engine helper is out of this module's
-- reach, so the dispatcher hands it in at load
reader.drive = nil :: ((scope: any, track: mods.Track, write: (v: any) -> ()) -> ())?

local function propertyOf(obj: Instance, name: string): any
  local ok, v = pcall(function()
    return (obj :: any)[name]
  end)

  return if ok then v else nil
end

-- a knob's chain methods live on the same table as its fields and share their
-- names, so an unset field falls through the metatable to the setter itself
-- rather than reading nil; the raw slot is what a row's own state actually is
local function field(row: knob.Knob, key: string): any
  return rawget(row, key)
end

local function stored(map: { [string]: any }, name: string, row: knob.Knob): any
  local v = map[name]

  if v ~= nil then
    return v
  end

  for _, alias in field(row, "aliases") or {} do
    v = map[alias]

    if v ~= nil then
      return v
    end
  end

  return nil
end

-- a scalar stored for a range row is the range it always meant
local function coerce(v: any, want: string?): any
  if want == "NumberRange" and typeof(v) == "number" then
    return NumberRange.new(v, v)
  end

  return v
end

-- the queue a row carries, looked for under its name and then each alias: any
-- framed queue first, on the row's own side and then, for a property row, on
-- the attribute side old content authored on; then the old shapes, which are
-- attribute quads whichever side the row reads
local function queueOf(ref: Instance, source: string, name: string, row: knob.Knob): ({ any }?, boolean)
  local names = { name }

  for _, alias in field(row, "aliases") or {} do
    table.insert(names, alias)
  end

  for _, n in names do
    local queue = mods.framed(ref, source, n)

    if queue ~= nil then
      return queue, true
    end
  end

  if source == "property" then
    for _, n in names do
      local queue = mods.framed(ref, "attribute", n)

      if queue ~= nil then
        return queue, true
      end
    end
  end

  for _, n in names do
    local queue = legacy_mods.read(ref, source, n)

    if queue ~= nil then
      return queue, false
    end
  end

  return nil, false
end

local function usableDuration(d: any): number
  if typeof(d) ~= "number" or d ~= d or d <= 0 or d == math.huge then
    return 1
  end

  return d
end

function reader.resolve(module: Module, ctx: Ctx): (any, any)
  local map = reader.source(ctx.ref)

  local attrs = {}
  local props = {}

  -- rows resolve on first access, in whatever order rules pull each other,
  -- and one pulling itself is a module bug rather than a runtime state
  local resolving: { [string]: boolean } = {}
  local duration: number? = nil

  local function durationOf(): number
    if duration ~= nil then
      return duration
    end

    if resolving.duration then
      logger.error(`effect module {module.id}: duration is defined in terms of itself`)
    end

    resolving.duration = true

    local d = if module.duration then module.duration(ctx, attrs, props) else 1

    resolving.duration = nil
    duration = usableDuration(d)
    ctx.duration = duration

    return duration
  end

  local function plainOf(source: string, name: string, row: knob.Knob): any
    local base = if source == "property" then propertyOf(ctx.obj, name) else nil
    local want: string? = nil

    if row.hasDefault then
      want = mods.kindOf(row.default)
    elseif base ~= nil then
      want = mods.kindOf(base)
    end

    local function fallback(): any
      if row.rule then
        return row.rule(ctx, attrs, props)
      end

      if row.hasDefault then
        return row.default
      end

      return base
    end

    -- a property row's state is the property, unless an attribute of its name
    -- shadows it, which is how old content overrode one
    local v = stored(map, name, row)

    if v == nil then
      v = base
    end

    if v == nil then
      v = fallback()
    else
      v = coerce(v, want)

      if want ~= nil and mods.kindOf(v) ~= want then
        mods.warnOnce(ctx.ref, name, `{name} holds a {mods.kindOf(v)} where {module.id} wants a {want}`)
        v = fallback()
      end
    end

    local readonly = field(row, "readonly")

    if readonly ~= nil and readonly(ctx, attrs, props) == true then
      v = fallback()
    end

    local options = field(row, "options")

    if options ~= nil and (typeof(v) ~= "string" or table.find(options, v) == nil) then
      v = fallback()
    end

    return knob.clamp(v, field(row, "min"), field(row, "max"))
  end

  local function trackOf(source: string, name: string, row: knob.Knob, rest: any, seeded: boolean, span: number): Track
    local queue, framed = queueOf(ctx.ref, source, name, row)

    -- an authored queue with nothing in it is a tombstone, deliberately
    -- silencing even the row's own default modifier rather than falling back
    -- to it, which is what mods.build would otherwise read an empty queue as
    local tombstone = framed and queue ~= nil and #queue == 0

    local default: any = rest

    -- a range is the row's state and a draw from it is what a piece takes; a
    -- default modifier is a queue from the state to its endpoint
    if not tombstone then
      if typeof(rest) == "NumberRange" then
        default = mods.draw(rest.Min, rest.Max)
      elseif row.modDefault ~= nil then
        default = mod.queue(row.modDefault, ctx, attrs, props, rest, field(row, "curve")) or rest
      end
    end

    local opts = if seeded then { ownStart = true } else nil
    local inner = mods.build(ctx.ref, source, name, default, span, nil, queue, framed, opts)

    local track = {
      at = inner.at,
      duration = inner.span,
      animated = inner.animated,
      value = rest,
    }

    function track.apply(_, write: (v: any) -> ())
      if reader.drive == nil or ctx.scope == nil then
        logger.error(`{name} cannot be applied without a running effect`)
      end

      local drive = reader.drive :: any

      drive(ctx.scope, inner, write)
    end

    -- a piece calls the row for a track of its own: rules run again, and a
    -- value handed in is where this piece's state is
    setmetatable(track, {
      __call = function(_, current: any)
        local state = if current ~= nil then current else plainOf(source, name, row)

        return trackOf(source, name, row, state, current ~= nil, durationOf())
      end,
    })

    return table.freeze(track) :: any
  end

  local function resolveRow(out: any, rows: { [string]: knob.Knob }, source: string, name: string): any
    local row = rows[name]

    if row == nil then
      return nil
    end

    local key = `{source}.{name}`

    if resolving[key] then
      logger.error(`effect module {module.id}: {name} is defined in terms of itself`)
    end

    resolving[key] = true

    local rest = plainOf(source, name, row)
    local v = rest

    -- a mod row pulled while the duration rule is still deciding is built over
    -- a span of one and not kept, so the rule may read the row's own value;
    -- the pass after the duration is known builds the track that stays
    local provisional = row.isMod and resolving.duration == true

    if row.isMod then
      v = trackOf(source, name, row, rest, false, if provisional then 1 else durationOf())
    end

    if not provisional then
      rawset(out, name, v)
    end

    resolving[key] = nil

    return v
  end

  setmetatable(attrs, {
    __index = function(t, k)
      return resolveRow(t, module.attributes, "attribute", k)
    end,
  })

  setmetatable(props, {
    __index = function(t, k)
      return resolveRow(t, module.properties, "property", k)
    end,
  })

  -- resolved before the walk below touches anything, so a mod row the rule
  -- reads is still pulled through the provisional branch rather than through
  -- a walk that would otherwise reach it first and lock its own key
  durationOf()

  for name in module.attributes do
    local _ = attrs[name]
  end

  for name in module.properties do
    local _ = props[name]
  end

  setmetatable(attrs, nil)
  setmetatable(props, nil)

  return table.freeze(attrs), table.freeze(props)
end

return reader
