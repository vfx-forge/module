local logger = require("@mod/logger")
local scheduler = require("@mod/scheduler")

local mover = {}

local pending: { [BasePart]: CFrame } = {}
local holders: { [BasePart]: any } = {}

local parts: { BasePart } = {}
local cframes: { CFrame } = {}

-- how a batch reaches the engine, replaceable so a spec can stand one in
function mover.bulk(list: { BasePart }, targets: { CFrame })
  workspace:BulkMoveTo(list, targets, Enum.BulkMoveMode.FireCFrameChanged)
end

-- a pooled part moves only for the effect holding it, so a write a finished
-- effect makes late never lands on the part's next holder
function mover.move(scope: any?, part: BasePart, cframe: CFrame)
  local holder = holders[part]

  -- only the pool assigns a holder, and only to a part
  if holder == nil then
    if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
      logger.warn(`only a BasePart can be moved, not {typeof(part)}`)
      return
    end
  elseif holder ~= scope then
    return
  end

  pending[part] = cframe
end

function mover.cframe(part: BasePart)
  return pending[part] or part.CFrame
end

-- a move made while the part had no holder belongs to nobody it now has
function mover.assign(part: BasePart, holder: any)
  holders[part] = holder
  pending[part] = nil
end

function mover.drop(part: BasePart)
  holders[part] = nil
  pending[part] = nil
end

-- the batch is taken out before it is sent, so one the engine refuses is not
-- sent again every frame
function mover.flush()
  if next(pending) == nil then
    return
  end

  for part, cframe in pending do
    table.insert(parts, part)
    table.insert(cframes, cframe)
  end

  table.clear(pending)

  local ok, err = pcall(mover.bulk, parts, cframes)

  table.clear(parts)
  table.clear(cframes)

  if not ok then
    logger.warn(`a batch of moves failed with error: {err}`)
  end
end

function mover.clear()
  table.clear(pending)
  table.clear(holders)
end

scheduler.after = mover.flush

return mover
