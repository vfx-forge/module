local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")

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
-- repeating until the effect ends and taking no time of their own. `own` is
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

-- where in its cycle a flipbook stands `elapsed` seconds in, 0 to 1, held at
-- 1 once the last of `cycles` ends
function common.phase(elapsed: number, cycle: number, cycles: number): number
  if cycle <= 0 then
    return 1
  end

  const t = elapsed / cycle

  if cycles > 0 and t >= cycles then
    return 1
  end

  return t - math.floor(t)
end

-- the frame of `count` shown `elapsed` seconds in at `rate` frames a second,
-- held at the last once `cycles` cycles have played
function common.frame(elapsed: number, rate: number, count: number, cycles: number): number
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

function common.createUpdateCallback(config: FlipbookConfig)
  local prefix = common.getTexturePrefix(config.ref)

  return function(alpha: number)
    local index = math.max(math.round(#config.frames * alpha), 1)
    config.setTexture(`{prefix}{config.frames[index]}`)
  end
end

return common
