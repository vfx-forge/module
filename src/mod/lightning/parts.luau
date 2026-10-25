const gradient = require("@mod/lightning/gradient")
const geometry = require("@mod/lightning/geometry")

type piece = { part: Part, size: Vector3, transparency: number }
type segment = { from: number, u: number, fade: number, color: Color3, glowColor: Color3, core: piece, glow: piece? }
export type PartsDrawn = {
  segments: { segment },
  keys: { gradient.key },
  heat: number,
  glowing: boolean,
  strength: number,
  moved: { BasePart },
  frames: { CFrame },
}
type looks = {
  glow: boolean,
  heat: number,
  strength: number,
  keys: { gradient.key },
  longest: number,
  restart: boolean,
  holder: Instance,
}
type state = { width: number, glow: number, opacity: number }

const TINY = 1e-6
const WHITE = Color3.new(1, 1, 1)
const GLOW_WIDTH = geometry.GLOW.scale / geometry.CORE.scale

const parts = {}

const function make(sdk: any, ctx: any, name: string, color: Color3, parent: Instance): piece
  const part = Instance.new("Part")

  sdk.hold(ctx, part)

  part.Name = name
  part.Archivable = false
  part.Locked = true
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false
  part.Material = Enum.Material.Neon
  part.Color = color
  part.Transparency = 1
  part.Parent = parent

  return { part = part, size = part.Size, transparency = 1 }
end

-- a core takes the bolt's color at its middle whitened by Heat, leaning back toward that color where the glow fades
-- out at the ends, and its glow the bolt's color as it is, looked at only when the gradient may have changed
const function tint(drawn: PartsDrawn, segment: segment, withGlow: boolean)
  const lean = gradient.lean(drawn.strength, segment.fade, 0)
  const shade = gradient.core(drawn.keys, segment.u, drawn.heat, lean)

  if segment.color ~= shade then
    segment.color = shade
    segment.core.part.Color = shade
  end

  const glowPiece = segment.glow

  if not glowPiece or not withGlow then
    return
  end

  const glowShade = gradient.color(drawn.keys, segment.u)

  if segment.glowColor ~= glowShade then
    segment.glowColor = glowShade
    glowPiece.part.Color = glowShade
  end
end

-- the cores go in the caller's holder, which a Highlight can adorn; the glows stay outside it in the effect's container; each core
-- and glow takes the gradient where its segment sat along the bolt as it was made, so a reshape never recolors it
function parts.build(sdk: any, ctx: any, joints: { geometry.Joint }, perChain: { number }, looks: looks): PartsDrawn
  const drawn: PartsDrawn = {
    segments = {},
    keys = looks.keys,
    heat = looks.heat,
    glowing = looks.glow,
    strength = if looks.glow then looks.strength else 0,
    moved = {},
    frames = {},
  }
  const longest = looks.longest
  local base = 0

  for _, count in perChain do
    const start = if count > 0 then joints[base + 1].arc else 0

    for j = 1, count - 1 do
      const from = base + j
      const middle = (joints[from].arc + joints[from + 1].arc) / 2
      const segment = {
        from = from,
        u = geometry.u(middle, start, longest, looks.restart),
        fade = (joints[from].fade + joints[from + 1].fade) / 2,
        color = WHITE,
        glowColor = WHITE,
        core = make(sdk, ctx, "LightningCore", WHITE, looks.holder),
        glow = if looks.glow then make(sdk, ctx, "LightningGlow", WHITE, sdk.container(ctx)) else nil,
      }

      tint(drawn, segment, true)
      table.insert(drawn.segments, segment)
    end

    base += count
  end

  return drawn
end

const function show(piece: piece, transparency: number)
  if piece.transparency ~= transparency then
    piece.transparency = transparency
    piece.part.Transparency = transparency
  end
end

const function resize(piece: piece, width: number, length: number)
  -- each end runs on by a quarter width so the blocks overlap where the path bends
  const size = Vector3.new(width, width, length + width / 2)

  if piece.size ~= size then
    piece.size = size
    piece.part.Size = size
  end
end

-- a core part beside its glow part drew no step leaving 0 for 0.02 or 0.05, so Segments takes no tint
-- (measured 2026-10-24)
const function fade(segment: segment, a: geometry.Joint, b: geometry.Joint, state: state, glow: number)
  show(segment.core, 1 - state.opacity)

  if segment.glow then
    show(segment.glow, 1 - geometry.GLOW.alpha * glow * state.glow * state.opacity * (a.fade + b.fade) / 2)
  end
end

-- reshaped is false when only the fade or the glow changed since the last draw, so nothing is placed again
function parts.draw(drawn: PartsDrawn, joints: { geometry.Joint }, state: state, glow: number, reshaped: boolean)
  const strength = if drawn.glowing then math.clamp(glow * state.glow, 0, 1) else 0

  if strength ~= drawn.strength then
    drawn.strength = strength

    for _, segment in drawn.segments do
      tint(drawn, segment, false)
    end
  end

  if not reshaped then
    for _, segment in drawn.segments do
      const a = joints[segment.from]
      const b = joints[segment.from + 1]

      if a.w > 0 or b.w > 0 then
        fade(segment, a, b, state, glow)
      end
    end

    return
  end

  const moved = drawn.moved
  const frames = drawn.frames
  local count = 0

  for _, segment in drawn.segments do
    const a = joints[segment.from]
    const b = joints[segment.from + 1]
    const glowPiece = segment.glow

    if a.w == 0 and b.w == 0 then
      show(segment.core, 1)

      if glowPiece then
        show(glowPiece, 1)
      end

      continue
    end

    const length = vector.magnitude(b.p - a.p)
    const middle = (a.p + b.p) / 2
    const frame = if length < TINY then CFrame.new(middle) else CFrame.lookAt(middle, b.p)
    const width = (a.w + b.w) / 2

    resize(segment.core, width * state.width, length)
    fade(segment, a, b, state, glow)

    count += 1
    moved[count] = segment.core.part
    frames[count] = frame

    if glowPiece then
      resize(glowPiece, width * state.width * GLOW_WIDTH, length)

      count += 1
      moved[count] = glowPiece.part
      frames[count] = frame
    end
  end

  for i = count + 1, #moved do
    moved[i] = nil
    frames[i] = nil
  end

  workspace:BulkMoveTo(moved, frames, Enum.BulkMoveMode.FireCFrameChanged)
end

-- a finished bolt's drawing goes at once, while the nested effects its emit waits for still play
function parts.free(drawn: PartsDrawn)
  for _, segment in drawn.segments do
    segment.core.part:Destroy()

    if segment.glow then
      segment.glow.part:Destroy()
    end
  end
end

-- keys are the Color gradient sampled anew and heat the Heat row, each nil when it held; a part is written only when
-- its color changed, and a glow is looked at only when the gradient did
function parts.paint(drawn: PartsDrawn, keys: { gradient.key }?, heat: number?)
  drawn.keys = keys or drawn.keys
  drawn.heat = heat or drawn.heat

  for _, segment in drawn.segments do
    tint(drawn, segment, keys ~= nil)
  end
end

return parts
