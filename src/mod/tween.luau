local RunService = game:GetService("RunService")

local mods = require("@mod/mods")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local timing_common = require("@mod/common/timing")

local Bezier = require("@obj/Bezier")

local tween = {}

tween.bezier_cache = {} :: { [string]: Bezier.Bezier }

function tween.fromParams(
  params: string,
  duration: number,
  animator: (alpha: number, deltaTime: number, elapsed: number) -> number?,
  awaitTween: RBXScriptConnection?,
  onFinish: ((organic: boolean) -> ())?,
  startAtZero: boolean?,
  stepAtPriority: number?
)
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

  local cleanupStepper

  local function step(deltaTime)
    -- roblox tweens apparently don't start from alpha=0
    if not startAtZero and elapsed == 0 then
      elapsed = math.clamp(elapsed + deltaTime, 0, math.max(duration, 0))
    end

    local t = timing_common.progress(elapsed, duration)
    local alpha = 1 - bezier:getEase(t).y

    local result = animator(alpha, deltaTime, elapsed)

    if (result == nil or timing_common.done(elapsed, duration)) and (not awaitTween or not awaitTween.Connected) then
      cleanupStepper()

      if onFinish then
        onFinish(true)
      end

      return
    end

    if result then
      elapsed = math.clamp(elapsed + result, 0, math.max(duration, 0.001))
    end
  end

  if not stepAtPriority then
    local connection: RBXScriptConnection
    connection = RunService.RenderStepped:Connect(step)

    cleanupStepper = function()
      connection:Disconnect()
    end

    return connection
  else
    local id = utility.getRandomId()

    RunService:BindToRenderStep(id, stepAtPriority, step)

    local bound = true

    cleanupStepper = function()
      if not bound then
        return
      end

      bound = false

      RunService:UnbindFromRenderStep(id)
    end

    return cleanupStepper
  end
end

-- the stepper half of a timer, with no opinion about what finishing means:
-- tween.timer resumes the thread that called it, tween.after calls a function
-- and never yields at all
local function runTimer(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  awaitTween: RBXScriptConnection?,
  scope: lifetime.effect?,
  stepAtPriority: number?,
  onDone: () -> ()
)
  duration = timing_common.duration(duration)

  local elapsed = 0

  local cleanupStepper

  local function step(deltaTime)
    local result = counter(deltaTime, elapsed)

    if (result == nil or timing_common.done(elapsed, duration)) and (not awaitTween or not awaitTween.Connected) then
      cleanupStepper()
      onDone()
      return
    end

    if result then
      elapsed = math.clamp(elapsed + result, 0, math.max(duration, 0.001))
    end
  end

  if not stepAtPriority then
    local connection = RunService.RenderStepped:Connect(step)

    cleanupStepper = function()
      connection:Disconnect()
    end
  else
    local id = utility.getRandomId()

    RunService:BindToRenderStep(id, stepAtPriority, step)

    local bound = true

    cleanupStepper = function()
      if not bound then
        return
      end

      bound = false

      RunService:UnbindFromRenderStep(id)
    end
  end

  if scope then
    lifetime.hold(scope, cleanupStepper)
  end
end

function tween.timer(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  awaitTween: RBXScriptConnection?,
  scope: lifetime.effect?,
  stepAtPriority: number?
)
  local main = coroutine.running()

  runTimer(duration, counter, awaitTween, scope, stepAtPriority, function()
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
function tween.after(
  duration: number,
  counter: (deltaTime: number, elapsed: number) -> number,
  onFinish: () -> (),
  scope: lifetime.effect?,
  stepAtPriority: number?
)
  runTimer(duration, counter, nil, scope, stepAtPriority, onFinish)
end

-- one target driven by one track: the first value is written at once, and an
-- animated track keeps writing on a timer the effect holds until its span is
-- up, ending on the track's last value so a frame that overshoots cannot leave
-- the target short of it
function tween.drive(scope: lifetime.effect, track: mods.Track, write: (v: any) -> (), stepAtPriority: number?)
  write(track.at(0))

  if not track.animated then
    return
  end

  tween.after(track.span, function(deltaTime, elapsed)
    write(track.at(elapsed))
    return deltaTime
  end, function()
    write(track.at(track.span))
  end, scope, stepAtPriority)
end

return tween
