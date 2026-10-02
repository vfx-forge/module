local logger = require("@mod/logger")
local numeric_common = require("@mod/common/numeric")

local GoodSignal = require("@pkg/GoodSignal")

export type Clock = {
  parent: Clock?,

  -- what the owner sets: the global speed, a handle's speed, an effect's
  -- authored Speed
  speed: number,
  paused: boolean,

  -- a controller's multiplier, keyed by the key the copies of one nested
  -- controller share, or else by the controller's effect
  scales: { [any]: number }?,

  -- the parent's factor times the speed and every scale, 0 while paused, as
  -- worked out on frame `frame`
  factor: number,
  frame: number,

  -- the factor a clock hanging from this one takes as its parent's, worked out
  -- with it: the factor itself, or under a halted clock the factor as if its
  -- speed were 1, so a nested emit it started still runs out
  through: number,

  -- counted among the clocks that are not at 1 of their own
  moved: boolean,
  dropped: boolean,

  -- an authored Speed that rests at or below zero for good, so the effect's
  -- timers end instead of waiting on a clock that never moves again
  halted: boolean,

  watchers: { (factor: number, previous: number) -> () }?,
  told: number,
}

local clock = {}

-- bumped once a frame, before any step: a clock's factor is worked out the
-- first time the frame reads it and kept for the rest of the frame
clock.frame = 0

-- no clock was off 1 of its own when the frame began, so the frame's steps
-- take its delta as it is
clock.uniform = true

-- called when a refresh takes a frame that began at 1 off it, for every
-- scheduler to scale the rest of its pass
clock.unfolded = {} :: { () -> () }

-- how many clocks are off 1 of their own
local moving = 0

-- the clocks something watches, checked once a frame
local watched: { Clock } = {}

-- where the tick stands in `watched`, 0 between ticks
local cursor = 0

local announcedSpeed = 1
local announcedPaused = false

local function make(parent: Clock?): Clock
  return {
    parent = parent,
    speed = 1,
    paused = false,
    scales = nil,
    factor = 1,
    frame = -1,
    through = 1,
    moved = false,
    dropped = false,
    halted = false,
    watchers = nil,
    told = 1,
  }
end

-- every scale on the clock multiplied together
local function scalesOf(c: Clock): number
  local f = 1
  local scales = c.scales

  if scales ~= nil then
    for _, scale in scales do
      f *= scale
    end
  end

  return f
end

-- the clock's speed times every scale, whether it is paused or not
local function scaledOf(c: Clock): number
  return c.speed * scalesOf(c)
end

-- the clock's own multiplier, without its parent's
local function multiplierOf(c: Clock): number
  if c.paused then
    return 0
  end

  return scaledOf(c)
end

-- the clock's factor for the frame, its parents' worked out first, each clock
-- at most once a frame
function clock.factorOf(c: Clock): number
  if c.frame == clock.frame then
    return c.factor
  end

  local parent = c.parent
  local above = 1

  if parent ~= nil then
    if parent.frame ~= clock.frame then
      clock.factorOf(parent)
    end

    above = parent.through
  end

  local f = multiplierOf(c) * above

  c.factor = f
  c.frame = clock.frame

  if not c.halted then
    c.through = f
  elseif c.paused then
    c.through = 0
  else
    c.through = scalesOf(c) * above
  end

  return f
end

-- the factor the frame has for the clock kept before its owner changes it, so
-- a change reaches the clock and everything below it from the next frame
-- whatever order the frame reads them in
local function pin(c: Clock)
  clock.factorOf(c)
end

-- counts the clock in or out of the ones off 1 after its owner changed it
local function recount(c: Clock)
  local moved = not c.dropped and (c.paused or c.speed ~= 1 or c.scales ~= nil)

  if moved == c.moved then
    return
  end

  c.moved = moved
  moving += if moved then 1 else -1
end

-- what a step with no owner advances on: real time
clock.REAL = make(nil)

-- the speed and pause every effect runs under, times every Global controller
clock.global = make(nil)

-- real time that a global pause still stops: a Global controller's own
-- timeline runs on it, so two of them never slow each other
clock.wall = make(nil)

-- fire with the effective speed when it changes, and with the pause when it
-- changes. each handler is spawned on a runner thread of the signal's own, run
-- synchronously until it first yields, so a handler that yields cannot stall
-- the frame
clock.speedChanged = GoodSignal.new()
clock.pausedChanged = GoodSignal.new()

function clock.new(parent: Clock): Clock
  return make(parent)
end

-- the owner is done with the clock: it goes back to 1, so nothing still
-- hanging from it is scaled by an owner that is gone, and nothing watches it
function clock.drop(c: Clock)
  pin(c)

  c.dropped = true
  c.speed = 1
  c.paused = false
  c.scales = nil
  c.halted = false

  recount(c)

  if c.watchers ~= nil then
    c.watchers = nil

    local index = table.find(watched, c)

    if index then
      table.remove(watched, index)

      if index <= cursor then
        cursor -= 1
      end
    end
  end
end

-- a NaN or an infinite value is ignored: either would turn a paused parent's 0
-- into a NaN that stalls every clock below for good
function clock.setSpeed(c: Clock, speed: number)
  if c.dropped or not numeric_common.finite(speed) then
    return
  end

  pin(c)

  c.speed = speed
  recount(c)
end

function clock.setPaused(c: Clock, paused: boolean)
  if c.dropped then
    return
  end

  pin(c)

  c.paused = paused
  recount(c)
end

function clock.scale(c: Clock, key: any, value: number)
  if c.dropped or not numeric_common.finite(value) then
    return
  end

  pin(c)

  local scales = c.scales

  if scales == nil then
    scales = {}
    c.scales = scales
  end

  scales[key] = value
  recount(c)
end

function clock.unscale(c: Clock, key: any)
  local scales = c.scales

  if scales == nil then
    return
  end

  pin(c)

  scales[key] = nil

  if next(scales) == nil then
    c.scales = nil
  end

  recount(c)
end

-- every scale off the clock at once, for a teardown that must not trust each
-- owner to take its own off
function clock.unscaleAll(c: Clock)
  if c.scales == nil then
    return
  end

  pin(c)

  c.scales = nil
  recount(c)
end

-- the factor worked out again now, for an owner that changes its clock inside
-- a frame and wants its own later steps to see it on that frame. what hangs
-- from it follows on the next frame
function clock.refresh(c: Clock)
  c.frame = -1

  if clock.factorOf(c) ~= 1 then
    if clock.uniform then
      for _, unfolded in clock.unfolded do
        unfolded()
      end
    end

    clock.uniform = false
  end
end

-- hangs a clock from another, for an owner that learns where it belongs only
-- after it was made
function clock.reparent(c: Clock, parent: Clock)
  pin(c)

  c.parent = parent
  clock.refresh(c)
end

-- called with the new factor and the one it was last called with, once a
-- frame at most, whenever the factor moved. answers what stops the calls
function clock.watch(c: Clock, watcher: (factor: number, previous: number) -> ())
  if c.dropped then
    return function() end
  end

  local watchers = c.watchers

  if watchers == nil then
    watchers = {}
    c.watchers = watchers
    c.told = clock.factorOf(c)

    table.insert(watched, c)
  end

  table.insert(watchers, watcher)

  return function()
    local list = c.watchers

    if list == nil then
      return
    end

    local index = table.find(list, watcher)

    if index then
      table.remove(list, index)
    end

    if #list > 0 then
      return
    end

    c.watchers = nil

    local at = table.find(watched, c)

    if at then
      table.remove(watched, at)

      if at <= cursor then
        cursor -= 1
      end
    end
  end
end

local function tell(c: Clock, factor: number)
  local previous = c.told

  c.told = factor

  for _, watcher in table.clone(c.watchers :: { (factor: number, previous: number) -> () }) do
    local ok, err = pcall(watcher, factor, previous)

    if not ok then
      logger.warn(`a clock watcher failed with error: {err}`)
    end
  end
end

-- a speed a caller hands in, refused unless it is a finite number of 0 or
-- more. `name` is what the caller set, for the error
function clock.checked(value: any, name: string): number
  if typeof(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
    logger.error(`{name} takes a finite number of 0 or more, got {tostring(value)}`)
  end

  return value
end

-- the global speed times every Global controller, whether paused or not
function clock.effective(): number
  return scaledOf(clock.global)
end

-- fires each signal whose value moved since it last fired
function clock.announce()
  local speed = clock.effective()
  local paused = clock.global.paused

  if speed ~= announcedSpeed then
    announcedSpeed = speed
    clock.speedChanged:Fire(speed)
  end

  if paused ~= announcedPaused then
    announcedPaused = paused
    clock.pausedChanged:Fire(paused)
  end
end

function clock.setGlobalSpeed(speed: number)
  clock.setSpeed(clock.global, speed)
  clock.announce()
end

-- a global pause stops the wall clock too, so a Global controller freezes
-- with everything it scales
function clock.setGlobalPaused(paused: boolean)
  clock.setPaused(clock.global, paused)
  clock.setPaused(clock.wall, paused)
  clock.announce()
end

-- once a frame, before any step: a new frame for every factor, every watcher
-- told of a factor that moved, and the signals of a global change
function clock.tick()
  clock.frame += 1
  clock.uniform = moving == 0

  -- a watcher may stop watching any clock while it is told, and the cursor
  -- follows the list as the clock leaves it
  cursor = 1

  while cursor <= #watched do
    local c = watched[cursor]
    local factor = clock.factorOf(c)

    if factor ~= c.told then
      tell(c, factor)
    end

    cursor += 1
  end

  cursor = 0

  clock.announce()
end

return clock
