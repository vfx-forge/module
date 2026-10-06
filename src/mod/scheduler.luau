local RunService = game:GetService("RunService")

local clock = require("@mod/clock")
local logger = require("@mod/logger")

local COMPUTE = { "undo", "wait", "compute" }
local LATE = { "shake", "screen", "follow" }

-- one suffix per load, so two copies of the module in one place never bind
-- under the same name
local SUFFIX = string.format("%x", math.random(0, 0x7fffffff))

local COMPUTE_NAME = `forge_compute_{SUFFIX}`
local LATE_NAME = `forge_late_{SUFFIX}`

export type Phase = "undo" | "wait" | "compute" | "shake" | "screen" | "follow"

export type Handle = {
  Connected: boolean,
  Disconnect: (self: Handle) -> (),
}

type Step = Handle & {
  run: (deltaTime: number) -> (),
  owner: any,
  clock: clock.Clock,
  survives: boolean,
  warned: boolean,
}

type Slot = {
  depths: { number },
  buckets: { [number]: { Step } },
}

local function disconnect(self: Handle)
  self.Connected = false
end

local function insertDepth(depths: { number }, depth: number)
  local at = #depths + 1

  for i, d in depths do
    if d > depth then
      at = i
      break
    end
  end

  table.insert(depths, at, depth)
end

local scheduler = {}

-- told about the owner of a step that threw, set by @mod/lifetime so this
-- module never requires it
scheduler.failed = nil :: ((owner: any) -> ())?

-- the real seconds every frame so far has stepped, read by an emit's handle to
-- count the time before it first asked for its own
scheduler.now = 0

local slots: { [string]: Slot } = {}

for _, phases in { COMPUTE, LATE } do
  for _, phase in phases do
    slots[phase] = { depths = {}, buckets = {} }
  end
end

local service: any = RunService
local connection: RBXScriptConnection? = nil
local bound = false
local stopped = false

-- the pass in progress, kept out here so a throw can re-enter it one step
-- after the thrower. a step must not yield: one that does leaves the pass
-- open, and every frame until it resumes is skipped rather than let run over
-- the pass it left
local bucket: { Step } = {}
local passer: thread? = nil
local passing = false
local index = 0
local kept = 0
local count = 0
local delta = 0

-- set when a step refreshes a clock off 1 during a pass that began at 1: the
-- rest of that pass is handed scaled deltas
local scaling = false

table.insert(clock.unfolded, function()
  scaling = true
end)

-- the pass is read into locals, and written back before each step runs so a
-- throw re-enters from where it left off. while every clock runs at 1, as it
-- does unless something set a speed, a pause or a controller, the frame's delta
-- is handed on as it is, at what a frame cost before there were clocks
local function sweep()
  local b, d, c = bucket, delta, count
  local i, k = index, kept

  while i < c do
    i += 1

    local step = b[i]

    if step.Connected then
      index, kept = i, k
      step.run(d)

      -- a refresh took the frame off 1: this step is kept, the rest are scaled
      if scaling then
        if step.Connected then
          k += 1
          b[k] = step
        end

        break
      end
    end

    if step.Connected then
      k += 1
      b[k] = step
    end
  end

  index, kept = i, k
end

-- the same pass with each step's delta scaled by its clock
local function sweepScaled()
  local b, d, c = bucket, delta, count
  local i, k = index, kept
  local frame = clock.frame

  while i < c do
    i += 1

    local step = b[i]

    if step.Connected then
      local timeline = step.clock

      index, kept = i, k
      step.run(d * (if timeline.frame == frame then timeline.factor else clock.factorOf(timeline)))
    end

    if step.Connected then
      k += 1
      b[k] = step
    end
  end

  index, kept = i, k
end

-- every step still connected runs once, in the order it was added. one added
-- while the pass runs waits for the next pass, and a step that throws is
-- dropped, reported, and its owner told, while the rest of the pass carries on
-- after it. a step added to survive a throw, a service kept for the session,
-- is reported once and kept running
local function runBucket(list: { Step }, deltaTime: number)
  bucket, index, kept, count, delta = list, 0, 0, #list, deltaTime
  passer = coroutine.running()
  passing = true
  scaling = false

  while true do
    local ok, err = xpcall(if clock.uniform then sweep else sweepScaled, debug.traceback)

    if ok then
      if index >= count then
        break
      end

      continue
    end

    local step = bucket[index]

    if not step.warned then
      step.warned = true
      logger.warn(`a step failed with error: {err}`)
    end

    if step.survives then
      if step.Connected then
        kept += 1
        bucket[kept] = step
      end

      continue
    end

    step.Connected = false

    local failed = scheduler.failed

    if failed == nil or step.owner == nil then
      continue
    end

    local told, reason = pcall(failed, step.owner)

    if not told then
      logger.warn(`releasing a failed step's owner failed with error: {reason}`)
    end
  end

  passing = false
  passer = nil

  local total = #list

  for i = count + 1, total do
    kept += 1
    list[kept] = list[i]
  end

  for i = kept + 1, total do
    list[i] = nil
  end
end

local function runPhases(phases: { string }, deltaTime: number)
  if passing then
    logger.warn("a frame of the scheduler started inside a pass, so it was skipped")
    return
  end

  for _, phase in phases do
    local slot = slots[phase]
    local depths = slot.depths
    local i = 1

    while i <= #depths do
      local depth = depths[i]

      runBucket(slot.buckets[depth], deltaTime)

      -- a depth added while this one ran may have moved it along
      i = (table.find(depths, depth) :: number) + 1
    end
  end
end

local function bind()
  if bound or stopped then
    return
  end

  bound = true

  if service:IsRunning() then
    service:BindToRenderStep(COMPUTE_NAME, Enum.RenderPriority.First.Value, scheduler.compute)
    service:BindToRenderStep(LATE_NAME, Enum.RenderPriority.Last.Value + 1, scheduler.late)
  else
    connection = service.RenderStepped:Connect(scheduler.frame)
  end
end

-- a step advances on the clock it is given, else on its owner's, else on
-- real time
function scheduler.add(
  phase: Phase,
  run: (deltaTime: number) -> (),
  depth: number?,
  owner: any?,
  survives: boolean?,
  timeline: clock.Clock?
): Handle
  local slot = slots[phase]
  local at = depth or 0
  local list = slot.buckets[at]

  if list == nil then
    list = {}
    slot.buckets[at] = list
    insertDepth(slot.depths, at)
  end

  local step: Step = {
    Connected = true,
    Disconnect = disconnect,
    run = run,
    owner = owner,
    clock = timeline or (if owner ~= nil then owner.clock else nil) or clock.REAL,
    survives = survives == true,
    warned = false,
  }

  table.insert(list, step)

  bind()

  return step
end

-- a step added with no owner takes the one that holds it, so a throw ends
-- the holder rather than the step alone, and it advances on the holder's
-- clock from its next frame. a step kept for the session is never adopted
function scheduler.adopt(handle: Handle, owner: any)
  local step = handle :: Step

  if step.Disconnect ~= disconnect or step.owner ~= nil or step.survives then
    return
  end

  step.owner = owner

  if step.clock == clock.REAL and owner.clock ~= nil then
    step.clock = owner.clock
  end
end

-- the first half of a frame: every clock's factor for the frame, undoing
-- what the last one left on shared targets, the waits that are due, then
-- every step that computes a value
function scheduler.compute(deltaTime: number)
  if not passing then
    scheduler.now += deltaTime
    clock.tick()
  end

  runPhases(COMPUTE, deltaTime)
end

-- the second half: the camera shake, then the screens, then whatever follows
-- a parent, shallowest first
function scheduler.late(deltaTime: number)
  runPhases(LATE, deltaTime)
end

-- whether the caller is a step, or a callback a step made, on the pass's own
-- thread, where a yield would leave the pass open. a thread a step resumed is
-- not the pass, and may yield
function scheduler.inPass()
  return passing and coroutine.running() == passer
end

function scheduler.frame(deltaTime: number)
  scheduler.compute(deltaTime)
  scheduler.late(deltaTime)
end

-- a running game gets a binding for each half, around the camera scripts; the
-- editor drives its camera with no binding, so one connection runs both
function scheduler.start(runService: any?)
  stopped = false

  -- a bound scheduler is unbound from the service it bound to
  if not bound then
    service = runService or RunService
  end

  bind()
end

-- nothing steps until the scheduler is started again, and no step added in
-- the meantime binds it
function scheduler.stop()
  stopped = true

  if not bound then
    return
  end

  bound = false

  local current = connection

  if current ~= nil then
    connection = nil
    current:Disconnect()
    return
  end

  service:UnbindFromRenderStep(COMPUTE_NAME)
  service:UnbindFromRenderStep(LATE_NAME)
end

return scheduler
