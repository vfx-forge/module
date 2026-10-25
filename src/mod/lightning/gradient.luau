export type key = { t: number, r: number, g: number, b: number }

const gradient = {}

function gradient.sample(keys: { key }, u: number): (number, number, number)
  const count = #keys

  if count == 0 then
    return 1, 1, 1
  end

  if count == 1 or u <= keys[1].t then
    return keys[1].r, keys[1].g, keys[1].b
  end

  for i = 2, count do
    const after = keys[i]

    if u <= after.t then
      const before = keys[i - 1]
      const span = after.t - before.t
      const f = if span > 0 then (u - before.t) / span else 1

      return before.r + (after.r - before.r) * f,
        before.g + (after.g - before.g) * f,
        before.b + (after.b - before.b) * f
    end
  end

  const last = keys[count]

  return last.r, last.g, last.b
end

const WHITE = Color3.new(1, 1, 1)

-- the bolt's color at a place along it, which the glow takes as it is
function gradient.color(keys: { key }, u: number)
  return Color3.new(gradient.sample(keys, u))
end

-- how far a core vertex leans toward the glow's color: by the glow's strength as much as the glow's fade took off at
-- the ends, then by the tint the shell lays over the core under a Fade where the glow still shows
function gradient.lean(strength: number, fade: number, tint: number)
  return 1 - (1 - strength * (1 - fade)) * (1 - tint * fade)
end

-- a core vertex's color: the bolt's color whitened by Heat, less as far as it leans back toward the glow, which is
-- that color as it is
function gradient.core(keys: { key }, u: number, heat: number, lean: number)
  return gradient.color(keys, u):Lerp(WHITE, math.clamp(heat, 0, 1) * (1 - math.clamp(lean, 0, 1)))
end

-- one color per place along the bolt, in the layout geometry.along writes
function gradient.colors(keys: { key }, along: { number }, out: { Color3 })
  for k, u in along do
    out[k] = gradient.color(keys, u)
  end

  for k = #along + 1, #out do
    out[k] = nil
  end

  return out
end

return gradient
