local curve = require("@mod/curve")
local reader = require("@mod/reader")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local tween = {}

export type Handle = scheduler.Handle

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
