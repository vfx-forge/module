local color = require("@mod/color/color")
local logger = require("@mod/logger")

-- the most keypoints the engine takes in a sequence
local ENGINE_KEYPOINTS = 20

local lerp = {}

-- a blend past the limit is told once a session, not once a frame
local warned = false

function lerp.number(a: number, b: number, t: number)
  return a + (b - a) * t
end

function lerp.Vector3(a: Vector3, b: Vector3, t: number)
  return a:Lerp(b, t)
end

function lerp.Vector2(a: Vector2, b: Vector2, t: number)
  return a:Lerp(b, t)
end

function lerp.CFrame(a: CFrame, b: CFrame, t: number)
  return a:Lerp(b, t)
end

function lerp.UDim2(a: UDim2, b: UDim2, t: number)
  return a:Lerp(b, t)
end

function lerp.UDim(a: UDim, b: UDim, t: number)
  -- stylua: ignore
  return UDim.new(
    lerp.number(a.Scale, b.Scale, t),
    lerp.number(a.Offset, b.Offset, t)
  )
end

function lerp.NumberRange(a: NumberRange, b: NumberRange, t: number)
  -- stylua: ignore
  return NumberRange.new(
    lerp.number(a.Min, b.Min, t),
    lerp.number(a.Max, b.Max, t)
  )
end

function lerp.Color3(a: Color3, b: Color3, t: number)
  return color.blend(a, b, t)
end

function lerp.PhysicalProperties(a: PhysicalProperties, b: PhysicalProperties, t: number)
  return PhysicalProperties.new(
    lerp.number(a.Density, b.Density, t),
    lerp.number(a.Friction, b.Friction, t),
    lerp.number(a.Elasticity, b.Elasticity, t),
    lerp.number(a.FrictionWeight, b.FrictionWeight, t),
    lerp.number(a.ElasticityWeight, b.ElasticityWeight, t)
  )
end

function lerp.Rect(a: Rect, b: Rect, t: number)
  return Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t))
end

-- credit https://github.com/boatbomber/BoatTween
function lerp.NumberSequence(a: NumberSequence, b: NumberSequence, t: number)
  local keypoints = {}
  local addedTimes = {}

  local keylength = 0

  for _, ap in a.Keypoints do
    local closestAbove, closestBelow

    for _, bp in b.Keypoints do
      if bp.Time == ap.Time then
        closestAbove, closestBelow = bp, bp
        break
      elseif bp.Time < ap.Time and (closestBelow == nil or bp.Time > closestBelow.Time) then
        closestBelow = bp
      elseif bp.Time > ap.Time and (closestAbove == nil or bp.Time < closestAbove.Time) then
        closestAbove = bp
      end
    end

    local bValue, bEnvelope

    if closestAbove == closestBelow then
      bValue, bEnvelope = closestAbove.Value, closestAbove.Envelope
    else
      local p = (ap.Time - closestBelow.Time) / (closestAbove.Time - closestBelow.Time)
      bValue = (closestAbove.Value - closestBelow.Value) * p + closestBelow.Value
      bEnvelope = (closestAbove.Envelope - closestBelow.Envelope) * p + closestBelow.Envelope
    end

    keylength += 1
    keypoints[keylength] = NumberSequenceKeypoint.new(
      ap.Time,
      (bValue - ap.Value) * t + ap.Value,
      (bEnvelope - ap.Envelope) * t + ap.Envelope
    )

    addedTimes[ap.Time] = true
  end

  for _, bp in b.Keypoints do
    if not addedTimes[bp.Time] then
      local closestAbove, closestBelow

      for _, ap in a.Keypoints do
        if ap.Time == bp.Time then
          closestAbove, closestBelow = ap, ap
          break
        elseif ap.Time < bp.Time and (closestBelow == nil or ap.Time > closestBelow.Time) then
          closestBelow = ap
        elseif ap.Time > bp.Time and (closestAbove == nil or ap.Time < closestAbove.Time) then
          closestAbove = ap
        end
      end

      local aValue, aEnvelope

      if closestAbove == closestBelow then
        aValue, aEnvelope = closestAbove.Value, closestAbove.Envelope
      else
        local p = (bp.Time - closestBelow.Time) / (closestAbove.Time - closestBelow.Time)
        aValue = (closestAbove.Value - closestBelow.Value) * p + closestBelow.Value
        aEnvelope = (closestAbove.Envelope - closestBelow.Envelope) * p + closestBelow.Envelope
      end

      keylength += 1
      keypoints[keylength] =
        NumberSequenceKeypoint.new(bp.Time, (bp.Value - aValue) * t + aValue, (bp.Envelope - aEnvelope) * t + aEnvelope)
    end
  end

  table.sort(keypoints, function(a, b)
    return a.Time < b.Time
  end)

  local finalKeypoints

  if #keypoints > ENGINE_KEYPOINTS then
    if not warned then
      warned = true
      logger.warn(
        `a NumberSequence blend has {#keypoints} keypoints, past the engine's {ENGINE_KEYPOINTS}; {ENGINE_KEYPOINTS} spread over them are kept`
      )
    end

    finalKeypoints = {}
    local step = (#keypoints - 1) / (ENGINE_KEYPOINTS - 1)

    for i = 0, ENGINE_KEYPOINTS - 1 do
      local index = math.floor(i * step + 1)
      table.insert(finalKeypoints, keypoints[index])
    end

    if finalKeypoints[#finalKeypoints].Time < keypoints[#keypoints].Time then
      finalKeypoints[#finalKeypoints] = keypoints[#keypoints]
    end
  else
    finalKeypoints = keypoints
  end

  return NumberSequence.new(finalKeypoints)
end

-- each of b's keypoints blended from a's color at its time, as
-- color.blend(color.sequenceAt(a, time), value, t) reads it. a's keypoints go
-- to Oklab once per call rather than twice per keypoint of b, and since b's
-- times run forward the search for the pair either side of one does too
function lerp.ColorSequence(a: ColorSequence, b: ColorSequence, t: number)
  local from = a.Keypoints
  local into = b.Keypoints
  local count = #from
  local labs = table.create(count)
  local keypoints = table.create(#into)

  for i, kp in from do
    labs[i] = color.toOklab(kp.Value)
  end

  local first = from[1].Time
  local last = from[count].Time
  local above = 2

  for i, bp in into do
    local time = bp.Time
    local at: Vector3

    if time <= first then
      at = labs[1]
    elseif time >= last then
      at = labs[count]
    else
      while from[above].Time < time do
        above += 1
      end

      local high = from[above].Time

      if high == time then
        at = labs[above]
      else
        local low = from[above - 1].Time

        at = labs[above - 1]:Lerp(labs[above], (time - low) / (high - low))

        -- sequenceAt hands its blend back as a Color3 clamped into range, so
        -- a middle that leaves the gamut is read from where it lands
        if not color.inGamut(at) then
          at = color.toOklab(color.fromOklab(at))
        end
      end
    end

    keypoints[i] = ColorSequenceKeypoint.new(time, color.fromOklab(at:Lerp(color.toOklab(bp.Value), t)))
  end

  return ColorSequence.new(keypoints)
end

function lerp.Other(a: any, b: any, t: number)
  -- NOT `t < 0.5 and a or b`: that's the classic Lua ternary pitfall, since
  -- when `a` is falsy (`false`/`nil`, both valid discrete values here), `X and
  -- a` is itself falsy, so the `or b` branch wins regardless of `t`.
  if t < 0.5 then
    return a
  end
  return b
end

-- dispatches on the type of `a` to the matching lerp above, falling back to
-- lerp.Other for anything with no typed lerp of its own
function lerp.any(a: any, b: any, t: number)
  local fn = (lerp :: any)[typeof(a)]

  if fn then
    return fn(a, b, t)
  end

  return lerp.Other(a, b, t)
end

return lerp
