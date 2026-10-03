local curve = require("@mod/curve")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local timing_common = require("@mod/common/timing")

local Bezier = require("@obj/Bezier")

local tween = {}

export type Handle = scheduler.Handle

tween.bezier_cache = {} :: { [string]: Bezier.Bezier }

-- a step that follows a parent runs late in the frame at the depth it is
-- given; every other step computes early
local function register(step: (deltaTime: number) -> (), follow: number?, owner: any?): scheduler.Handle
  if follow ~= nil then
    return scheduler.add("follow", step, follow, owner)
  end

  return scheduler.add("compute", step, 0, owner)
end

function tween.fromParams(
  params: string,
  duration: number,
  animator: (alpha: number, deltaTime: number, elapsed: number) -> number?,
  awaitTween: scheduler.Handle?,
  onFinish: ((organic: boolean) -> ())?,
  startAtZero: boolean?,
  follow: number?
): scheduler.Handle
  local bezier = tween.bezier_cache[params]

  if not bezier then
    local success, points = pcall(function()
      return utility.deserializePath(params)
    end)

    if not success then
      logger.error(`failed to decode bezier path data with error: {points}`)
    end

    -- use 0 accuracy as it saves performance because there is no need to calculate the length
    bezier = Bezier.new(points, 0)
    tween.bezier_cache[params] = bezier
  end

  duration = timing_common.duration(duration)

  local elapsed = 0
  local handle: scheduler.Handle

  local function step(deltaTime: number)
    -- roblox tweens apparently don't start from alpha=0
    if not startAtZero and elapsed == 0 then
      elapsed = math.clamp(elapsed + deltaTime, 0, math.max(duration, 0))
    end

    local t = timing_common.progress(elapsed, duration)
    local alpha = 1 - bezier:getEase(t).y

    local result = animator(alpha, deltaTime, elapsed)

    if (result == nil or timing_common.done(elapsed, duration)) and (not awaitTween or not awaitTween.Connected) then
      handle:Disconnect()

      if onFinish then
        onFinish(true)
      end

      return
    end

    if result then
      elapsed = math.clamp(elapsed + result, 0, math.max(duration, 0.001))
    end
  end

  handle = register(step, follow)

  return handle
end

-- the stepper half of a timer, with no opinion about what finishing means:
-- tween.timer resumes the thread that called it, tween.after calls a function
-- and never yields at all
local function runTimer(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  awaitTween: scheduler.Handle?,
  scope: lifetime.effect?,
  follow: number?,
  onDone: () -> (),
  unbounded: boolean?
)
  duration = if unbounded then math.huge else timing_common.duration(duration)

  local elapsed = 0
  local handle: scheduler.Handle

  local function step(deltaTime: number)
    local result = counter(deltaTime, elapsed)

    if (result == nil or timing_common.done(elapsed, duration)) and (not awaitTween or not awaitTween.Connected) then
      handle:Disconnect()
      onDone()
      return
    end

    if result then
      elapsed = math.clamp(elapsed + result, 0, math.max(duration, 0.001))
    end
  end

  handle = register(step, follow, scope)

  if scope then
    lifetime.hold(scope, handle)
  end
end

function tween.timer(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  awaitTween: scheduler.Handle?,
  scope: lifetime.effect?,
  follow: number?
)
  if scheduler.inPass() then
    logger.error("tween.timer yields, so it cannot run inside a step or a tween's callback; start it in task.spawn")
  end

  local main = coroutine.running()

  runTimer(duration, counter, awaitTween, scope, follow, function()
    task.spawn(main)
  end)

  coroutine.yield()
end

-- a wait that belongs to the effect rather than to the scheduler, for a caller
-- that cannot yield: it steps on the effect's own clock, so whatever the counter
-- returns is what time does, and its cleanup goes in the scope, so tearing the
-- effect down cancels it.
--
-- task.delay does neither. It keeps wall-clock time whatever the effect's speed
-- is doing, and it fires into whatever is left of an effect that has already
-- been destroyed, which for a pooled part is whoever holds it next
--
-- an infinite duration here means there is no ceiling and the counter alone
-- ends the wait, where every other helper runs an unusable duration as zero
function tween.after(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  onFinish: () -> (),
  scope: lifetime.effect?,
  follow: number?
)
  runTimer(duration, counter, nil, scope, follow, onFinish, duration == math.huge)
end

local function finish(handle: scheduler.Handle, done: (() -> ())?)
  handle:Disconnect()

  if done ~= nil then
    done()
  end
end

-- a curve played on the effect's clock and held by the effect. `fn` sees its
-- first value at once, then one a frame, each after the frame is counted, the
-- last at the curve's end. it ends there, when `fn` answers false or when the
-- clock halts for good, and calls `done` then; a clear stops it with no `done`
function tween.play(
  scope: lifetime.effect,
  shape: curve.Curve,
  fn: (alpha: number, deltaTime: number, elapsed: number) -> boolean?,
  follow: number?,
  done: (() -> ())?
): scheduler.Handle
  local duration = shape.duration
  local elapsed = 0
  local handle: scheduler.Handle

  local function step(deltaTime: number)
    elapsed = math.min(elapsed + deltaTime, duration)

    local more = fn(shape:at(elapsed / duration), deltaTime, elapsed)

    if more == false or elapsed >= duration or scope.clock.halted then
      finish(handle, done)
    end
  end

  handle = lifetime.hold(
    scope,
    if follow ~= nil then scheduler.add("follow", step, follow, scope) else scheduler.add("compute", step, 0, scope)
  )

  -- an effect already released let it go at once, and it never plays
  if not handle.Connected then
    return handle
  end

  local more = fn(shape:at(if duration > 0 then 0 else 1), 0, 0)

  if more == false or duration <= 0 or scope.clock.halted then
    finish(handle, done)
  end

  return handle
end

local function noop() end

-- a curve played as tween.play plays it, the calling thread of the effect
-- parked until it ends: at its end, when `fn` answers false or on a halt. a
-- clear closes the thread with it
function tween.wait(
  scope: lifetime.effect,
  shape: curve.Curve,
  fn: ((alpha: number, deltaTime: number, elapsed: number) -> boolean?)?,
  follow: number?
)
  local ended = lifetime.join(scope)

  tween.play(scope, shape, fn or noop, follow, lifetime.add(ended))
  lifetime.awaitJoin(ended)
end

-- one target driven by one track: its first value at once and, while the
-- track is animated, one a frame until its span is up, the last on the
-- track's end so a frame that overshoots cannot leave the target short of
-- it. answers the tween, or nil for a track that never moves
function tween.drive(
  scope: lifetime.effect,
  track: reader.Track,
  write: (v: any) -> (),
  follow: number?
): scheduler.Handle?
  if not track.animated then
    write(track.at(0))
    return nil
  end

  return tween.play(scope, curve.new(track.duration, "linear"), function(_, _, elapsed: number)
    write(track.at(elapsed))
  end, follow)
end

return tween
