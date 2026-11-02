local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local frames_common = require("@mod/common/frames")

local common = {}

function common.serialize(ids: { number })
  local buf = buffer.create(#ids * 8)

  for i, id in ids do
    buffer.writef64(buf, (i - 1) * 8, id)
  end

  return buf
end

function common.deserialize(data: string | buffer)
  local buf = typeof(data) == "string" and buffer.fromstring(data) or data
  local count = buffer.len(buf) / 8

  local ids = {}

  for i = 0, count - 1 do
    table.insert(ids, buffer.readf64(buf, i * 8))
  end

  return ids
end

function common.isLocalFlipbook(ref: Instance)
  if not RunService:IsStudio() then
    return false
  end

  for _, tag in CollectionService:GetTags(ref) do
    if tag:match("^_local_flipbook_") then
      return true
    end
  end

  return false
end

function common.getTexturePrefix(ref: Instance)
  return common.isLocalFlipbook(ref) and "rbxtemp://" or "rbxassetid://"
end

function common.getFlipbookData(ref: Instance): { number }?
  if not attr.get(ref, "FlipbookEnabled", false, true) then
    return nil
  end

  local data = attr.get(ref, "FlipbookTextures", nil, true)

  if not data then
    return nil
  end

  local frames = common.deserialize(data)

  if #frames == 0 then
    return nil
  end

  return frames
end

export type FlipbookConfig = {
  ref: Instance,
  curve: string,

  duration: number,
  effectDuration: number,
  syncDuration: boolean?,

  frames: { number },

  setTexture: (texture: string) -> (),
}

function common.getChangeDuration(config: FlipbookConfig)
  local changeDuration = config.duration

  if config.syncDuration then
    changeDuration = config.effectDuration
  end

  return changeDuration
end

-- one cycle's length, how many cycles play and how long they take, 0 cycles
-- repeating with no end and taking no time of their own. `own` is
-- the flipbook's own cycle and `span` the effect's duration, which synced
-- cycles share, so an endless loop counts as one there
function common.cycles(own: number, span: number, sync: boolean, loop: boolean, count: number): (number, number, number)
  const cycles = if loop then math.max(math.floor(count), 0) else 1

  if not sync then
    return own, cycles, own * cycles
  end

  const shared = math.max(cycles, 1)

  return span / shared, shared, span
end

export type mode = "OneShot" | "Loop" | "PingPong"

-- where in its cycle a flipbook stands `elapsed` seconds in, 0 to 1, held at
-- 1 once the last of `cycles` ends, or at 0 for a PingPong, whose cycle is the
-- round trip and which ends where it began. `start` is how far into the cycle
-- it starts, 0 to 1
function common.phase(elapsed: number, cycle: number, cycles: number, mode: mode?, start: number?): number
  const pingpong = mode == "PingPong"
  const held = if pingpong then 0 else 1

  if cycle <= 0 then
    return held
  end

  local t = elapsed / cycle

  if cycles > 0 and t >= cycles then
    if not start or start == 0 then
      return held
    end

    t = cycles
  end

  if start then
    t += start
  end

  return t - math.floor(t)
end

-- the cycles an endless loop has played once the cycle playing `elapsed`
-- seconds in ends, the count it stops at when it is switched off then
function common.stopped(elapsed: number, cycle: number): number
  return math.floor(elapsed / cycle) + 1
end

-- the frames a cycle of `count` steps through, a PingPong one there and back
-- without showing either end twice
function common.steps(count: number, mode: mode?): number
  return if mode == "PingPong" then math.max(2 * count - 2, 1) else count
end

-- the frame of `count` that step `step` of a cycle of `steps` shows, a PingPong
-- cycle running up the frames and back down
function common.fold(step: number, count: number, steps: number): number
  return if step < count then step + 1 else steps - step + 1
end

-- the frame a flipbook of `count` shows at `alpha` through its cycle. a
-- PingPong one is cut into equal steps, since rounding would hold its first
-- frame for most of a turn
function common.pick(count: number, alpha: number, mode: mode?): number
  if mode ~= "PingPong" then
    return frames_common.index(count, alpha)
  end

  const steps = common.steps(count, mode)

  return common.fold(math.min(math.floor(alpha * steps), steps - 1), count, steps)
end

-- the frame of `count` shown `elapsed` seconds in at `rate` frames a second,
-- held at the last once `cycles` cycles have played. `offset` is the frames
-- a cycle starts in, which a counted loop wraps round, and a PingPong held
-- where it began
function common.frame(
  elapsed: number,
  rate: number,
  count: number,
  cycles: number,
  mode: mode?,
  reverse: boolean?,
  offset: number?
): number
  if mode == nil and not reverse and not offset then
    -- a cycle of no length, such as one synced to an instant effect
    if not (rate < math.huge) then
      return count
    end

    const played = math.floor(elapsed * rate)

    if cycles > 0 and played >= count * cycles then
      return count
    end

    return played % count + 1
  end

  const steps = common.steps(count, mode)
  const total = steps * math.max(cycles, 1)

  local played = if rate < math.huge then math.floor(elapsed * rate) else total

  if not (rate < math.huge) or (cycles > 0 and played >= total) then
    played = if mode == "PingPong" then 0 else total - 1
  end

  const index = common.fold((played + (offset or 0)) % steps, count, steps)

  return if reverse then count + 1 - index else index
end

function common.createUpdateCallback(config: FlipbookConfig)
  local prefix = common.getTexturePrefix(config.ref)

  return function(alpha: number)
    local index = math.max(math.round(#config.frames * alpha), 1)
    config.setTexture(`{prefix}{config.frames[index]}`)
  end
end

return common
