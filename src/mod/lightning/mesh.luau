const AssetService = game:GetService("AssetService")

const gradient = require("@mod/lightning/gradient")
const geometry = require("@mod/lightning/geometry")

export type Layer = {
  editable: EditableMesh,
  part: MeshPart,
  vertexIds: { number },
  colorIds: { number },
  positions: { vector },
  alphas: { number },
}
export type Look = {
  keys: { gradient.key },
  along: { number },
  fades: { number },
  colors: { Color3 },
  glowAlong: { number },
  glowColors: { Color3 },
  heat: number,
  strength: number,
  tint: number,
}
export type Drawn = {
  core: Layer,
  glow: Layer?,
  look: Look,
  transparency: number,
  spare: { positions: { vector }, alphas: { number } },
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

-- a part draws in the transparent pass, where vertex alpha shows, only from a Transparency of 0.02 up; 0.01 drew
-- opaque (measured 2026-10-23)
const TRANSPARENT = 0.02
const GLOW_TRANSPARENCY = TRANSPARENT
-- the core rests opaque, so the glow's tint over it shows
const CORE_TRANSPARENCY = 0
const WHITE = Color3.new(1, 1, 1)
const GLOW_PROFILE = table.create(geometry.GLOW.sides, geometry.GLOW.alpha)
const ONES = table.create(geometry.CORE.sides, 1)

const mesh = {}

-- the core's color at each vertex: the bolt's color at how far along the bolt the vertex sits (along its own fork
-- from the fork's root when the color restarts there) whitened by Heat, leaning back toward that color where the glow
-- fades out at the ends, and once the core has left the opaque pass, by the tint the shell laid over it there
const function shade(look: Look)
  const keys = look.keys
  const colors = look.colors
  const fades = look.fades
  const strength = look.strength
  const tint = look.tint

  for k, u in look.along do
    colors[k] = gradient.core(keys, u, look.heat, gradient.lean(strength, fades[k], tint))
  end

  return colors
end

const function make(
  sdk: any,
  ctx: any,
  name: string,
  positions: { vector },
  alphas: { number },
  colors: { Color3 },
  faces: { { number } },
  transparency: number,
  parent: Instance,
  inward: boolean?
): Layer?
  const made, editable = pcall(function()
    return AssetService:CreateEditableMesh()
  end)

  if not made or not editable then
    return nil
  end

  sdk.hold(ctx, function()
    editable:Destroy()
  end)

  const vertexIds = editable:BatchAdd(Enum.MeshAttribute.Vertex, positions)
  const colorIds = editable:BatchAdd(Enum.MeshAttribute.Color, colors, alphas)
  const corners = table.create(#faces)

  for f, face in faces do
    corners[f] = if inward
      then { vertexIds[face[1]], vertexIds[face[3]], vertexIds[face[2]] }
      else { vertexIds[face[1]], vertexIds[face[2]], vertexIds[face[3]] }
  end

  const faceIds = editable:BatchAdd(Enum.MeshAttribute.Face, corners)

  for f, faceId in faceIds do
    const face = faces[f]

    editable:SetFaceColors(
      faceId,
      if inward
        then { colorIds[face[1]], colorIds[face[3]], colorIds[face[2]] }
        else { colorIds[face[1]], colorIds[face[2]], colorIds[face[3]] }
    )
  end

  -- Box fidelity made a 330 vertex bolt's part in 0.22 ms, the default fidelity in 21.7 ms (measured 2026-10-23)
  const done, part = pcall(function()
    return AssetService:CreateMeshPartAsync(
      Content.fromObject(editable),
      { CollisionFidelity = Enum.CollisionFidelity.Box }
    )
  end)

  if not done or not part then
    editable:Destroy()

    return nil
  end

  sdk.hold(ctx, part)

  part.Name = name
  part.Archivable = false
  part.Locked = true
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false
  part.DoubleSided = not inward
  part.Material = Enum.Material.Neon
  part.Color = WHITE
  part.Transparency = transparency
  -- a mesh part keeps its mesh's origin instead of recentering on its bounds, so world space vertices sit at
  -- identity, and vertices moved past the bounds it was made with still draw (measured 2026-10-23)
  part.CFrame = CFrame.identity
  part.Parent = parent

  return {
    editable = editable,
    part = part,
    vertexIds = vertexIds,
    colorIds = colorIds,
    positions = positions,
    alphas = alphas,
  }
end

-- SetColor keeps each color's alpha, so the fades survive a recolor; 310 calls took 0.03 ms (measured 2026-10-23)
const function recolor(drawn: Drawn)
  const core = drawn.core
  const colors = shade(drawn.look)

  for k, id in core.colorIds do
    core.editable:SetColor(id, colors[k])
  end
end

-- the core goes in the caller's holder, which a Highlight can adorn; the glow stays outside it in the effect's container
function mesh.build(sdk: any, ctx: any, joints: { geometry.Joint }, perChain: { number }, looks: looks): Drawn?
  const core = geometry.CORE
  const positions = {}
  const count = geometry.tube(joints, core.sides, core.scale, positions)
  const look: Look = {
    keys = looks.keys,
    along = {},
    fades = {},
    colors = table.create(count),
    glowAlong = {},
    glowColors = {},
    heat = looks.heat,
    strength = if looks.glow then looks.strength else 0,
    tint = 0,
  }

  geometry.along(joints, core.sides, looks.longest, look.along, looks.restart)
  geometry.alphas(joints, ONES, 1, look.fades)

  const coreLayer = make(
    sdk,
    ctx,
    "LightningCore",
    positions,
    table.create(count, 1),
    shade(look),
    geometry.faces(perChain, core.sides, true),
    CORE_TRANSPARENCY,
    looks.holder
  )

  if not coreLayer then
    return nil
  end

  -- a glow the engine has no room for is left out, the core still draws. the shell is drawn inside out and one sided,
  -- so only its far wall shows and the opaque core hides it: drawn both sided, its near wall lay over the core and
  -- Strength read as how tinted the core was rather than how bright the glow was (the owner, 2026-10-24)
  local glowLayer = nil

  if looks.glow then
    const glow = geometry.GLOW
    const shell = {}
    const alphas = {}

    geometry.tube(joints, glow.sides, glow.scale, shell)
    geometry.alphas(joints, GLOW_PROFILE, 1, alphas)
    geometry.along(joints, glow.sides, looks.longest, look.glowAlong, looks.restart)

    glowLayer = make(
      sdk,
      ctx,
      "LightningGlow",
      shell,
      alphas,
      gradient.colors(look.keys, look.glowAlong, look.glowColors),
      geometry.faces(perChain, glow.sides, true),
      GLOW_TRANSPARENCY,
      sdk.container(ctx),
      true
    )
  end

  const drawn: Drawn = {
    core = coreLayer,
    glow = glowLayer,
    look = look,
    transparency = CORE_TRANSPARENCY,
    spare = { positions = {}, alphas = {} },
  }

  if not glowLayer and look.strength > 0 then
    look.strength = 0
    recolor(drawn)
  end

  return drawn
end

const function differs(now: { any }, was: { any }): boolean
  for i, value in now do
    if was[i] ~= value then
      return true
    end
  end

  return false
end

-- the spare buffers hold what was just worked out; a changed one is written and swapped with the layer's own
const function writePositions(drawn: Drawn, layer: Layer)
  const spare = drawn.spare

  if differs(spare.positions, layer.positions) then
    layer.editable:BatchSetValues(layer.vertexIds, spare.positions)
    spare.positions, layer.positions = layer.positions, spare.positions
  end
end

const function writeAlphas(drawn: Drawn, layer: Layer)
  const spare = drawn.spare

  if differs(spare.alphas, layer.alphas) then
    layer.editable:BatchSetValues(layer.colorIds, spare.alphas)
    spare.alphas, layer.alphas = layer.alphas, spare.alphas
  end
end

-- each glow vertex is the bolt's color at the same place along the bolt as the core's vertices at its joint
const function recolorGlow(drawn: Drawn, glowLayer: Layer)
  const look = drawn.look
  const colors = gradient.colors(look.keys, look.glowAlong, look.glowColors)

  for k, id in glowLayer.colorIds do
    glowLayer.editable:SetColor(id, colors[k])
  end
end

-- glow is the Glow row, apart from state.glow, the timeline's own share of it
function mesh.draw(drawn: Drawn, joints: { geometry.Joint }, state: state, glow: number)
  const spare = drawn.spare
  const core = geometry.CORE
  const glowLayer = drawn.glow
  const look = drawn.look
  const transparency = if state.opacity >= 1 then CORE_TRANSPARENCY else math.max(TRANSPARENT, 1 - state.opacity)
  const strength = if glowLayer then math.clamp(glow * state.glow, 0, 1) else 0
  local stale = strength ~= look.strength

  look.strength = strength

  geometry.tube(joints, core.sides, core.scale * state.width, spare.positions)
  writePositions(drawn, drawn.core)

  if transparency ~= drawn.transparency then
    -- Fade is one property write a frame, cheaper than the core's vertex alphas, which stay at 1; it goes from 0
    -- straight to the transparent pass at 0.02, where beside a dark wall the shell's tint over the core went in one
    -- frame (0 and 0.01 drew alike), so on that frame the core's colors take the tint instead; that halved the step
    -- but left a slight cyan shift, a mean pixel change of 1.78 against 3.55 untinted and 0.14 for a repeat
    -- capture of the same frame (measured 2026-10-24)
    const opaque = transparency == CORE_TRANSPARENCY

    if opaque ~= (drawn.transparency == CORE_TRANSPARENCY) then
      const tint = if opaque or not glowLayer then 0 else geometry.GLOW.alpha * glow * state.glow

      if tint ~= look.tint then
        look.tint = tint
        stale = true
      end
    end

    drawn.transparency = transparency
    drawn.core.part.Transparency = transparency
  end

  if stale then
    recolor(drawn)
  end

  if glowLayer then
    const shell = geometry.GLOW

    geometry.tube(joints, shell.sides, shell.scale * state.width, spare.positions)
    geometry.alphas(joints, GLOW_PROFILE, glow * state.glow * state.opacity, spare.alphas)
    writePositions(drawn, glowLayer)
    writeAlphas(drawn, glowLayer)
  end
end

-- keys are the Color gradient sampled anew and heat the Heat row, each nil when it held; the glow takes no Heat, so
-- it is written again only when the gradient changed
function mesh.paint(drawn: Drawn, keys: { gradient.key }?, heat: number?)
  const look = drawn.look

  look.keys = keys or look.keys
  look.heat = heat or look.heat
  recolor(drawn)

  const glowLayer = drawn.glow

  if not glowLayer or not keys then
    return
  end

  recolorGlow(drawn, glowLayer)
end

const function free(layer: Layer?)
  if not layer then
    return
  end

  layer.part:Destroy()
  layer.editable:Destroy()
end

-- a finished bolt's drawing goes at once, while the nested effects its emit waits for still play
function mesh.free(drawn: Drawn)
  free(drawn.core)
  free(drawn.glow)
end

function mesh.move(drawn: Drawn, cframe: CFrame)
  drawn.core.part.CFrame = cframe

  if drawn.glow then
    drawn.glow.part.CFrame = cframe
  end
end

return mesh
