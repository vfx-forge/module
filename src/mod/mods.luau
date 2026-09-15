local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local codec = require("@mod/modifier_codec")
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

-- how long a queue runs on its own terms, for a caller with no effect duration
-- to lend it. a delay pushes what follows it out, so the answer is the far end
-- of the queue rather than its longest single duration, and a caller whose
-- delay is drawn per instance passes the rolls in so the span is the one THIS
-- instance will run
function mods.span(queue: { any }, fallback: number, rolls: Rolls?): (number, number)
  local picks = if rolls then rolls.picks else nil

  -- schedule seeds a linked modifier's run from the fallback, so a nan one
  -- poisons every offset in the queue and the span comes back nan. zero makes
  -- the frontier the far end of the authored durations instead
  if fallback ~= fallback then
    fallback = 0
  end

  local _, frontier, linked = modifiers.schedule(queue, picks, fallback, if rolls then rolls.env else nil)

  -- an effect turns this straight into a tween's duration, and a tween that
  -- never ends holds the emit open for good. nothing an author can mean by a
  -- span is infinite, so an unusable one falls back the same way an empty one does
  if frontier ~= frontier or frontier <= 0 or frontier == math.huge then
    return fallback, linked
  end

  return frontier, linked
end

-- a queue that moves nothing: every entry holds a value the target already
-- carries, so driving it writes that value back every frame for the length of
-- the run and holds the emit open while it does. the sample guard behind
-- mods.build catches the base-only case only where nothing rests at all, since
-- such a queue hands back whatever the row does rest at
function mods.inert(queue: { any }): boolean
  if #queue == 0 then
    return false
  end

  for _, m in queue do
    if not modifiers.BASE_KINDS[m.kind] then
      return false
    end
  end

  return true
end

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

  local body = frame.unframe(raw)

  if body == nil then
    logger.warn(`{name} carries a framed modifier queue that could not be read`)
    return nil
  end

  local ok, decoded = pcall(codec.decode, body)

  if ok and decoded then
    return decoded.lanes
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

-- randomizer alphas, drawn endpoints, drawn offsets and the envelope offset are
-- all drawn HERE, once, which is once per emitted instance. that makes "one
-- draw per instance" structural rather than a rule every call site has to
-- remember. it is its own function because a drawn offset moves the far end of
-- the queue, so a caller that needs the SPAN first has to draw before it can
-- ask for one, and then hand the same rolls to the sampler
function mods.roll(queue: { any }, env: { [string]: any }?): Rolls
  local rng = Random.new()
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
    local offsetDrawn = type(m.offset) == "table" and value.isDraw(m.offset)

    if startDrawn or finishDrawn or offsetDrawn then
      picks[i] = {
        start = if startDrawn then rng:NextNumber() else nil,
        finish = if finishDrawn then rng:NextNumber() else nil,
        offset = if offsetDrawn then rng:NextNumber() else nil,
      }
    end
  end

  return { draws = draws, picks = picks, env = env, envelope = rng:NextNumber() * 2 - 1 }
end

-- a caller that already read the queue, to span it or to test it, passes it
-- back in rather than paying a second base64 plus buffer decode for the same
-- attribute, and passes its rolls back in so the span it computed and the
-- sampler it gets are drawn from the same hat
function mods.sampler(
  ref: Instance,
  source: string,
  name: string,
  duration: number,
  queue: { any },
  rolls: Rolls?,
  linked: number?
): ((elapsed: number, own: any?) -> any)?
  if #queue == 0 then
    return nil
  end

  local rolled = rolls or mods.roll(queue)
  -- `duration` is the reach, which a delay inflates. seeding the linked run
  -- from it would stretch every modifier that names no duration and leave a
  -- delayed one short of its finish, so a caller that knows what it lent says so
  local lent = if linked ~= nil then linked else duration
  local offsets, _, resolved = modifiers.schedule(queue, rolled.picks, lent, rolled.env)

  local base = baseOf(ref, source, name)

  local ctx: modifiers.Ctx = {
    duration = duration,
    base = base,
    draws = rolled.draws,
    picks = rolled.picks,
    offsets = offsets,
    linked = resolved,
    env = rolled.env,
    envelope = rolled.envelope,
  }

  -- a lane fired over a running row begins from the value under it rather than
  -- from what the instance itself carries, so the base is the caller's per call
  return function(elapsed: number, own: any?)
    ctx.base = if own ~= nil then own else base

    return modifiers.evaluate(queue, elapsed, ctx)
  end
end

export type Track = {
  at: (elapsed: number, own: any?, since: number?) -> any,
  span: number,
  animated: boolean,
  has: (lane: string) -> boolean,
}

local Piece = {}
Piece.__index = Piece

-- the clock a lane fires on belongs to the emitted piece rather than to the
-- read: one ctx serves every piece of an emit and each piece has tracks of its
-- own. a module declares the names it may fire and the piece refuses any other,
-- since a name nothing declares can only be a module bug
export type Piece = typeof(setmetatable({} :: { fired: { [string]: number }, events: { string }? }, Piece))

type Lane = {
  name: string,
  order: number,
  from: number?,
  reach: number,
  sample: (elapsed: number, own: any?) -> any,
}

function Piece.fire(self: Piece, name: string, elapsed: number)
  local events = self.events

  if events == nil or table.find(events, name) == nil then
    logger.error(`no lane named {name} is declared here`)
  end

  -- firing again restarts the lane, and a clock nobody can read starts it where
  -- the piece already is rather than nowhere at all
  self.fired[name] = if typeof(elapsed) == "number" and elapsed == elapsed then math.max(elapsed, 0) else 0
end

function mods.piece(events: { string }?): Piece
  return setmetatable({ fired = {}, events = events }, Piece)
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
-- it, and the later of two that started together. `under` is the lane a base is
-- being folded for, which cannot own the moment it starts and neither can a lane
-- after it in the same frame, so the fold always descends
local function ownerAt(lanes: { Lane }, piece: Piece?, elapsed: number, since: number?, under: number?): number?
  local best: number? = nil
  local at = -1

  for i, lane in lanes do
    local from = firedAt(lane, piece)

    if from == nil or from > elapsed then
      continue
    end

    if under ~= nil and from == elapsed and i >= under then
      continue
    end

    if since ~= nil and from <= since then
      continue
    end

    if from >= at then
      at = from
      best = i
    end
  end

  return best
end

-- the row's value at `elapsed`: the owning lane's queue run from its own
-- trigger, over what the lanes under it hold at that trigger. a lane producing
-- nothing passes that value through, and a row nobody owns rests where the
-- caller says it rests
local function valueAt(lanes: { Lane }, piece: Piece?, elapsed: number, own: any, since: number?, under: number?): any
  local i = ownerAt(lanes, piece, elapsed, since, under)

  if i == nil then
    return own
  end

  local lane = lanes[i]
  local from = firedAt(lane, piece) :: number
  local base = valueAt(lanes, piece, from, own, since, i)
  local v = lane.sample(elapsed - from, base)

  return if v ~= nil then v else base
end

local function trackFrom(set: { Lane }, piece: Piece?, span: number, rest: any): Track
  local reach = span

  for _, lane in set do
    if lane.name == "start" then
      reach = lane.reach
    end
  end

  return {
    at = function(elapsed: number, own: any?, since: number?)
      return valueAt(set, piece, elapsed, if own ~= nil then own else rest, since, nil)
    end,
    span = reach,
    animated = true,
    has = function(lane: string)
      for _, held in set do
        if held.name == lane then
          return true
        end
      end

      return false
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

local function constant(default: any, span: number): Track
  return {
    at = function(_, own: any?)
      return if own ~= nil then own else default
    end,
    span = span,
    animated = false,
    has = noLane,
  }
end

-- the value a knob wants, which is the knob's own answer, re-exported here for
-- the callers that already hold mods
mods.kindOf = knob.kindOf

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
  probe: any
): (((elapsed: number, own: any?) -> any)?, number)
  local rolls = mods.roll(queue, env)
  local reach, linked = mods.span(queue, span, rolls)
  local sample = mods.sampler(ref, source, name, reach, queue, rolls, linked)

  if sample == nil then
    return nil, span
  end

  if sample(0) == nil and (probe == nil or sample(0, probe) == nil) then
    return nil, span
  end

  return sample, reach
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

-- a lane's entries with the two old-format rewrites applied: an effect-owned
-- start becomes a half quad, and a half quad is completed from the default. nil
-- when the lane cannot be completed at all, which is a lane that says nothing
local function completed(
  queue: { any },
  framed: boolean,
  seeded: boolean,
  lead: any,
  fillStart: value.Value?,
  fillFinish: value.Value?
): { any }?
  -- an old row whose start was only ever a seed for a target carrying nothing
  -- of its own says where the value ENDS, and the effect says where it comes
  -- from. handing that start back makes it a half quad, which the block below
  -- completes from the default. a row that already named no finish gives up
  -- both ends and keeps only its duration and curve, which is what such a row
  -- did when the effect ran the other half itself. only the old format reads
  -- this way: a framed lane was authored to mean exactly what it says
  if
    seeded
    and #queue == 1
    and queue[1].kind == "tween"
    and (queue[1].partial == nil or queue[1].partial == "finish")
    and not framed
  then
    local m = table.clone(queue[1])

    m.partial = if queue[1].partial == "finish" then "both" else "start"
    queue = { m }
  end

  if #queue == 1 and queue[1].partial then
    -- a curve alone can only ease a ramp. a constant default has no ramp and a
    -- drawn default is not a tween, so the curve is dropped as the old arms
    -- dropped it for those knobs
    if queue[1].partial == "both" and (lead == nil or lead.kind ~= "tween") then
      return nil
    end

    return legacy_mods.complete(queue, fillStart, fillFinish)
  end

  return queue
end

-- the one way a knob becomes a track. it always answers: what rests when nothing
-- usable is authored, else one sampler per lane over that lane's own reach. a
-- default given as a lane map is what runs when nothing is authored, for a knob
-- whose resting state is a ramp or a draw rather than a value.
--
-- `ownStart` is for a knob whose start belongs to the effect rather than to the
-- row. `piece` is the clock the row's event lanes fire on, and the row carries
-- none without one
function mods.build(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?,
  lanes: { [string]: { any } }?,
  framed: boolean,
  opts: { ownStart: boolean? }?,
  piece: Piece?
): Track
  local fallback: { [string]: { any } }? = if type(default) == "table" then default else nil
  local rest: any = if fallback then nil else default

  local lead = if fallback then leadTween(fallback.start) else nil

  local fillStart: value.Value? = nil
  local fillFinish: value.Value? = nil
  local want: string? = nil

  if fallback then
    fillStart = lead and lead.start
    fillFinish = lead and lead.finish

    if fillStart and value.isLit(fillStart) then
      want = mods.kindOf(value.resolve(fillStart))
    end
  else
    fillStart = legacy_mods.endpoint(source, name, default)
    fillFinish = fillStart

    if default ~= nil then
      want = mods.kindOf(default)
    end
  end

  -- where a blank start begins, which is where the row rests: the probe a lane
  -- whose first entry chains is judged against, since nothing under such a lane
  -- has run at the moment it is built
  local seed: any = if fillStart ~= nil then value.resolve(fillStart, nil, env) else rest

  local seeded = opts ~= nil and opts.ownStart == true

  -- a default lane is taken as it stands: the two old-format rewrites answer for
  -- what an author stored, and a row's own defaults were never read that way
  local function setOf(map: { [string]: { any } }, authored: boolean): { Lane }
    local out: { Lane } = {}

    for lane, queue in map do
      local order = orderOf(piece, lane)

      if order == nil or #queue == 0 or mods.inert(queue) then
        continue
      end

      local entries = if authored then completed(queue, framed, seeded, lead, fillStart, fillFinish) else queue

      if entries == nil then
        continue
      end

      local sample, reach = laneOf(ref, source, name, entries, span, env, seed)

      if sample == nil then
        continue
      end

      table.insert(out, {
        name = lane,
        order = order,
        -- the end lane fires once the piece's own clock has only its reach
        -- left, and an event lane has no trigger until the module gives it one
        from = if lane == "start" then 0 elseif lane == "end" then math.max(0, span - reach) else nil,
        reach = reach,
        sample = sample,
      })
    end

    table.sort(out, byOrder)

    return out
  end

  local function resting(): Track
    if fallback == nil then
      return constant(rest, span)
    end

    local set = setOf(fallback, false)

    if #set == 0 then
      return constant(nil, span)
    end

    return trackFrom(set, piece, span, rest)
  end

  if lanes == nil then
    return resting()
  end

  local set = setOf(lanes, true)

  if #set == 0 then
    return resting()
  end

  if want ~= nil then
    local got = mods.kindOf(set[1].sample(0, rest))

    if got ~= want then
      mods.warnOnce(ref, name, `{name} samples a {got} where the effect wants a {want}`)
      return resting()
    end
  end

  return trackFrom(set, piece, span, rest)
end

-- the read half: what an effect that still names its own knobs calls
function mods.track(
  ref: Instance,
  source: string,
  name: string,
  default: any,
  span: number,
  env: { [string]: any }?,
  opts: { ownStart: boolean? }?,
  piece: Piece?
): Track
  local lanes, framed = mods.read(ref, source, name)

  return mods.build(ref, source, name, default, span, env, lanes, framed, opts, piece)
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

local function scaleEndpoint(x: any, factor: number)
  if type(x) ~= "table" then
    return
  end

  if x.t == "lit" then
    x.v = scaleValue(x.v, factor)
  elseif x.t == "draw" then
    x.a = scaleValue(x.a, factor)
    x.b = scaleValue(x.b, factor)
  end
end

-- everything in a queue that is a time: durations, waits and the duration of
-- a carried speed ramp. in place, on a decoded queue
function mods.scaleTime(queue: { any }, factor: number)
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

-- every numeric endpoint in a queue. a var names a value that is not the
-- queue's to scale
function mods.scaleValues(queue: { any }, factor: number)
  for _, m in queue do
    scaleEndpoint(m.start, factor)
    scaleEndpoint(m.finish, factor)
  end
end

-- a framed attribute value decoded, edited in place and framed again, so a
-- caller that scales a queue never touches the codec. nil when the value is
-- not a framed queue it can read, and the caller leaves the attribute alone
function mods.recode(raw: any, edit: (queue: { any }) -> ()): string?
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

  local lane = decoded.lanes.start

  if lane ~= nil then
    edit(lane)
  end

  return frame.frame(codec.encode(decoded))
end

return mods
