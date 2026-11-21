local mods = require("@mod/mods")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local emitters = require("@root/emitters")

type Run = { stop: (() -> ())?, before: Run?, ended: boolean? }

-- the run each target's property is under, newest emit first: a new run takes
-- the property over and stops the ones before it, so one target property is
-- never driven twice by animators, re-emitted or cloned alike. an entry goes
-- once its run ends, since a run holds its target and a weak key it reaches
-- is never let go
local RUNS = setmetatable({} :: { [Instance]: { [string]: Run } }, { __mode = "k" })

-- the instance driven: the Target row, else the parent the way a legacy
-- tween child finds its own
local function targetOf(ref: Instance, attrs: any): Instance?
  if attrs.Target ~= nil then
    return attrs.Target
  end

  return utility.getTarget(ref)
end

-- the effect the animator sits under, past Folders, whose end its end lane
-- is placed against. one in a folder its effect emits as it ends has none:
-- it starts once that end has passed
local function hostOf(ref: Instance): Instance?
  local parent = ref.Parent

  while parent ~= nil and parent:IsA("Folder") do
    if parent.Name == utility.EMIT_ON_FINISH then
      return nil
    end

    parent = parent.Parent
  end

  return parent
end

local function playable(queue: { any }?): { any }?
  if queue == nil or #queue == 0 or mods.inert(queue) then
    return nil
  end

  return queue
end

-- the start lane, and the end lane with the span left to place it against:
-- the host's, less the delay it waited, and none without a host
local function lanesOf(ref: Instance, scope: any, attrs: any): ({ any }?, { any }?, number?)
  if attrs.Property == "" then
    return nil, nil, nil
  end

  local lanes = mods.read(ref, "property", attrs.Property)

  if lanes == nil then
    return nil, nil, nil
  end

  local finish = playable(lanes["end"])
  local span = if finish ~= nil and scope ~= nil then emitters.hostSpan(scope, hostOf(ref)) else nil

  if span == nil then
    finish = nil
  end

  return playable(lanes.start), finish, if span ~= nil then math.max(span - attrs.EmitDelay, 0) else nil
end

-- a run that holds nothing any more hands the property back to the newest
-- run under it still playing
local function letGo(target: Instance, runs: { [string]: Run }, name: string, handle: Run)
  handle.ended = true

  if runs[name] == handle then
    local back = handle.before

    while back ~= nil and back.ended do
      back = back.before
    end

    runs[name] = back
  end

  if next(runs) == nil and RUNS[target] == runs then
    RUNS[target] = nil
  end
end

local play = {}

function play.duration(ctx: reader.Ctx, attrs: any)
  local start, finish, span = lanesOf(ctx.ref, ctx.scope, attrs)
  local reach = if start ~= nil then mods.span(start, 1) else 0

  if finish ~= nil and span ~= nil then
    reach = math.max(reach, span)
  end

  return attrs.EmitDelay + reach
end

function play.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref
  local scope = ctx.scope
  local name = attrs.Property
  local target = targetOf(ref, attrs)
  local start, finish, span = lanesOf(ref, scope, attrs)

  if (start == nil and finish == nil) or target == nil then
    return
  end

  lifetime.wait(scope, attrs.EmitDelay)

  -- an end lane plays against the span left, so the row is built whole
  local track = nil

  if finish ~= nil and span ~= nil then
    local ok, current = pcall(function()
      return (target :: any)[name]
    end)

    track = mods.track(ref, "property", name, nil, span, nil, { value = if ok then current else nil })
  end

  local runs = RUNS[target]

  if runs == nil then
    runs = {}
    RUNS[target] = runs
  end

  -- the runs before this one, newest first: a run that never wrote still
  -- links the ones under it, so a takeover reaches every one
  local handle: Run = { stop = nil, before = runs[name], ended = false }

  runs[name] = handle

  emitters.drive(target, "property", name, start or {}, scope, 1, {
    rule = if attrs.ResetOnFinish then nil else "keep",
    track = track,

    -- the runs before this one end only once this one holds the property, so
    -- the target never goes back for a frame in between
    took = function()
      local older = handle.before
      handle.before = nil

      while older ~= nil do
        if older.stop ~= nil then
          older.stop()
        end

        older = older.before
      end
    end,

    handle = handle,

    ended = function()
      letGo(target, runs, name, handle)
    end,
  })

  -- a run the driver turned down holds nothing, and hands the property back
  -- to the one before it
  if handle.stop == nil then
    letGo(target, runs, name, handle)
  end
end

return play
