local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local logger = require("@mod/logger")
local legacy_mods = require("@mod/legacy_mods")
local numeric_common = require("@mod/common/numeric")

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
  constant: boolean?,
  events: { string }?,
  emit: (ctx: any, attrs: any, props: any) -> (),
  selected: ((ctx: any) -> ())?,
}

-- the two maps a particle's ancestry clone is shared through for the life of
-- one emit, built by the dispatcher and handed to every effect of that emit
export type Shared = {
  unc: { [Instance]: number },
  ref: { [Instance]: Instance },
}

export type Ctx = {
  ref: Instance,
  obj: Instance,
  scope: any?,
  scale: number,
  effect: Module?,
  duration: number?,
  shared: Shared?,
  constant: boolean?,
  piece: mods.Piece?,
}

export type Track = {
  at: (elapsed: number, own: any?, since: number?) -> any,
  duration: number,
  animated: boolean,
  value: any,
  has: (lane: string) -> boolean,
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

-- the indexing a property row's base is read through, kept out of propertyOf so
-- the pcall below has a function to call rather than one to build per row
local function indexOf(obj: Instance, name: string)
  return (obj :: any)[name]
end

local function propertyOf(obj: Instance, name: string)
  local ok, v = pcall(indexOf, obj, name)

  return if ok then v else nil
end

type Lookup = (ref: Instance, source: string, name: string, map: { [string]: any }, children: { Instance }?) -> any?

-- a row's lanes, its framed flag and the spelling it was found under, kept
-- together so a piece calling the row a second time is handed the one lookup
-- rather than paying for it again
type Found = { lanes: { [string]: { any } }?, framed: boolean, under: string? }

-- everything one read carries, built once and handed down to the steps below.
-- the steps are written at load rather than rebuilt per read, so a module's
-- rows pay for themselves and nothing else. it doubles as the metatable of both
-- row tables, which is why it names __index
type State = {
  ctx: Ctx,
  map: { [string]: any },
  attrs: any,
  props: any,
  module: Module,
  duration: number?,
  deciding: boolean,
  children: { Instance }?,
  piece: mods.Piece?,
  attrPending: { [string]: boolean },
  propPending: { [string]: boolean },
  attrQueues: { [string]: Found }?,
  propQueues: { [string]: Found }?,
  __index: (t: any, k: any) -> any,
}

-- the one option a piece's own track is built with. shared because mods.build
-- only ever reads it
local SEEDED = table.freeze({ ownStart = true })

-- the instance's children, taken once for the whole read and handed to every
-- old shape that walks them, rather than once per row per side. taken on the
-- first row that reaches the old shapes at all, so a read that finds every row
-- authored the current way takes none
local function childrenOf(state: State)
  local children = state.children

  if children == nil then
    children = state.ctx.ref:GetChildren()
    state.children = children
  end

  return children
end

-- the old spellings of a row, after its own name has already missed. walked in
-- place rather than gathered into a table the row would pay for on every read.
-- the second return is the spelling it answered under
local function aliasOf(
  look: Lookup,
  ref: Instance,
  source: string,
  row: knob.Knob,
  map: { [string]: any },
  children: { Instance }?
): (any?, string?)
  for _, alias in row.names do
    local queue = look(ref, source, alias, map, children)

    if queue ~= nil then
      return queue, alias
    end
  end

  return nil, nil
end

-- the lanes a row carries, looked for under its name and then each alias: any
-- framed map first, on the row's own side and then, for a property row, on the
-- attribute side old content authored on; then the old shapes, in the same
-- order. the third return is the alias it was found under, which is the name
-- the base behind it is stored under too
local function queueOf(
  state: State,
  source: string,
  name: string,
  row: knob.Knob
): ({ [string]: { any } }?, boolean, string?)
  local ref = state.ctx.ref
  local map = state.map
  local aliased = row.names[1] ~= nil
  local lanes = mods.framed(ref, source, name, map)
  local under: string? = nil

  if lanes == nil and aliased then
    lanes, under = aliasOf(mods.framed, ref, source, row, map)
  end

  if lanes == nil and source == "property" then
    lanes = mods.framed(ref, "attribute", name, map)

    if lanes == nil and aliased then
      lanes, under = aliasOf(mods.framed, ref, "attribute", row, map)
    end
  end

  if lanes ~= nil then
    return lanes, true, under
  end

  local children = childrenOf(state)

  local queue = legacy_mods.read(ref, source, name, map, children)

  if queue == nil and aliased then
    queue, under = aliasOf(legacy_mods.read, ref, source, row, map, children)
  end

  if queue == nil and source == "property" then
    queue = legacy_mods.read(ref, "attribute", name, map, children)

    if queue == nil and aliased then
      queue, under = aliasOf(legacy_mods.read, ref, "attribute", row, map, children)
    end
  end

  if queue == nil then
    return nil, false, under
  end

  -- the old format had one trigger, which is the lane every queue was
  return { start = queue }, false, under
end

local function usableDuration(d: any)
  if typeof(d) ~= "number" or d ~= d or d <= 0 or d == math.huge then
    return 1
  end

  return d
end

-- the queue a row carries, found once per read: a piece calling the row for a
-- track of its own runs the rules again over what was stored at the read, since
-- the stored content does not change between the read and the piece. the memo a
-- side keeps is built on the first mod row that side has, so a module with none
-- never allocates one
local function queueFor(state: State, source: string, name: string, row: knob.Knob): Found
  local memo

  if source == "property" then
    memo = state.propQueues

    if memo == nil then
      memo = {}
      state.propQueues = memo
    end
  else
    memo = state.attrQueues

    if memo == nil then
      memo = {}
      state.attrQueues = memo
    end
  end

  local found = memo[name]

  if found == nil then
    local lanes, framed, under = queueOf(state, source, name, row)

    found = { lanes = lanes, framed = framed, under = under }
    memo[name] = found
  end

  return found
end

local function durationOf(state: State): number
  local known = state.duration

  if known ~= nil then
    return known
  end

  local module = state.module

  if state.deciding then
    logger.error(`effect module {module.id}: duration is defined in terms of itself`)
  end

  state.deciding = true

  local ctx = state.ctx
  local d = if module.duration then module.duration(ctx, state.attrs, state.props) else 1

  state.deciding = false

  local decided = usableDuration(d)

  state.duration = decided
  ctx.duration = decided

  return decided
end

-- what a row rests at when nothing usable is stored for it. taking the row and
-- its base keeps it one function for the whole package rather than one closure
-- per row
local function fallbackOf(state: State, row: knob.Knob, base: any)
  if row.rule then
    return row.rule(state.ctx, state.attrs, state.props)
  end

  if row.hasDefault then
    return row.default
  end

  return base
end

-- the piece a row's lanes fire on when the caller named none: one per read,
-- which is what a module emitting a single piece per emit wants. built on the
-- first mod row that asks for one, so a module with none allocates nothing
local function pieceOf(state: State): mods.Piece
  local piece = state.piece

  if piece == nil then
    piece = mods.piece(state.module.events)
    state.piece = piece
    state.ctx.piece = piece
  end

  return piece
end

local function plainOf(state: State, source: string, name: string, row: knob.Knob)
  local ctx = state.ctx
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
  local map = state.map
  local v = map[name]

  if v == nil then
    for _, alias in row.names do
      v = map[alias]

      if v ~= nil then
        break
      end
    end
  end

  -- an authored value no clock or lerp can use reads as the row's fallback,
  -- the way every read did before rows
  if v ~= nil and not numeric_common.usable(v) then
    v = fallbackOf(state, row, base)
  end

  if v == nil then
    v = base
  end

  if v == nil then
    v = fallbackOf(state, row, base)
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
      v = fallbackOf(state, row, base)
    elseif got ~= want then
      mods.warnOnce(ctx.ref, name, `{name} holds a {got} where {state.module.id} wants a {want}`)
      v = fallbackOf(state, row, base)
    end
  end

  if row.readonlyRule ~= nil and row.readonlyRule(ctx, state.attrs, state.props) == true then
    v = fallbackOf(state, row, base)
  end

  if row.choices ~= nil and (typeof(v) ~= "string" or table.find(row.choices, v) == nil) then
    v = fallbackOf(state, row, base)
  end

  return knob.clamp(v, row.lower, row.upper)
end

-- a stored map that moves nothing: no lane at all, or every lane empty or
-- holding only values the target already carries
local function silent(lanes: { [string]: { any } }): boolean
  for _, queue in lanes do
    if #queue > 0 and not mods.inert(queue) then
      return false
    end
  end

  return true
end

local function trackOf(
  state: State,
  source: string,
  name: string,
  row: knob.Knob,
  rest: any,
  seeded: boolean,
  span: number,
  piece: mods.Piece?
): Track
  local ctx = state.ctx
  local found = queueFor(state, source, name, row)

  -- an existing queue, even an empty one or one that only waits, means the
  -- author owns the row: it is a tombstone, deliberately silencing even the
  -- row's own default modifier rather than falling back to it, which is
  -- what mods.build would otherwise read such a queue as
  local tombstone = found.framed and found.lanes ~= nil and silent(found.lanes)

  local default: any = rest

  -- a range is the row's state and a draw from it is what a piece takes,
  -- tombstone or not: this is not a default, it is what a range row's own
  -- value always means. a default modifier is a queue from the state to
  -- its endpoint, and a tombstone silences that instead
  if typeof(rest) == "NumberRange" then
    default = mods.draw(rest.Min, rest.Max)
  elseif not tombstone and row.modDefault ~= nil then
    default = mod.lanes(row.modDefault, ctx, state.attrs, state.props, rest, row.preset) or rest
  end

  local own = if piece ~= nil then piece else pieceOf(state)
  local opts = if seeded then SEEDED else nil
  -- an attribute row builds under the name its queue was found under, since
  -- that is where the value it chains from and the range it draws inside are
  -- stored too; a property row's base is the property, whatever the spelling
  local built = if source == "property" then name else found.under or name
  local inner = mods.build(ctx.ref, source, built, default, span, nil, found.lanes, found.framed, opts, own)

  local track = {
    at = inner.at,
    duration = inner.span,
    animated = inner.animated,
    value = rest,
    has = inner.has,
  }

  function track.apply(_, write: (v: any) -> ())
    if reader.bind == nil or ctx.scope == nil then
      logger.error(`{name} cannot be applied without a running effect`)
    end

    local bind = reader.bind :: any

    bind(ctx.scope, inner, write)
  end

  -- a piece calls the row for a track of its own: rules run again, a value
  -- handed in is where this piece's state is, a span handed in is the clock this
  -- piece runs over when it drew one, and a piece handed in is the clock its own
  -- event lanes fire on
  setmetatable(track, {
    __call = function(_, current: any, span: number?, own: mods.Piece?)
      local held = if current ~= nil then current else plainOf(state, source, name, row)

      return trackOf(state, source, name, row, held, current ~= nil, span or durationOf(state), own)
    end,
  })

  return table.freeze(track) :: any
end

local function resolveRow(
  state: State,
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
    logger.error(`effect module {state.module.id}: {name} is defined in terms of itself`)
  end

  pending[name] = true

  local rest = plainOf(state, source, name, row)
  local v = rest

  -- a mod row pulled while the duration rule is still deciding is built over
  -- a span of one and not kept, so the rule may read the row's own value and
  -- must not read at: the track it sees is not the one the pass after the
  -- duration is known builds and keeps
  local provisional = row.isMod and state.deciding

  if row.isMod then
    v = trackOf(state, source, name, row, rest, false, if provisional then 1 else durationOf(state))
  end

  if not provisional then
    rawset(out, name, v)
  end

  pending[name] = nil

  return v
end

-- which of the two row tables a rule reached through, told apart by the table
-- itself, so the one state the read already holds is the metatable of both and
-- no __index closure is built per read
local function rowIndex(t: any, k: any)
  local state = getmetatable(t) :: State
  local module = state.module

  if rawequal(t, state.attrs) then
    return resolveRow(state, t, module.attributes, state.attrPending, "attribute", k)
  end

  return resolveRow(state, t, module.properties, state.propPending, "property", k)
end

function reader.resolve(module: Module, ctx: Ctx): (any, any)
  local attrs = {}
  local props = {}

  -- rows resolve on first access, in whatever order rules pull each other, and
  -- one pulling itself is a module bug rather than a runtime state. a guard
  -- table per source keys a row by its own name, so the guard costs no string
  -- built per read
  local state: State = {
    ctx = ctx,
    map = reader.source(ctx.ref),
    attrs = attrs,
    props = props,
    module = module,
    duration = nil,
    deciding = false,
    children = nil,
    piece = nil,
    attrPending = {},
    propPending = {},
    attrQueues = nil,
    propQueues = nil,
    __index = rowIndex,
  }

  setmetatable(attrs, state)
  setmetatable(props, state)

  -- resolved before the walk below touches anything, so a mod row the rule
  -- reads is still pulled through the provisional branch rather than through
  -- a walk that would otherwise reach it first and lock its own key
  durationOf(state)

  -- resolved straight rather than through the __index just installed, which
  -- would only find the row missing and call the same function. a row a rule
  -- already pulled is left as it resolved
  for name in module.attributes do
    if rawget(attrs, name) == nil then
      resolveRow(state, attrs, module.attributes, state.attrPending, "attribute", name)
    end
  end

  for name in module.properties do
    if rawget(props, name) == nil then
      resolveRow(state, props, module.properties, state.propPending, "property", name)
    end
  end

  setmetatable(attrs, nil)
  setmetatable(props, nil)

  return table.freeze(attrs), table.freeze(props)
end

return reader
