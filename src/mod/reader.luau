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
function reader.defaultSource(inst: Instance)
  return attr.map(inst)
end

reader.source = reader.defaultSource

-- what apply binds a track with. the engine helper is out of this module's
-- reach, so the dispatcher hands it in at load
reader.bind = nil :: ((scope: any, track: mods.Track, write: (v: any) -> ()) -> ())?

local function propertyOf(obj: Instance, name: string)
  local ok, v = pcall(function()
    return (obj :: any)[name]
  end)

  return if ok then v else nil
end

type Lookup = (ref: Instance, source: string, name: string) -> { any }?

-- the old spellings of a row, after its own name has already missed. walked in
-- place rather than gathered into a table the row would pay for on every read.
-- the second return is the spelling it answered under
local function aliasOf(look: Lookup, ref: Instance, source: string, row: knob.Knob): ({ any }?, string?)
  for _, alias in row.names do
    local queue = look(ref, source, alias)

    if queue ~= nil then
      return queue, alias
    end
  end

  return nil, nil
end

-- the queue a row carries, looked for under its name and then each alias: any
-- framed queue first, on the row's own side and then, for a property row, on
-- the attribute side old content authored on; then the old shapes, looked for
-- on the row's own side and then, for a property row, on the attribute side
-- old content authored on. the third return is the alias it was found under,
-- which is the name the base behind it is stored under too
local function queueOf(ref: Instance, source: string, name: string, row: knob.Knob): ({ any }?, boolean, string?)
  local aliased = row.names[1] ~= nil
  local queue = mods.framed(ref, source, name)
  local under: string? = nil

  if queue == nil and aliased then
    queue, under = aliasOf(mods.framed, ref, source, row)
  end

  if queue == nil and source == "property" then
    queue = mods.framed(ref, "attribute", name)

    if queue == nil and aliased then
      queue, under = aliasOf(mods.framed, ref, "attribute", row)
    end
  end

  if queue ~= nil then
    return queue, true, under
  end

  queue = legacy_mods.read(ref, source, name)

  if queue == nil and aliased then
    queue, under = aliasOf(legacy_mods.read, ref, source, row)
  end

  if queue == nil and source == "property" then
    queue = legacy_mods.read(ref, "attribute", name)

    if queue == nil and aliased then
      queue, under = aliasOf(legacy_mods.read, ref, "attribute", row)
    end
  end

  return queue, false, under
end

local function usableDuration(d: any)
  if typeof(d) ~= "number" or d ~= d or d <= 0 or d == math.huge then
    return 1
  end

  return d
end

function reader.resolve(module: Module, ctx: Ctx): (any, any)
  local map = reader.source(ctx.ref)

  local attrs = {}
  local props = {}

  -- rows resolve on first access, in whatever order rules pull each other, and
  -- one pulling itself is a module bug rather than a runtime state. a guard
  -- table per source keys a row by its own name, so the guard costs no string
  -- built per read
  local attrPending: { [string]: boolean } = {}
  local propPending: { [string]: boolean } = {}
  local deciding = false
  local duration: number? = nil

  local function durationOf(): number
    if duration ~= nil then
      return duration
    end

    if deciding then
      logger.error(`effect module {module.id}: duration is defined in terms of itself`)
    end

    deciding = true

    local d = if module.duration then module.duration(ctx, attrs, props) else 1

    deciding = false
    duration = usableDuration(d)
    ctx.duration = duration

    return duration
  end

  -- what a row rests at when nothing usable is stored for it. taking the row
  -- and its base keeps it one function for the whole resolve rather than one
  -- closure per row
  local function fallbackOf(row: knob.Knob, base: any)
    if row.rule then
      return row.rule(ctx, attrs, props)
    end

    if row.hasDefault then
      return row.default
    end

    return base
  end

  local function plainOf(source: string, name: string, row: knob.Knob)
    local base = if source == "property" then propertyOf(ctx.obj, name) else nil
    local want: string? = nil

    if row.hasDefault then
      want = row.kind
    elseif base ~= nil then
      want = knob.kindOf(base)
    end

    -- a property row's state is the property, unless an attribute of its name
    -- shadows it, which is how old content overrode one. a row answers to its
    -- old spellings here too
    local v = map[name]

    if v == nil then
      for _, alias in row.names do
        v = map[alias]

        if v ~= nil then
          break
        end
      end
    end

    if v == nil then
      v = base
    end

    if v == nil then
      v = fallbackOf(row, base)
    elseif want ~= nil then
      local got = knob.kindOf(v)

      -- a scalar stored for a range row is the range it always meant
      if want == "NumberRange" and got == "number" then
        v = NumberRange.new(v, v)
        got = want
      end

      -- a range stored on a scalar mod row is the randomizer queueOf reads
      -- under the same name, so the row rests at its own fallback and the draw
      -- comes from the range rather than from a warning
      if row.isMod and want == "number" and got == "NumberRange" then
        v = fallbackOf(row, base)
      elseif got ~= want then
        mods.warnOnce(ctx.ref, name, `{name} holds a {got} where {module.id} wants a {want}`)
        v = fallbackOf(row, base)
      end
    end

    if row.readonlyRule ~= nil and row.readonlyRule(ctx, attrs, props) == true then
      v = fallbackOf(row, base)
    end

    if row.choices ~= nil and (typeof(v) ~= "string" or table.find(row.choices, v) == nil) then
      v = fallbackOf(row, base)
    end

    return knob.clamp(v, row.lower, row.upper)
  end

  local function trackOf(source: string, name: string, row: knob.Knob, rest: any, seeded: boolean, span: number): Track
    local queue, framed, under = queueOf(ctx.ref, source, name, row)

    -- an existing queue, even an empty one or one that only waits, means the
    -- author owns the row: it is a tombstone, deliberately silencing even the
    -- row's own default modifier rather than falling back to it, which is
    -- what mods.build would otherwise read such a queue as
    local tombstone = framed and queue ~= nil and (#queue == 0 or mods.inert(queue))

    local default: any = rest

    -- a range is the row's state and a draw from it is what a piece takes,
    -- tombstone or not: this is not a default, it is what a range row's own
    -- value always means. a default modifier is a queue from the state to
    -- its endpoint, and a tombstone silences that instead
    if typeof(rest) == "NumberRange" then
      default = mods.draw(rest.Min, rest.Max)
    elseif not tombstone and row.modDefault ~= nil then
      default = mod.queue(row.modDefault, ctx, attrs, props, rest, row.preset) or rest
    end

    local opts = if seeded then { ownStart = true } else nil
    -- an attribute row builds under the name its queue was found under, since
    -- that is where the value it chains from and the range it draws inside are
    -- stored too; a property row's base is the property, whatever the spelling
    local built = if source == "property" then name else under or name
    local inner = mods.build(ctx.ref, source, built, default, span, nil, queue, framed, opts)

    local track = {
      at = inner.at,
      duration = inner.span,
      animated = inner.animated,
      value = rest,
    }

    function track.apply(_, write: (v: any) -> ())
      if reader.bind == nil or ctx.scope == nil then
        logger.error(`{name} cannot be applied without a running effect`)
      end

      local bind = reader.bind :: any

      bind(ctx.scope, inner, write)
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

  local function resolveRow(
    out: any,
    rows: { [string]: knob.Knob },
    pending: { [string]: boolean },
    source: string,
    name: string
  )
    local row = rows[name]

    if row == nil then
      return nil
    end

    if pending[name] then
      logger.error(`effect module {module.id}: {name} is defined in terms of itself`)
    end

    pending[name] = true

    local rest = plainOf(source, name, row)
    local v = rest

    -- a mod row pulled while the duration rule is still deciding is built over
    -- a span of one and not kept, so the rule may read the row's own value and
    -- must not read at: the track it sees is not the one the pass after the
    -- duration is known builds and keeps
    local provisional = row.isMod and deciding

    if row.isMod then
      v = trackOf(source, name, row, rest, false, if provisional then 1 else durationOf())
    end

    if not provisional then
      rawset(out, name, v)
    end

    pending[name] = nil

    return v
  end

  setmetatable(attrs, {
    __index = function(t, k)
      return resolveRow(t, module.attributes, attrPending, "attribute", k)
    end,
  })

  setmetatable(props, {
    __index = function(t, k)
      return resolveRow(t, module.properties, propPending, "property", k)
    end,
  })

  -- resolved before the walk below touches anything, so a mod row the rule
  -- reads is still pulled through the provisional branch rather than through
  -- a walk that would otherwise reach it first and lock its own key
  durationOf()

  -- resolved straight rather than through the __index just installed, which
  -- would only find the row missing and call the same function. a row a rule
  -- already pulled is left as it resolved
  for name in module.attributes do
    if rawget(attrs, name) == nil then
      resolveRow(attrs, module.attributes, attrPending, "attribute", name)
    end
  end

  for name in module.properties do
    if rawget(props, name) == nil then
      resolveRow(props, module.properties, propPending, "property", name)
    end
  end

  setmetatable(attrs, nil)
  setmetatable(props, nil)

  return table.freeze(attrs), table.freeze(props)
end

return reader
