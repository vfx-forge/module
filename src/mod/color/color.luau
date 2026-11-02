--!native
--!optimize 2
local Oklab = require("@mod/color/Oklab")

-- the vendored modules stay as their author wrote them. two of their comments
-- are swapped: sRGB's `transform` turns an sRGB channel into a linear one and
-- `inverse` a linear channel into an sRGB one, the opposite of what each says
local color = {}

-- a Color3 in Oklab, as a Vector3 of lightness and its two hues
function color.toOklab(c: Color3): Vector3
  return Oklab.fromSRGB(c)
end

-- an Oklab Vector3 back as a Color3, clamped into range unless `unclamped`
function color.fromOklab(lab: Vector3, unclamped: boolean?): Color3
  return Oklab.toSRGB(lab, unclamped)
end

-- whether an Oklab Vector3 is a color sRGB can hold, so a clamp would leave it
-- where it is
function color.inGamut(lab: Vector3): boolean
  local linear = Oklab.toLinear(lab, true)

  return linear.R >= 0 and linear.R <= 1 and linear.G >= 0 and linear.G <= 1 and linear.B >= 0 and linear.B <= 1
end

-- `t` of the way from `a` to `b`, blended in Oklab so the middle keeps the
-- lightness of its ends
function color.blend(a: Color3, b: Color3, t: number, unclamped: boolean?): Color3
  return Oklab.toSRGB(Oklab.fromSRGB(a):Lerp(Oklab.fromSRGB(b), t), unclamped)
end

-- a sequence's color at `time`, blended in Oklab between the keypoints on
-- either side of it
function color.sequenceAt(sequence: ColorSequence, time: number): Color3
  local keypoints = sequence.Keypoints
  local first = keypoints[1]
  local last = keypoints[#keypoints]

  if time <= first.Time then
    return first.Value
  end

  if time >= last.Time then
    return last.Value
  end

  for i = 2, #keypoints do
    local above = keypoints[i]

    if above.Time >= time then
      local below = keypoints[i - 1]

      if above.Time == time then
        return above.Value
      end

      return color.blend(below.Value, above.Value, (time - below.Time) / (above.Time - below.Time))
    end
  end

  return last.Value
end

return color
