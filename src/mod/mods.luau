local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local lerp = require("@mod/lerp")
local codec = require("@mod/modifier_codec")
local curve = require("@mod/curve")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local modifiers = require("@mod/modifiers")
local legacy_mods = require("@mod/legacy_mods")

local mods = {}

-- split by target source so the runtime knows whether to write ref[name] or
-- ref:SetAttribute(name, v), and so an instance carrying both a property and
-- an attribute of one name never confuses the two
mods.PREFIX = {
  property = "ForgePropMods_",
  attribute = "ForgeAttrMods_",
}

-- what a roll draws from: a fresh generator each time, unless a caller that
-- has to see the same draws twice lends one around its reads, as the path
-- preview does for each path
mods.random = nil :: Random?

function mods.attrName(source: string, name: string): string
  return mods.PREFIX[source] .. name
end

-- everything a queue needs that belongs to ONE emitted instance: the draws,
-- made here, and the environment a `var` resolves against, which the caller
-- supplies because it is shared with the other queues on that instance. both
-- travel together because both decide what the span is
export type Rolls = {
  draws: { [number]: modifiers.Draw },
  picks: { [number]: modifiers.Picks },
  env: { [string]: any }?,
  envelope: number,
}

-- the walk behind mods.span, which also hands back the schedule it made: a
-- sampler built over the same rolls right after it places every modifier
-- exactly so, and takes these rather than walk the queue a second time
local function spanned(
  queue: { any },
  fallback: number,
  rolls: Rolls?,
  left: number?
): (number, number, number, { [number]: number }?, number, { [number]: number }?)
  local picks = if rolls then rolls.picks else nil

  -- schedule seeds a linked modifier's run from the fallback, so a nan one
  -- poisons every offset in the queue and the span comes back nan. zero makes
  -- the frontier the far end of the authored durations instead
  if fallback ~= fallback then
    fallback = 0
  end

  local offsets, frontier, resolved, lengths =
    modifiers.schedule(queue, picks, fallback, if rolls then rolls.env else nil, left)

  -- a lane told nothing is left may take no time at all, and that zero is its
  -- reach: falling back would start it at the emit rather than at the end
  if frontier == 0 and left ~= nil and left == left then
    return 0, fallback, 0, offsets, resolved, lengths
  end

  -- an effect turns this straight into a tween's duration, and a tween that
  -- never ends holds the emit open for good. nothing an author can mean by a
  -- span is infinite, so an unusable one falls back the same way an empty one does
  if frontier ~= frontier or frontier <= 0 or frontier == math.huge then
    return fallback, fallback, if frontier == 0 then 0 else fallback, offsets, resolved, lengths
  end

  return frontier, fallback, frontier, offsets, resolved, lengths
end

-- how long a queue runs on its own terms: modifiers run one after another,
-- so the answer is where the last one ends rather than the longest single
-- duration, and a caller whose delay is drawn per instance passes the rolls in
-- so the span is the one THIS instance will run. the second return is the
-- effect duration a modifier naming none runs out, which the sampler lends
-- back to schedule so both walks place every modifier alike. `left` is the
-- time the effect has left where the queue starts, for a lane that starts late.
-- the third return is how far the queue reaches on its own, zero for one that
-- takes no time where the first falls back to the effect's duration
function mods.span(queue: { any }, fallback: number, rolls: Rolls?, left: number?): (number, number, number)
  local reach, lent, length = spanned(queue, fallback, rolls, left)

  return reach, lent, length
end

-- a queue that moves nothing: one that only waits, or only holds values the
-- target already carries, drives nothing and would hold the emit open for the
-- length of its run while it wrote those values back every frame. the sample
-- guard behind mods.build catches the base-only case only where nothing rests
-- at all, since such a queue hands back whatever the row does rest at
function mods.inert(queue: { any }): boolean
  if #queue == 0 then
    return false
  end

  for _, m in queue do
    if m.kind ~= "delay" and not modifiers.BASE_KINDS[m.kind] then
      return false
    end
  end

  return true
end

-- a framed attribute decoded once per distinct string: every clone of a
-- template carries the same string, and the lanes are read and never written
-- past this point, so one frozen table answers them all and a build keyed on
-- it is a build keyed on the content. cleared whole once it holds more strings
-- than a place authors, rather than weighed entry by entry
local DECODED: { [string]: { [string]: { any } } } = {}
local DECODED_CAP = 2048
local decodedCount = 0

local function deepFreeze(t: { [any]: any })
  for _, v in t do
    if type(v) == "table" and not table.isfrozen(v) then
      deepFreeze(v)
    end
  end

  table.freeze(t)
end

mods.deepFreeze = deepFreeze

-- the framed attribute decoded on its own, with no legacy fallback. an EMPTY
-- queue is a tombstone the authoring side writes deliberately, so a caller
-- asking whether anything is authored here has to tell it apart from an absent
-- attribute, which mods.read cannot once it has fallen through
function mods.framed(ref: Instance, source: string, name: string, map: { [string]: any }?): { [string]: { any } }?
  local key = mods.attrName(source, name)
  local raw = if map ~= nil then map[key] else attr.get(ref, key, nil, true)

  if not frame.isFramed(raw) then
    return nil
  end

  local known = DECODED[raw :: string]

  if known ~= nil then
    return if legacy_mods.isHeldStillLane(ref, name, known) then nil else known
  end

  local body = frame.unframe(raw)

  if body == nil then
    logger.warn(`{name} carries a framed modifier queue that could not be read`)
    return nil
  end

  local ok, decoded = pcall(codec.decode, body)

  if ok and decoded then
    -- a tween an earlier plugin converted with its start lost plays from its
    -- target's own value, as the child it came from did
    local lanes = legacy_mods.repaired(decoded.lanes)

    deepFreeze(lanes)

    if decodedCount >= DECODED_CAP then
      table.clear(DECODED)
      decodedCount = 0
    end

    DECODED[raw :: string] = lanes
    decodedCount += 1

    return if legacy_mods.isHeldStillLane(ref, name, lanes) then nil else lanes
  end

  logger.warn(`failed to decode the modifier queue on {name}`)

  return nil
end

-- the second return says whether the lanes came out of the framed attribute, so
-- a caller that has to tell an authored row from an old one does not pay the
-- decode a second time to ask
function mods.read(
  ref: Instance,
  source: string,
  name: string,
  map: { [string]: any }?
): ({ [string]: { any } }?, boolean)
  local lanes = mods.framed(ref, source, name, map)

  if lanes ~= nil then
    return lanes, true
  end

  local queue = legacy_mods.read(ref, source, name, map)

  if queue == nil then
    return nil, false
  end

  -- the old format had one trigger, which is the lane every queue was
  return { start = queue }, false
end

-- the value a target already carries, which is what a base entry resolves to
local function baseOf(ref: Instance, source: string, name: string): any
  if source ~= "property" then
    return attr.get(ref, name, nil, true)
  end

  local ok, current = pcall(function()
    return (ref :: any)[name]
  end)

  return if ok then current else nil
end

-- whether a randomizer draws each axis on its own rather than one alpha for the
-- whole vector. only the shape that ASKS for it does, which is a legacy Min/Max
-- pair: a pair names a box, and a size drawn inside it keeps its own
-- proportions, where one alpha would only ever scale a copy of the same shape.
-- two endpoints name a segment instead, so a RayValue randomizer child and an
-- authored one keep drawing along it, exactly as the legacy randomizer always
-- did for the same data.
--
-- both ends have to resolve to vectors, because evaluate's per-component branch
-- needs two to interpolate between. resolved rather than read raw, so a var
-- endpoint is judged on what it holds for this instance
local function componentEnds(m: any, env: { [string]: any }?): boolean
  if not m.perComponent then
    return false
  end

  local startVal = if m.start then value.resolve(m.start, nil, env) else nil
  local finishVal = if m.finish then value.resolve(m.finish, nil, env) else nil

  return typeof(startVal) == "Vector3" and typeof(finishVal) == "Vector3"
end

-- randomizer alphas, drawn endpoints, drawn waits and the envelope offset are
-- all drawn HERE, once, which is once per emitted instance. that makes "one
-- draw per instance" structural rather than a rule every call site has to
-- remember. it is its own function because a drawn delay moves the far end of
-- the queue, so a caller that needs the SPAN first has to draw before it can
-- ask for one, and then hand the same rolls to the sampler
function mods.roll(queue: { any }, env: { [string]: any }?): Rolls
  local rng = mods.random or Random.new()
  local draws = {}
  local picks = {}

  for i, m in queue do
    if m.kind == "randomizer" then
      local first = rng:NextNumber()

      -- the first draw stays the first call either way, so a queue that does
      -- not draw per component keeps the draw order it always had
      if componentEnds(m, env) then
        draws[i] = { first, rng:NextNumber(), rng:NextNumber() }
      else
        draws[i] = first
      end
    end

    local startDrawn = m.start ~= nil and value.isDraw(m.start)
    local finishDrawn = m.finish ~= nil and value.isDraw(m.finish)
    local waitDrawn = type(m.wait) == "table" and value.isDraw(m.wait)
    local rateDrawn = modifiers.drawsRate(m)

    if startDrawn or finishDrawn or waitDrawn or rateDrawn then
      picks[i] = {
        start = if startDrawn then rng:NextNumber() else nil,
        finish = if finishDrawn then rng:NextNumber() else nil,
        wait = if waitDrawn then rng:NextNumber() else nil,
        fps = if rateDrawn then rng:NextNumber() else nil,
      }
    end
  end

  return { draws = draws, picks = picks, env = env, envelope = rng:NextNumber() * 2 - 1 }
end

-- a sampler over a queue already scheduled from `rolled`, `lent` and `left`
local function samplerOf(
  ref: Instance,
  source: string,
  name: string,
  duration: number,
  queue: { any },
  rolled: Rolls,
  lent: number,
  left: number?,
  offsets: { [number]: number }?,
  resolved: number,
  lengths: { [number]: number }?
): (((elapsed: number, own: any?, left: number?) -> any)?, number)
  if #queue == 0 then
    return nil, 0
  end

  local base = baseOf(ref, source, name)
  local lead = 0

  -- a parallel legacy entry keeps its own wait, so the offsets need not rise
  -- through the queue and the lead is the smallest of them
  if offsets ~= nil then
    lead = math.huge

    for _, at in offsets do
      lead = math.min(lead, at)
    end
  end

  -- a randomizer draws where it starts and always takes none, so a queue whose
  -- only no-duration entries are randomizers never has a length that moves
  -- with `left`. computed once here rather than read off `lengths`, which a
  -- randomizer-only queue still populates with its own zeros
  local openEnded = false

  for _, m in queue do
    if modifiers.BASE_KINDS[m.kind] or m.kind == "delay" then
      continue
    end

    if m.kind ~= "randomizer" and typeof(m.duration) ~= "number" then
      openEnded = true
      break
    end
  end

  local ctx: modifiers.Ctx = {
    duration = duration,
    draws = rolled.draws,
    picks = rolled.picks,
    offsets = offsets,
    lengths = lengths,
    linked = resolved,
    env = rolled.env,
    envelope = rolled.envelope,
  }

  local steps = modifiers.compile(queue, ctx)
  local scheduledFor = left

  -- a lane fired over a running row begins from the value under it rather than
  -- from what the instance itself carries, so the base is the caller's per call.
  -- a lane that fires late tells the sampler the time the effect has left, and
  -- only a queue with some other kind naming no duration has anything to redo then
  local function sample(elapsed: number, own: any?, left: number?)
    if openEnded and left ~= nil and left == left and left ~= scheduledFor then
      local placed, _, _, runs = modifiers.schedule(queue, rolled.picks, lent, rolled.env, left)

      scheduledFor = left
      ctx.offsets = placed
      ctx.lengths = runs
      modifiers.place(steps, ctx, placed, runs)
    end

    return modifiers.sample(steps, ctx, elapsed, if own ~= nil then own else base)
  end

  return sample, lead
end

-- a caller that already read the queue, to span it or to test it, passes it
-- back in rather than paying a second base64 plus buffer decode for the same
-- attribute, and passes its rolls back in so the span it computed and the
-- sampler it gets are drawn from the same hat. the second return is where the
-- queue's first modifier on the clock starts, which is how long it waits first
function mods.sampler(
  ref: Instance,
  source: string,
  name: string,
  duration: number,
  queue: { any },
  rolls: Rolls?,
  linked: number?,
  left: number?
): (((elapsed: number, own: any?, left: number?) -> any)?, number)
  if #queue == 0 then
    return nil, 0
  end

  local rolled = rolls or mods.roll(queue)
  -- `duration` is the reach, which can run past the effect when the named
  -- durations add up to more than it. a modifier naming none runs out what is
  -- left of the effect, so a caller that knows the effect duration it lent says so
  local lent = if linked ~= nil then linked else duration
  local offsets, _, resolved, lengths = modifiers.schedule(queue, rolled.picks, lent, rolled.env, left)

  return samplerOf(ref, source, name, duration, queue, rolled, lent, left, offsets, resolved, lengths)
end

export type Track = {
  at: (elapsed: number, own: any?, since: number?) -> any,
  span: number,
  animated: boolean,
  has: (lane: string) -> boolean,
  reach: (lane: string) -> number,
  -- whether the lane, fired at `at`, leaves the row where it stood then the
  -- whole way and no lane starting after it takes the row, which a driver can
  -- skip sampling. false whenever that cannot be told from the lanes, and true
  -- for a lane the row does not hold
  still: (lane: string, at: number) -> boolean,
}

local Piece = {}
Piece.__index = Piece

-- the clock a lane fires on belongs to the emitted piece rather than to the
-- read: one ctx serves every piece of an emit and each piece has tracks of its
-- own. a module declares the names it may fire and the piece refuses any other,
-- since a name nothing declares can only be a module bug
export type Piece = typeof(setmetatable(
  {} :: { fired: { [string]: number }, runs: { [string]: number }?, events: { string }? },
  Piece
))

type Lane = {
  name: string,
  order: number,
  from: number?,
  reach: number,
  -- how long the lane's own entries run from its trigger: its reach, except
  -- that a lane taking no time reaches nothing rather than the row's span
  length: number,
  lead: number,
  -- an event lane's sampler is built the first time a piece has fired it, by
  -- `build`, which leaves `silent` set instead when the lane says nothing. a
  -- stored lane that turns out silent hands the row to `fallback`, the
  -- default lane of its name, as one found silent at the read always did
  sample: ((elapsed: number, own: any?, left: number?) -> any)?,
  build: (() -> ())?,
  silent: boolean,
  fallback: Lane?,
  -- the one value an event lane made only of chained tweens to it ends every
  -- entry at, and nil for any other lane
  rests: any,
  -- the entries the lane was built from, and whether they hold the row at one
  -- value (`level`) from its trigger, judged over `under`: a lane leading with
  -- a chain holds whatever it is fired over, so a track judges it again over
  -- what its own lanes hold
  queue: { any }?,
  flat: boolean,
  level: any,
  leads: boolean,
}

-- the lane that answers for `lane` once it has fired: itself, built on the
-- first call that needs it, or its fallback when it says nothing
local function live(lane: Lane): Lane?
  local build = lane.build

  if build ~= nil then
    lane.build = nil
    build()
  end

  if not lane.silent then
    return lane
  end

  local fallback = lane.fallback

  return if fallback ~= nil then live(fallback) else nil
end

-- `runFor` is how long the phase the lane opens runs, when the firer knows:
-- an entry on the lane naming no duration runs that out rather than what the
-- effect has left, and a fire naming none leaves the lane to the effect
function Piece.fire(self: Piece, name: string, elapsed: number, runFor: number?)
  local events = self.events

  if events == nil or table.find(events, name) == nil then
    logger.error(`no lane named {name} is declared here`)
  end

  -- firing again restarts the lane, and a clock nobody can read starts it where
  -- the piece already is rather than nowhere at all
  self.fired[name] = if typeof(elapsed) == "number" and elapsed == elapsed then math.max(elapsed, 0) else 0

  local told = if typeof(runFor) == "number"
      and runFor == runFor
      and runFor >= 0
      and runFor ~= math.huge
    then runFor
    else nil
  local runs = self.runs

  -- kept only once some fire names one, so a piece nobody tells anything
  -- carries no table for it
  if runs == nil and told ~= nil then
    runs = {}
    self.runs = runs
  end

  if runs ~= nil then
    runs[name] = told
  end
end

function mods.piece(events: { string }?): Piece
  return setmetatable({ fired = {}, runs = nil, events = events }, Piece)
end

-- where a lane sits when two of them fired in the same frame: the built ins
-- first, then the piece's events in the order the module declared them, and the
-- later one owns the row. a name the piece does not declare can never have
-- fired, so it is not a lane at all
local function orderOf(piece: Piece?, lane: string): number?
  if lane == "start" then
    return 1
  end

  if lane == "end" then
    return 2
  end

  local events = if piece then piece.events else nil
  local at = if events then table.find(events, lane) else nil

  return if at then 2 + at else nil
end

local function byOrder(a: Lane, b: Lane): boolean
  return a.order < b.order
end

-- when a lane's clock started, on the piece's own clock: the emit for start, the
-- moment the row's span leaves room for its reach for end, and the elapsed a
-- module fired an event at, which is nothing until it does
local function firedAt(lane: Lane, piece: Piece?): number?
  if lane.from ~= nil then
    return lane.from
  end

  return if piece then piece.fired[lane.name] else nil
end

-- which lane owns the row at `elapsed`: the one that started last at or before
-- it, and the later of two that started together. `under` is the lane a base
-- is being folded for: neither it nor a lane that started after it, or with it
-- and later in the same frame, is under it, so the fold always descends.
-- `since` is where a caller froze the row, and only a lane that had already
-- started is inside the value it froze: one starting exactly there is part of
-- what the caller was born into, so it still composes
local function ownerAt(lanes: { Lane }, piece: Piece?, elapsed: number, since: number?, under: number?): number?
  local floor = if under ~= nil then firedAt(lanes[under], piece) else nil
  local best: number? = nil
  local at = -1

  for i, lane in lanes do
    local from = firedAt(lane, piece)

    if from == nil or from > elapsed then
      continue
    end

    if floor ~= nil and (from > floor or (from == floor and i >= (under :: number))) then
      continue
    end

    if since ~= nil and from < since then
      continue
    end

    if from >= at and live(lane) ~= nil then
      at = from
      best = i
    end
  end

  return best
end

-- the owning lane's queue at `elapsed`, run from its trigger over `base`. an
-- event lane runs out the phase its firer said it opens, else what the effect
-- has left from where it fired; the start and end lanes were told theirs when
-- they were built
local function played(lane: Lane, piece: Piece?, span: number, elapsed: number, from: number, base: any): any
  local left: number? = nil

  if lane.from == nil then
    local runs = (piece :: Piece).runs
    local told = if runs ~= nil then runs[lane.name] else nil

    left = if told ~= nil then told else span - from
  end

  local v = (lane.sample :: any)(elapsed - from, base, left)

  return if v ~= nil then v else base
end

-- the row's value at `elapsed`: the owning lane's queue run from its own
-- trigger, over what the lanes under it hold. that base is read where the
-- lane's first modifier starts, and live until then: a chained first entry
-- follows the lanes under it through the wait, and a non-chained one holds its
-- own start from the moment the lane begins instead. a lane producing nothing
-- passes the base through, and a row nobody owns rests where the caller says
-- it rests
local function valueAt(
  lanes: { Lane },
  piece: Piece?,
  span: number,
  elapsed: number,
  own: any,
  since: number?,
  under: number?
): any
  local i = ownerAt(lanes, piece, elapsed, since, under)

  if i == nil then
    return own
  end

  local lane = live(lanes[i]) :: Lane
  local from = firedAt(lane, piece) :: number
  local base = valueAt(lanes, piece, span, math.min(elapsed, from + lane.lead), own, since, i)

  return played(lane, piece, span, elapsed, from, base)
end

-- the one value a queue of chained tweens leaves the row at when every entry
-- names it outright: fired over that value, no entry moves the row at all.
-- nil for a queue that waits, draws, starts anywhere of its own or goes
-- somewhere else on the way
local function restsOf(queue: { any }): any
  local rests: any = nil

  for _, m in queue do
    if m.kind ~= "tween" or not m.chain or m.finish == nil or not value.isLit(m.finish) then
      return nil
    end

    local v = value.resolve(m.finish)

    if rests ~= nil and v ~= rests then
      return nil
    end

    rests = v
  end

  return rests
end

-- the one value a lane's entries hold the row at from its trigger, when they
-- hold it anywhere at all: every entry ends where it starts, a chained one
-- starting from what the entry before it left, or from `under` when it leads.
-- a drawn endpoint counts when its corners agree, since the draw can land
-- nowhere else. false when any entry moves the row or draws. the third return
-- says the lane leads with a chain, so what it holds depends on `under`
local function flatOf(queue: { any }, under: any): (boolean, any, boolean)
  local running: any = nil
  local any = false
  local leads = false

  for _, m in queue do
    local kind = m.kind

    if modifiers.BASE_KINDS[kind] or kind == "delay" then
      continue
    end

    if kind ~= "tween" and kind ~= "randomizer" then
      return false, nil, false
    end

    local startV: any

    if m.chain then
      if running == nil then
        leads = true
      end

      startV = if running ~= nil then running else under
    else
      startV = value.fixed(m.start)
    end

    local finishV = if m.finish ~= nil then value.fixed(m.finish) else startV

    if startV == nil or finishV == nil or startV ~= finishV then
      return false, nil, false
    end

    if running ~= nil and startV ~= running then
      return false, nil, false
    end

    running = finishV
    any = true
  end

  return any, running, leads
end

-- whether a set of lanes leaves the row at one value for good: the start lane,
-- first in the set, holds the row somewhere from the emit, and every lane after
-- it holds that same value, so firing one changes nothing. a lane with a
-- fallback may hand the row to its default, which is not told from here
local function pinned(set: { Lane }, rest: any): boolean
  local held = rest

  for _, lane in set do
    local queue = lane.queue

    if queue == nil or lane.fallback ~= nil then
      return false
    end

    local flat, level = lane.flat, lane.level

    if lane.leads then
      flat, level = flatOf(queue, held)
    end

    if not flat then
      return false
    end

    if lane.name == "start" then
      held = level
    elseif level ~= held then
      return false
    end
  end

  return true
end

local function trackFrom(set: { Lane }, piece: Piece?, span: number, rest: any): Track
  local reach = span
  local ends = false

  for _, lane in set do
    if lane.name == "start" then
      reach = lane.reach
    elseif lane.name == "end" then
      ends = true
    end
  end

  -- an end lane triggers where the row's own span leaves room for its reach, so
  -- a driver stepping only the start lane's reach would stop short of it
  if ends then
    reach = math.max(reach, span)
  end

  local at: (elapsed: number, own: any?, since: number?) -> any

  -- a row of one lane is that lane's from the moment it fires, over where the
  -- row rests, since no other lane can own it or lie under it: the same answer
  -- as the fold without the walk or the fold. a trigger is never nan nor below
  -- zero, so the walk's own test against -1 always holds
  if #set == 1 then
    local only = set[1]

    at = function(elapsed: number, own: any?, since: number?)
      local held = if own ~= nil then own else rest
      local from = firedAt(only, piece)

      if from == nil or from > elapsed or (since ~= nil and from < since) then
        return held
      end

      local lane = live(only)

      if lane == nil then
        return held
      end

      return played(lane, piece, span, elapsed, firedAt(lane, piece) :: number, held)
    end
  else
    at = function(elapsed: number, own: any?, since: number?)
      return valueAt(set, piece, span, elapsed, if own ~= nil then own else rest, since, nil)
    end
  end

  return {
    at = at,
    span = reach,
    animated = not pinned(set, rest),
    has = function(lane: string)
      for _, held in set do
        if held.name == lane then
          return true
        end
      end

      return false
    end,
    reach = function(lane: string): number
      for _, held in set do
        if held.name == lane then
          return held.length
        end
      end

      return 0
    end,
    still = function(lane: string, at: number): boolean
      for i, held in set do
        if held.name ~= lane then
          continue
        end

        local rests = held.rests
        local fallback = held.fallback

        if rests == nil or (fallback ~= nil and fallback.rests ~= rests) then
          return false
        end

        -- the row belongs to the lane that started last, so one that has not
        -- started yet, or starts later in the same frame, can still take it
        for j, other in set do
          if j == i then
            continue
          end

          local from = firedAt(other, piece)

          if from == nil or from > at or (from == at and j > i) then
            return false
          end
        end

        -- where the lanes under this one hold the row when it fires, which is
        -- what its first entry chains from
        return valueAt(set, piece, span, at, rest, nil, i) == rests
      end

      return true
    end,
  }
end

-- one warning per knob per instance: a mismatch repeats on every emit of the
-- same template, and the first one already says everything
local WARNED: { [Instance]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

function mods.warnOnce(ref: Instance, name: string, message: string)
  local seen = WARNED[ref]

  if seen == nil then
    seen = {}
    WARNED[ref] = seen
  end

  if seen[name] then
    return
  end

  seen[name] = true
  logger.warn(message)
end

-- the default for a knob that rests on a ramp rather than a value: what the
-- effect used to tween between when nothing was authored. a value when both
-- ends agree, so a knob at rest costs no stepper
function mods.ramp(startV: any, finishV: any): any
  if startV == finishV then
    return startV
  end

  return {
    start = {
      {
        kind = "tween",
        chain = false,
        start = value.lit(startV),
        finish = value.lit(finishV),
        curve = curves.default(),
      },
    },
  }
end

-- the default for a knob drawn once per emitted instance between two corners,
-- which is what a Min and Max pair or a NumberRange attribute always meant. a
-- vector pair draws each axis on its own
function mods.draw(minV: any, maxV: any): { [string]: { any } }
  return {
    start = {
      {
        kind = "randomizer",
        chain = false,
        start = value.lit(minV),
        finish = value.lit(maxV),
        perComponent = true,
      },
    },
  }
end

local function noLane(): boolean
  return false
end

local function noReach(): number
  return 0
end

local function noMove(): boolean
  return true
end

local function constant(default: any, span: number): Track
  return {
    at = function(_, own: any?)
      return if own ~= nil then own else default
    end,
    span = span,
    animated = false,
    has = noLane,
    reach = noReach,
    still = noMove,
  }
end

-- the value a knob wants, which is the knob's own answer, re-exported here for
-- the callers that already hold mods
mods.kindOf = knob.kindOf

-- whether a lane's entries come out differently for each piece that builds
-- them: a draw is rolled per build, an envelope deviates by a roll, and an
-- event lane whose entry names no duration is scheduled again from whatever
-- the fire says is left
local function perPiece(queue: { any }, event: boolean): boolean
  for _, m in queue do
    if m.kind == "randomizer" or m.envelope ~= nil then
      return true
    end

    if (m.start ~= nil and value.isDraw(m.start)) or (m.finish ~= nil and value.isDraw(m.finish)) then
      return true
    end

    if type(m.wait) == "table" and value.isDraw(m.wait) then
      return true
    end

    if modifiers.drawsRate(m) then
      return true
    end

    if event and m.kind ~= "delay" and not modifiers.BASE_KINDS[m.kind] and typeof(m.duration) ~= "number" then
      return true
    end
  end

  return false
end

-- the rolls of a queue that draws nothing, which is what mods.roll would hand
-- it without the generator: no draw, no pick, and an envelope nothing reads
local function unrolled(env: { [string]: any }?): Rolls
  return { draws = {}, picks = {}, env = env, envelope = 0 }
end

-- one lane as a sampler on its own clock, drawn once for this instance. the
-- probe is where the row rests, which is what a lane whose first entry chains
-- begins from when nothing under it has run yet
local function laneOf(
  ref: Instance,
  source: string,
  name: string,
  queue: { any },
  span: number,
  env: { [string]: any }?,
  probe: any,
  lane: string
): (((elapsed: number, own: any?, left: number?) -> any)?, number, number, number)
  -- the end lane plays out as the effect ends, so a modifier on it naming no
  -- duration has nothing left to run for and snaps to its finish
  local left = if lane == "end" then 0 else nil
  local rolls = if perPiece(queue, false) then mods.roll(queue, env) else unrolled(env)
  local reach, linked, length, offsets, resolved, lengths = spanned(queue, span, rolls, left)
  local sample, lead = samplerOf(ref, source, name, reach, queue, rolls, linked, left, offsets, resolved, lengths)

  if sample == nil then
    return nil, span, 0, 0
  end

  if sample(0) == nil and (probe == nil or sample(0, probe) == nil) then
    return nil, span, 0, 0
  end

  return sample, reach, lead, length
end

-- the entry of a default lane whose ends complete a half quad: the first tween,
-- since a default may lead with something else
local function leadTween(queue: { any }?): any
  if queue == nil then
    return nil
  end

  for _, m in queue do
    if m.kind == "tween" then
      return m
    end
  end

  return queue[1]
end

-- whether a lane opens on a tween that neither chains nor names a start, which
-- samples nothing and so can never run
local function blankLead(queue: { any }): boolean
  for _, m in queue do
    if m.kind == "delay" or modifiers.BASE_KINDS[m.kind] then
      continue
    end

    return m.kind == "tween" and not m.chain and m.start == nil
  end

  return false
end

-- a lane's entries with the two old-format rewrites applied: an effect-owned
-- start becomes a half quad, and a half quad is completed from the default. nil
-- when the lane cannot be completed at all, which is a lane that says nothing
local function completed(
  queue: { any },
  framed: boolean,
  seeded: boolean,
  lead: any,
  fillStart: value.Value?,
  fillFinish: value.Value?,
  rest: any
): { any }?
  -- an old row whose start was only ever a seed for a target carrying nothing
  -- of its own says where the value ENDS, and the effect says where it comes
  -- from. handing that start back makes it a half quad, which the block below
  -- completes from the default. a row that already named no finish gives up
  -- both ends and keeps only its duration and curve, which is what such a row
  -- did when the effect ran the other half itself. only the old format reads
  -- this way: a framed lane was authored to mean exactly what it says, save an
  -- entry the plugin converted out of the old format, which keeps its reading
  -- by naming itself seedable
  if
    seeded
    and #queue == 1
    and queue[1].kind == "tween"
    and (queue[1].partial == nil or queue[1].partial == "finish")
    and (not framed or queue[1].seedable == true)
  then
    local m = table.clone(queue[1])

    m.partial = if queue[1].partial == "finish" then "both" else "start"

    -- the old format's reader chains a tween naming no start, which gives way
    -- to the start the effect fills. a stored chain is the author's choice
    if not framed then
      m.chain = false
    end

    queue = { m }
  elseif not seeded then
    -- an old tween naming no start runs from where the row rests
    queue = legacy_mods.fromRest(queue, rest)
  end

  if #queue == 1 and queue[1].partial then
    -- a curve alone can only ease a ramp. a constant default has no ramp and a
    -- drawn default is not a tween, so the curve is dropped as the old arms
    -- dropped it for those knobs
    if queue[1].partial == "both" and (lead == nil or lead.kind ~= "tween") then
      return nil
    end

    local filled = legacy_mods.complete(queue, fillStart, fillFinish)
    local m = filled[1]

    -- a filled half of another type than the half authored cannot be lerped
    -- to, so the lane says nothing and the default runs
    if
      m.start ~= nil
      and m.finish ~= nil
      and value.isLit(m.start)
      and value.isLit(m.finish)
      and typeof(m.start.v) ~= typeof(m.finish.v)
    then
      return nil
    end

    return filled
  end

  return queue
end

-- an event lane as its reach and length alone, which is all a row answers
-- before the lane fires: its sampler, and the probe that says whether it
-- samples anything at all, wait for the first time a piece has fired it. a
-- lane that draws is rolled now all the same, so the length is the one it will
-- run, and one that draws nothing is spanned exactly as its empty rolls would
-- span it
local function eventLaneOf(
  ref: Instance,
  source: string,
  name: string,
  queue: { any },
  span: number,
  env: { [string]: any }?,
  probe: any,
  lane: string,
  order: number,
  draws: boolean
): Lane
  local rolls: Rolls? = if draws then mods.roll(queue, env) elseif env ~= nil then unrolled(env) else nil
  local reach, linked, length, offsets, resolved, lengths = spanned(queue, span, rolls, nil)

  local out: Lane = {
    name = lane,
    order = order,
    from = nil,
    reach = reach,
    length = length,
    lead = 0,
    sample = nil,
    build = nil,
    silent = false,
    fallback = nil,
    rests = restsOf(queue),
    queue = queue,
    flat = false,
    level = nil,
    leads = false,
  }

  out.flat, out.level, out.leads = flatOf(queue, probe)

  -- a var in the queue reads the environment as it stands when the lane is
  -- built, the first time it fires, which may no longer be what the read placed
  -- it by. a lane with an environment is placed again then, one without as the
  -- read placed it
  out.build = function()
    local sample, lead

    if env ~= nil then
      sample, lead = mods.sampler(ref, source, name, reach, queue, rolls or unrolled(env), linked, nil)
    else
      sample, lead =
        samplerOf(ref, source, name, reach, queue, rolls or unrolled(env), linked, nil, offsets, resolved, lengths)
    end

    if sample == nil or (sample(0) == nil and (probe == nil or sample(0, probe) == nil)) then
      out.silent = true
      return
    end

    out.sample = sample
    out.lead = lead
  end

  return out
end

-- every build but the one the deferral below leaves for later
local function buildNow(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?,
  lanes: { [string]: { any } }?,
  framed: boolean,
  opts: { ownStart: boolean?, value: any?, home: string? }?,
  piece: Piece?
): (Track, ((other: Piece) -> Track?)?)
  -- a table is a map of lanes, unless it is a value curve the row rests at
  local fallback: { [string]: { any } }? = if mods.kindOf(default) == "table" then default else nil
  local rest: any = if fallback then nil else default

  -- the lane an old half quad completes from: the start's, or the event's a
  -- row is played from, which its old shapes are read onto
  const home = if opts ~= nil and opts.home ~= nil then opts.home else "start"
  local lead = if fallback then leadTween(fallback[home]) else nil

  -- a default made of lanes may put nothing on the row's own lane, so there is
  -- no lead to read a resting value off and the caller says where it rests
  local stated: any = if opts ~= nil then opts.value else nil

  local fillStart: value.Value? = nil
  local fillFinish: value.Value? = nil
  local want: string? = nil

  if lead ~= nil then
    -- a lead on an event lane chains and names no start, and the half it
    -- leaves is where the row rests, which is where it chains from too
    fillStart = if lead.start ~= nil then lead.start else legacy_mods.endpoint(source, name, stated)
    fillFinish = lead.finish

    if fillStart and value.isLit(fillStart) then
      want = mods.kindOf(value.resolve(fillStart))
    end
  else
    -- the half an old quad did not name is where the row rests, and a default
    -- made of lanes that leads nowhere leaves the row resting exactly where one
    -- with no default at all does, so both fill that half the same way
    local held: any = if fallback then stated else default

    fillStart = legacy_mods.endpoint(source, name, held)
    fillFinish = fillStart

    if held ~= nil then
      want = mods.kindOf(held)
    end
  end

  -- where a blank start begins, which is where the row rests: the probe a lane
  -- whose first entry chains is judged against, since nothing under such a lane
  -- has run at the moment it is built
  local seed: any = if fillStart ~= nil then value.resolve(fillStart, nil, env) elseif rest ~= nil then rest else stated

  -- what a lane that chains composes over when nothing under it has run: where
  -- the row rests, which the caller states outright when it knows, since a
  -- default made of lanes leads from somewhere the row does not rest at
  local footing: any = if rest ~= nil then rest elseif stated ~= nil then stated else seed

  local seeded = opts ~= nil and opts.ownStart == true

  -- the authored lanes that could not be read at all, which say nothing and so
  -- leave the default lane of the same name running. nil until one of them
  -- fails, so a row with nothing stored never pays for this table
  local unread: { [string]: boolean }? = nil

  -- set once some lane is built from entries that come out differently per
  -- piece, so the lanes this build keeps are never handed to another
  local varies = false

  -- a default lane is taken as it stands: the two old-format rewrites answer for
  -- what an author stored, and a row's own defaults were never read that way
  local function setOf(map: { [string]: { any } }, authored: boolean): { Lane }
    local out: { Lane } = {}

    for lane, queue in map do
      local order = orderOf(piece, lane)

      if order == nil or #queue == 0 or mods.inert(queue) then
        continue
      end

      local entries = if authored then completed(queue, framed, seeded, lead, fillStart, fillFinish, footing) else queue
      local event = lane ~= "start" and lane ~= "end"

      -- a lane the format could complete and that does not open on a blank
      -- tween is kept as it stands until it fires
      if event and entries ~= nil and not (authored and blankLead(entries)) then
        local draws = perPiece(entries, false)

        if not varies then
          varies = draws or perPiece(entries, true)
        end

        table.insert(out, eventLaneOf(ref, source, name, entries, span, env, seed, lane, order, draws))
        continue
      end

      local sample: ((elapsed: number, own: any?, left: number?) -> any)? = nil
      local reach, first, length = span, 0, 0
      local flat, level, leads = false, nil, false

      if entries ~= nil then
        flat, level, leads = flatOf(entries, footing)
      end

      -- a lane that holds the row at one literal value needs no sampler walked
      -- for it, only its reach, which a phase length may still read. one that
      -- leads with a chain holds whatever it is fired over, so it keeps its
      -- sampler and the track decides what it comes to
      if flat and not leads then
        reach, _, length = spanned(entries :: { any }, span, unrolled(env), if lane == "end" then 0 else nil)
        sample = function()
          return level
        end
      elseif entries ~= nil then
        sample, reach, first, length = laneOf(ref, source, name, entries, span, env, seed, lane)
      end

      if sample ~= nil and not flat and not varies then
        varies = perPiece(entries :: { any }, event)
      end

      -- an authored lane that says nothing leaves the default of its name
      -- running. only one opening on a tween with no start and no chain is
      -- worth a word: an old lane the format could not complete is dropped on
      -- purpose
      if sample == nil then
        if authored then
          if entries ~= nil and blankLead(entries) then
            mods.warnOnce(
              ref,
              `{name}.{lane}`,
              `{name} has a {lane} modifier with no start that does not chain, and it was skipped`
            )
          end

          unread = unread or {}
          unread[lane] = true
        end

        continue
      end

      table.insert(out, {
        name = lane,
        order = order,
        -- the end lane fires once the piece's own clock has only its reach
        -- left, and an event lane has no trigger until the module gives it one
        from = if lane == "start" then 0 elseif lane == "end" then math.max(0, span - reach) else nil,
        reach = reach,
        length = length,
        lead = first,
        sample = sample,
        build = nil,
        silent = false,
        fallback = nil,
        rests = nil,
        queue = entries,
        flat = flat,
        level = level,
        leads = leads,
      })
    end

    table.sort(out, byOrder)

    return out
  end

  local events = if piece then piece.events else nil

  -- a track that runs nothing is the same for every piece, and lanes that come
  -- out alike for every piece are handed on to one of the same events
  local function shared(set: { Lane }?, resting: any): (Track, ((other: Piece) -> Track?)?)
    if set == nil then
      local track = constant(resting, span)

      return track, function()
        return track
      end
    end

    local track = trackFrom(set, piece, span, footing)

    if varies then
      return track, nil
    end

    -- a track fires its lanes on its piece's clock and holds nothing else of
    -- its own, so a caller on the very piece this one was built for, which is
    -- every read of a module that fires no event, is handed this track
    return track,
      function(other: Piece)
        if other == piece then
          return track
        end

        if other.events ~= events then
          return nil
        end

        return trackFrom(set, other, span, footing)
      end
  end

  -- nothing that runs rests where a map silencing every default lane rests
  local function resting(): (Track, ((other: Piece) -> Track?)?)
    if fallback == nil then
      return shared(nil, rest)
    end

    local set = setOf(fallback, false)

    if #set == 0 then
      return shared(nil, footing)
    end

    return shared(set, nil)
  end

  -- a map naming no lane is the payload a row whose modifiers were cleared
  -- carries, and it leaves the row exactly as if nothing were stored
  if lanes == nil or next(lanes) == nil then
    return resting()
  end

  local set = setOf(lanes, true)

  -- the kind is judged on the first stored lane that samples anything, so an
  -- event lane ahead of every other is built for it now, and one found silent
  -- on the way leaves its default running as it would have at the read
  local first: Lane? = nil

  if want ~= nil then
    local kept: { Lane } = {}

    for _, held in set do
      if first == nil then
        local build = held.build

        if build ~= nil then
          held.build = nil
          build()
        end

        if held.silent then
          unread = unread or {}
          unread[held.name] = true
          continue
        end

        first = held
      end

      table.insert(kept, held)
    end

    set = kept
  end

  if #set == 0 and fallback == nil then
    return resting()
  end

  -- judged from where the row rests, which is the probe the lanes were kept
  -- under: a lane that begins where the row stands says nothing on its own
  if first ~= nil then
    local got = mods.kindOf((first.sample :: any)(0, seed))

    if got ~= want then
      mods.warnOnce(ref, name, `{name} samples a {got} where the effect wants a {want}`)
      return resting()
    end
  end

  if fallback == nil then
    return shared(set, nil)
  end

  -- a stored map owns the lanes it names and nothing else, framed or read out
  -- of the old format: a default lane it does not name keeps running, and one
  -- it names with nothing that moves stays silent
  local others: { [string]: { any } } = {}

  for lane, queue in fallback do
    if lanes[lane] == nil or (unread ~= nil and unread[lane]) then
      others[lane] = queue
    end
  end

  -- a stored event lane not yet built may still turn out silent, and then the
  -- default of its name runs in its place
  for _, held in set do
    local stand = fallback[held.name]

    if held.from == nil and not held.silent and stand ~= nil and others[held.name] == nil then
      held.fallback = setOf({ [held.name] = stand }, false)[1]
    end
  end

  for _, lane in setOf(others, false) do
    table.insert(set, lane)
  end

  if #set == 0 then
    return shared(nil, footing)
  end

  table.sort(set, byOrder)

  return shared(set, nil)
end

-- the one way a knob becomes a track. it always answers: what rests when nothing
-- usable is authored, else one sampler per lane over that lane's own reach. a
-- default given as a lane map is what runs when nothing is authored, for a knob
-- whose resting state is a ramp or a draw rather than a value.
--
-- `ownStart` is for a knob whose start belongs to the effect rather than to the
-- row, and `value` is where the caller says the row rests, for a default made of
-- lanes that names no start of its own. `piece` is the clock the row's event
-- lanes fire on, and the row carries none without one.
--
-- the second return hands the same lanes to another piece of the same events,
-- so a caller building one track per piece pays for the lanes once. nil when
-- some lane draws or schedules per piece, which only a build of its own gets
-- the row most effects are made of: stored lanes of one start lane holding
-- one tween from a literal to another, eased by a serialized curve or not,
-- over a duration it names or the row's span, with nothing drawn, chained,
-- waited or stepped, over a default that is where the row rests. such a row
-- fires at the emit whatever the piece, so its track holds nothing of a
-- piece's and is built straight, with none of the lane machinery, to answer
-- exactly what the lanes answer for it: held where the caller says below
-- zero or when frozen after its trigger, else the tween at its progress, or
-- the one value a tween between two ends alike holds the row at, which the
-- lanes know as a flat lane and never animate. nil for every other row,
-- which the lanes build
local function simpleOf(default: any, span: number, lanes: { [string]: { any } }?, opts: any?): Track?
  if opts ~= nil or lanes == nil or default == nil or type(default) == "table" then
    return nil
  end

  if span ~= span or span <= 0 or span == math.huge then
    return nil
  end

  local first = next(lanes)

  if first ~= "start" or next(lanes, first) ~= nil then
    return nil
  end

  local queue = lanes.start

  if #queue ~= 1 then
    return nil
  end

  local m = queue[1]

  if
    m.kind ~= "tween"
    or m.chain
    or m.partial ~= nil
    or m.parallel
    or m.fps ~= nil
    or m.envelope ~= nil
    or m.speed ~= nil
    or m.reset ~= nil
  then
    return nil
  end

  local a, b = m.start, m.finish

  if a == nil or b == nil or not value.isLit(a) or not value.isLit(b) then
    return nil
  end

  local from, to = (a :: any).v, (b :: any).v

  -- a kind the row does not rest in is the lanes' to refuse and warn about
  if from == nil or to == nil then
    return nil
  end

  local kind = knob.kindOf(from)

  if kind ~= knob.kindOf(to) or kind ~= knob.kindOf(default) then
    return nil
  end

  local shape = m.curve
  local form = typeof(shape)

  if shape ~= nil and form ~= "string" and form ~= "buffer" then
    return nil
  end

  local d = m.duration

  if d ~= nil and (type(d) ~= "number" or d ~= d or d <= 0 or d == math.huge) then
    return nil
  end

  local length: number = if d ~= nil then d else span
  local sampler = if shape ~= nil then curve.sampler(shape) else nil
  local rest = default
  local flat = from == to
  local at: (elapsed: number, own: any?, since: number?) -> any

  if flat then
    at = function(elapsed: number, own: any?, since: number?)
      if elapsed < 0 or (since ~= nil and since > 0) then
        return if own ~= nil then own else rest
      end

      return from
    end
  else
    at = function(elapsed: number, own: any?, since: number?)
      if elapsed < 0 or (since ~= nil and since > 0) then
        return if own ~= nil then own else rest
      end

      local progress = math.clamp(elapsed / length, 0, 1)

      return lerp.any(from, to, if sampler ~= nil then sampler(progress) else progress)
    end
  end

  return {
    at = at,
    span = length,
    animated = not flat,
    has = function(lane: string)
      return lane == "start"
    end,
    reach = function(lane: string): number
      return if lane == "start" then length else 0
    end,
    still = function(lane: string): boolean
      return lane ~= "start"
    end,
  }
end

function mods.build(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?,
  lanes: { [string]: { any } }?,
  framed: boolean,
  opts: { ownStart: boolean?, value: any?, home: string? }?,
  piece: Piece?
): (Track, ((other: Piece) -> Track?)?)
  local simple = simpleOf(default, span, lanes, opts)

  -- nothing of a piece in it, so every piece is handed the one track
  if simple ~= nil then
    return simple, function()
      return simple
    end
  end

  local stated: any = if opts ~= nil then opts.value else nil

  -- a default made only of event lanes, with nothing stored over it, rests
  -- where the caller says until a piece fires one of them, and says which it
  -- holds without building any: the build waits for the first fire, or for a
  -- caller asking how far a lane reaches
  if
    mods.kindOf(default) ~= "table"
    or stated == nil
    or (lanes ~= nil and next(lanes) ~= nil)
    or default.start ~= nil
    or default["end"] ~= nil
  then
    return buildNow(ref, source, name, default, span, env, lanes, framed, opts, piece)
  end

  local names: { string } = {}
  local varies = false

  for lane, queue in default do
    if orderOf(piece, lane) == nil or #queue == 0 or mods.inert(queue) then
      continue
    end

    table.insert(names, lane)
    varies = varies or perPiece(queue, true)
  end

  if #names == 0 then
    return buildNow(ref, source, name, default, span, env, lanes, framed, opts, piece)
  end

  local function holds(lane: string): boolean
    return table.find(names, lane) ~= nil
  end

  -- the first full build, whose lanes every later piece is handed when they
  -- come out alike for every piece
  local share: ((other: Piece) -> Track?)? = nil
  local built = false

  local function deferred(own: Piece?): Track
    local inner: Track? = nil

    local function real(): Track
      if inner ~= nil then
        return inner
      end

      if built and share ~= nil and own ~= nil then
        inner = share(own)
      end

      if inner == nil then
        local track, again = buildNow(ref, source, name, default, span, env, lanes, framed, opts, own)

        if not built and not varies then
          built = true
          share = again
        end

        inner = track
      end

      return inner :: Track
    end

    return {
      at = function(elapsed: number, current: any?, since: number?)
        if inner == nil then
          local fired = if own ~= nil then own.fired else nil
          local any = false

          for _, lane in names do
            if fired ~= nil and fired[lane] ~= nil then
              any = true
              break
            end
          end

          if not any then
            return if current ~= nil then current else stated
          end
        end

        return real().at(elapsed, current, since)
      end,
      span = span,
      animated = true,
      has = holds,
      reach = function(lane: string): number
        if not holds(lane) then
          return 0
        end

        return real().reach(lane)
      end,
      still = function(lane: string, at: number): boolean
        if not holds(lane) then
          return true
        end

        return real().still(lane, at)
      end,
    }
  end

  local events = if piece then piece.events else nil
  local own = deferred(piece)

  if varies then
    return own, nil
  end

  return own,
    function(other: Piece)
      if other == piece then
        return own
      end

      if other.events ~= events then
        return nil
      end

      return deferred(other)
    end
end

-- the read half: what an effect that still names its own knobs calls
function mods.track(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?,
  opts: { ownStart: boolean?, value: any?, home: string? }?,
  piece: Piece?
): Track
  local lanes, framed = mods.read(ref, source, name)
  return (mods.build(ref, source, name, default, span, env, lanes, framed, opts, piece))
end

local function scaleValue(v: any, factor: number): any
  local t = typeof(v)

  if t == "number" or t == "Vector3" or t == "vector" then
    return v * factor
  end

  if t == "NumberRange" then
    return NumberRange.new(v.Min * factor, v.Max * factor)
  end

  return v
end

local function scaleEndpoint(x: any, factor: number, scaler: ((v: any, factor: number) -> any)?)
  if type(x) ~= "table" then
    return
  end

  const by = scaler or scaleValue

  if x.t == "lit" then
    x.v = by(x.v, factor)
  elseif x.t == "draw" then
    x.a = by(x.a, factor)
    x.b = by(x.b, factor)
  end
end

-- everything in a lane map that is a time: durations, waits and the duration
-- of a carried speed ramp. in place, on a decoded map
function mods.scaleTime(lanes: { [string]: { any } }, factor: number)
  for _, queue in lanes do
    for _, m in queue do
      if typeof(m.duration) == "number" then
        m.duration *= factor
      end

      if type(m.wait) == "table" then
        scaleEndpoint(m.wait, factor)
      elseif typeof(m.wait) == "number" then
        m.wait *= factor
      end

      if type(m.speed) == "table" and typeof(m.speed.duration) == "number" then
        m.speed.duration *= factor
      end
    end
  end
end

-- every numeric endpoint in a lane map, or every endpoint through `scaler`
-- for a row whose values are no number. a var names a value that is not the
-- row's to scale
function mods.scaleValues(lanes: { [string]: { any } }, factor: number, scaler: ((v: any, factor: number) -> any)?)
  for _, queue in lanes do
    for _, m in queue do
      scaleEndpoint(m.start, factor, scaler)
      scaleEndpoint(m.finish, factor, scaler)
    end
  end
end

-- a framed attribute value decoded, edited in place and framed again, so a
-- caller that scales a row never touches the codec. nil when the value is not a
-- framed map it can read, and the caller leaves the attribute alone
function mods.recode(raw: any, edit: (lanes: { [string]: { any } }) -> ()): string?
  if not frame.isFramed(raw) then
    return nil
  end

  local body = frame.unframe(raw)

  if body == nil then
    return nil
  end

  local ok, decoded = pcall(codec.decode, body)

  if not ok or not decoded then
    return nil
  end

  edit(decoded.lanes)

  return frame.frame(codec.encode(decoded))
end

return mods
