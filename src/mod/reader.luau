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

-- the maps a particle's ancestry clone is shared through for the life of one
-- emit, built by the dispatcher and handed to every effect of that emit
export type Shared = {
  unc: { [Instance]: number },
  ref: { [Instance]: Instance },
  held: { [Instance]: { any } },
}

export type Ctx = {
  ref: Instance,
  obj: Instance,
  scope: any?,
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
  reach: (lane: string) -> number,
  still: (lane: string, at: number) -> boolean,
  apply: (self: Track, write: (v: any) -> (), done: (() -> ())?) -> (),
}

-- where the walk takes an instance's attributes from. replaceable, for a host
-- that keeps effect values somewhere other than attributes
function reader.defaultSource(inst: Instance)
  return attr.map(inst)
end

reader.source = reader.defaultSource

-- what apply binds a track with. the engine helper is out of this module's
-- reach, so the dispatcher hands it in at load
reader.bind = nil :: ((scope: any, track: Track, write: (v: any) -> (), follow: number?, done: (() -> ())?) -> ())?

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
-- rather than paying for it again. live is the range row's lanes filtered of
-- what moves nothing, built once on the first piece call that needs it. share
-- hands the lanes the read built to a piece calling the row with nothing of its
-- own, over the span it was built for and resting where rest says
type Found = {
  lanes: { [string]: { any } }?,
  framed: boolean,
  under: string?,
  live: { [string]: { any } }?,
  share: ((other: mods.Piece) -> mods.Track?)?,
  shareSpan: number?,
  rest: any,
}

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

-- the piece every read of a module that fires no event hands its rows: such a
-- piece can never fire, so one serves them all and a read allocates none
local STILL = mods.piece(nil)

-- the lane map wrapped around each old queue, one per queue table
local LEGACY_LANES: { [any]: { [string]: { any } } } = setmetatable({}, { __mode = "k" }) :: any

-- the builds every instance storing the same content shares: the lanes a row
-- was found under are one table per distinct content, and a row of another
-- instance found under that same table, resting at the same value over the
-- same span, is handed the lanes the first build kept, the way a piece of the
-- same emit already is. a build that draws per piece hands nothing on and is
-- never kept here
type Kept = {
  source: string,
  built: string,
  span: number,
  rest: any,
  framed: boolean,
  share: (other: mods.Piece) -> mods.Track?,
}

local BUILDS: { [any]: { Kept } } = setmetatable({}, { __mode = "k" }) :: any

local function keptOf(lanes: any, source: string, built: string, span: number, rest: any, framed: boolean): Kept?
  local held = BUILDS[lanes]

  if held == nil then
    return nil
  end

  for _, kept in held do
    if
      kept.source == source
      and kept.built == built
      and kept.span == span
      and kept.rest == rest
      and kept.framed == framed
    then
      return kept
    end
  end

  return nil
end

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

  -- the old format had one trigger, which is the lane every queue was. the
  -- queue is one table per distinct content, and so is the map around it, so
  -- a build kept under the map is kept under the content
  local wrapped = LEGACY_LANES[queue]

  if wrapped == nil then
    wrapped = table.freeze({ start = queue })
    LEGACY_LANES[queue] = wrapped
  end

  return wrapped, false, under
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

    found = { lanes = lanes, framed = framed, under = under, live = nil, share = nil, shareSpan = nil, rest = nil }
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
-- which is what a module emitting a single piece per emit wants, and the one
-- still piece for a module that declares no event. built on the first mod row
-- that asks for one, so a module with none allocates nothing
local function pieceOf(state: State): mods.Piece
  local piece = state.piece

  if piece == nil then
    local events = state.module.events

    piece = if events == nil then STILL else mods.piece(events)
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

-- the lanes of a stored map that move something, dropping every lane that is
-- empty or holds only values the target already carries. the map itself when
-- nothing drops, so a range row whose lanes all move allocates nothing
local function moving(lanes: { [string]: { any } }): { [string]: { any } }
  local drops = false

  for _, queue in lanes do
    if #queue == 0 or mods.inert(queue) then
      drops = true
      break
    end
  end

  if not drops then
    return lanes
  end

  local out = {}

  for lane, queue in lanes do
    if #queue > 0 and not mods.inert(queue) then
      out[lane] = queue
    end
  end

  return out
end

local wrap

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

  local default: any = rest
  local declared: { [string]: { any } }? = nil
  local lanes = found.lanes

  -- a range is the row's state and a draw from it is what a piece takes: this
  -- is not a default, it is what a range row's own value always means, so a
  -- stored lane that moves nothing cannot silence it. every other row hands
  -- its default modifier over whole, and a stored map owns the lanes it names
  -- and nothing else
  if typeof(rest) == "NumberRange" then
    default = mods.draw(rest.Min, rest.Max)

    -- filtered once per read, so a piece calling the row again is handed the
    -- lanes the read already kept
    if lanes ~= nil then
      local live = found.live

      if live == nil then
        live = moving(lanes)
        found.live = live
      end

      lanes = live
    end
  elseif row.modDefault ~= nil then
    declared = mod.lanes(row.modDefault, ctx, state.attrs, state.props, rest, row.preset)
    default = declared or rest
  end

  local own = if piece ~= nil then piece else pieceOf(state)
  -- a default made of lanes may name no start at all, and the row still rests
  -- somewhere, so the build is told where rather than left to read it off a
  -- lead that is not there. a drawn range names both its corners and every
  -- other row takes the shared option table
  local opts: { ownStart: boolean?, value: any? }? = if declared ~= nil
    then { ownStart = seeded, value = rest }
    elseif seeded then SEEDED
    else nil
  -- an attribute row builds under the name its queue was found under, since
  -- that is where the value it chains from and the range it draws inside are
  -- stored too; a property row's base is the property, whatever the spelling
  local built = if source == "property" then name else found.under or name

  -- a build from where the row rests, over a default that is the row's own
  -- value, is a function of the stored content alone, so one such build is
  -- shared by every instance storing that content. a declared default reads
  -- other rows, a range draws, and a seeded or provisional build is a piece's
  -- or a rule's own
  local shareable = lanes ~= nil and declared == nil and default == rest and not seeded and not state.deciding

  if shareable then
    local kept = keptOf(lanes, source, built, span, rest, found.framed)

    if kept ~= nil then
      local shared = kept.share(own)

      if shared ~= nil then
        found.share = kept.share
        found.shareSpan = span
        found.rest = rest

        return wrap(state, source, name, row, rest, shared)
      end
    end
  end

  local inner, share = mods.build(ctx.ref, source, built, default, span, nil, lanes, found.framed, opts, own)

  -- only a build from where the row rests, with the duration decided, is the
  -- one every piece calling the row with nothing of its own would make again
  if not seeded and not state.deciding then
    found.share = share
    found.shareSpan = span
    found.rest = rest
  end

  if shareable and share ~= nil then
    local held = BUILDS[lanes]

    if held == nil then
      held = {}
      BUILDS[lanes] = held
    end

    table.insert(
      held,
      { source = source, built = built, span = span, rest = rest, framed = found.framed, share = share }
    )
  end

  return wrap(state, source, name, row, rest, inner)
end

local function apply(track: any, write: (v: any) -> (), done: (() -> ())?)
  local ctx = track.state.ctx

  if reader.bind == nil or ctx.scope == nil then
    logger.error(`{track.name} cannot be applied without a running effect`)
  end

  local bind = reader.bind :: any

  bind(ctx.scope, track, write, nil, done)
end

-- a piece calls the row for a track of its own: rules run again, a value
-- handed in is where this piece's state is, a span handed in is the clock this
-- piece runs over when it drew one, and a piece handed in is the clock its own
-- event lanes fire on. one metatable serves every track, reading what the
-- track was built from off the track itself, so a read allocates no closure
-- per row for a call most rows never get
local TRACK_META = {
  __call = function(track: any, current: any, span: number?, own: mods.Piece?)
    local state: State = track.state
    local source: string = track.source
    local name: string = track.name
    local row: knob.Knob = track.row
    local over = span or durationOf(state)

    if current == nil then
      local found = queueFor(state, source, name, row)
      local share = found.share

      if share ~= nil and found.shareSpan == over then
        local shared = share(if own ~= nil then own else pieceOf(state))

        if shared ~= nil then
          return wrap(state, source, name, row, found.rest, shared)
        end
      end
    end

    local held = if current ~= nil then current else plainOf(state, source, name, row)

    return trackOf(state, source, name, row, held, current ~= nil, over, own)
  end,
}

wrap = function(state: State, source: string, name: string, row: knob.Knob, rest: any, inner: mods.Track): Track
  local track = {
    at = inner.at,
    duration = inner.span,
    animated = inner.animated,
    value = rest,
    has = inner.has,
    reach = inner.reach,
    still = inner.still,
    apply = apply,
    state = state,
    source = source,
    name = name,
    row = row,
  }

  return table.freeze(setmetatable(track, TRACK_META)) :: any
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

-- the third return is every attribute the walk read the instance under, for
-- a caller that goes on to walk the same keys and would otherwise read them again
function reader.resolve(module: Module, ctx: Ctx): (any, any, { [string]: any })
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

  return table.freeze(attrs), table.freeze(props), state.map
end

return reader
