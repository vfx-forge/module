-- run through the VFX Forge MCP's studio_execute_luau with each paste line replaced by that module's text, and
-- comment lines, blank lines and indentation stripped so the paste stays small:
-- gawk 'match($0, /^ *--@paste ([a-z_]+)$/, m) { f = "src/mod/lightning/" m[1] ".luau"; while ((getline l < f) > 0) { sub(/^export type/, "type", l); print l }; next } { print }' tests/forge_lightning_studio/draw_check.luau | grep -v -E '^\s*(--.*)?$' | sed -E 's/^\s+//'
-- the sandbox can neither require a ModuleScript it made nor parent into the place, so each module is pasted as a
-- function body (export is top level only, hence the gawk sub), script and require are shadowed below, and mesh and
-- parts take a stand-in workspace whose Terrain is a Folder of the check's own
-- a module whose file does not exist yet is left empty, so its require fails by name
-- nothing is placed: everything made is held and destroyed before the call answers; any FAIL raises with the whole
-- output

const AssetService = game:GetService("AssetService")

const modules = {}

const script = {
  Parent = setmetatable({}, {
    __index = function(_, name: string)
      return name
    end,
  }),
}

const function require(name: string): any
  const found = modules[name]

  if found == nil then
    error(`no module {name}`, 2)
  end

  return found
end

modules.rng = (function()
  --@paste rng
end)()

modules.path = (function()
  --@paste path
end)()

modules.geometry = (function()
  --@paste geometry
end)()

modules.gradient = (function()
  --@paste gradient
end)()

-- mesh and parts read game and workspace when they load, so each load takes its own
const function loadMesh(game: any, workspace: any)
  --@paste mesh
end

const function loadParts(workspace: any)
  --@paste parts
end

const ORIGIN = vector.create(-300, 2, -300)
const FINISH = vector.create(-300, 44, -300)
const SHIFT = vector.create(22, 0, 0)
const TOLERANCE = 1e-3
-- the core rests opaque and its first faded frame goes straight to the transparent pass at 0.02
const CORE_REST = 0
const TRANSPARENT = 0.02
const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const NEAR_VERTICAL = math.cos(math.rad(25))
const COLOR_TOLERANCE = 1.5 / 255
const RED = { t = 0, r = 1, g = 0, b = 0 }
const BLUE = { t = 1, r = 0, g = 0, b = 1 }
const GREEN = { t = 0, r = 0, g = 1, b = 0 }
const WHITE = Color3.new(1, 1, 1)

const held = {}
const lines = {}
local failed = false

const sdk = {
  hold = function(_, thing)
    table.insert(held, thing)

    return thing
  end,
}

const function check(what: string, ok: boolean, detail: string?)
  if ok then
    table.insert(lines, `ok {what}`)
  else
    failed = true
    table.insert(lines, `FAIL {what}{if detail then `: {detail}` else ""}`)
  end
end

const function near(a: vector, b: vector): boolean
  return vector.magnitude(a - b) < TOLERANCE
end

const function colorNear(a: Color3, r: number, g: number, b: number): boolean
  return math.abs(a.R - r) < COLOR_TOLERANCE
    and math.abs(a.G - g) < COLOR_TOLERANCE
    and math.abs(a.B - b) < COLOR_TOLERANCE
end

-- a color's alpha is kept as a byte, min(255, floor(a * 256)), and read back over 255, so 0.035 reads 8 / 255
-- and 0.5 reads 128 / 255 (measured 2026-10-23)
const function alphaNear(read: number, want: number): boolean
  return math.abs(read - math.min(255, math.floor(want * 256)) / 255) < 1e-6
end

-- the first vertex of joint i's ring: each chain before it adds its two cap points after its rings
const function ringStart(joints: { any }, i: number, sides: number): number
  return (i - 1) * sides + 2 * (joints[i].chain - 1)
end

const function run()
  const terrain = sdk.hold(nil, Instance.new("Folder"))
  const holder = sdk.hold(nil, Instance.new("Model"))
  const stage = {
    Terrain = terrain,
    BulkMoveTo = function(_, ...)
      return workspace:BulkMoveTo(...)
    end,
  }

  terrain.Name = "Terrain"

  const rng = require("rng")
  const path = require("path")
  const geometry = require("geometry")
  const gradient = require("gradient")
  const mesh = loadMesh(game, stage)

  const next = rng.generator(7)
  const shape = path.make(next, { detail = 16, forks = 5, forkLength = 0.5, jagged = 0.15 })
  const fitted = path.fit(shape, ORIGIN, FINISH)
  const joints = geometry.joints(shape, fitted, 0.7, 0.3)
  const perChain = {}
  local total = 0
  local segments = 0
  local longest = 0
  local farthest = 1

  for c, chain in fitted do
    perChain[c] = #chain
    total += #chain
    segments += #chain - 1
  end

  for i, joint in joints do
    if joint.arc > longest then
      longest = joint.arc
      farthest = i
    end
  end

  const chains = #perChain

  table.insert(lines, `chains {chains}, joints {total}, segments {segments}`)

  -- a bolt made with no glow strength yet, so its first colors lean nowhere
  const looks = {
    glow = true,
    heat = 0.5,
    strength = 0,
    keys = { RED, BLUE },
    longest = longest,
    holder = holder,
  }
  const started = os.clock()
  const built, drawn = pcall(mesh.build, sdk, {}, joints, perChain, looks)

  table.insert(lines, `mesh.build {string.format("%.2f", (os.clock() - started) * 1000)} ms`)
  check("mesh.build answers a bolt", built and drawn ~= nil, if built then nil else tostring(drawn))

  if built and drawn then
    const expected = {
      core = { total * 5 + chains * 2, segments * 10 + chains * 10, CORE_REST, holder },
      glow = { total * 6 + chains * 2, segments * 12 + chains * 12, 0.02, terrain },
    }

    for _, name in { "core", "glow" } do
      const layer = drawn[name]

      if layer then
        const want = expected[name]
        const vertices = #layer.vertexIds
        const faces = #layer.editable:GetFaces()
        const transparency = layer.part.Transparency

        check(`{name} vertices {vertices}`, vertices == want[1], `want {want[1]}`)
        check(`{name} faces {faces}`, faces == want[2], `want {want[2]}`)
        check(
          `{name} transparency {string.format("%.3f", transparency)}`,
          math.abs(transparency - want[3]) < 1e-6,
          `want {want[3]}`
        )
        check(`{name} part sits under {want[4].ClassName}`, layer.part.Parent == want[4], `{layer.part.Parent}`)
      else
        check(`{name} layer made`, false)
      end
    end

    check("no rim layer", drawn.rim == nil)

    const core = drawn.core
    const glow = drawn.glow

    -- the caps close both ends of the main bolt: a ray along its axis, a little off center, from just outside
    -- each end to just inside its first ring meets the core's own triangles
    for _, at in { { "origin", 1, 1 }, { "tip", perChain[1], -1 } } do
      const joint = joints[at[2]]
      const radius = joint.w * geometry.CORE.scale
      const inward = joint.t * at[3]
      const reference = if math.abs(vector.dot(inward, UP)) > NEAR_VERTICAL then SIDE else UP
      const across = vector.normalize(vector.cross(inward, reference))
      const from = joint.p - inward * (radius + 0.2) + across * (radius * 0.3)
      const hit = core.editable:RaycastLocal(from, inward * (radius + 0.25))

      check(`the core's {at[1]} end is capped`, hit ~= nil)
    end

    -- the gradient whitened halfway by Heat: red at the origin, blue at the farthest tip
    const first = core.editable:GetColor(core.colorIds[1])
    const last = core.editable:GetColor(core.colorIds[ringStart(joints, farthest, geometry.CORE.sides) + 1])

    check("the origin vertex takes the first key whitened by Heat", colorNear(first, 1, 0.5, 0.5), `{first}`)
    check("the farthest tip vertex takes the last key whitened by Heat", colorNear(last, 0.5, 0.5, 1), `{last}`)

    const along = {}

    geometry.along(joints, geometry.CORE.sides, longest, along)

    local off = 0

    for k, u in along do
      const r, g, b = gradient.sample(looks.keys, u)
      const want = Color3.new(r, g, b):Lerp(WHITE, looks.heat)

      if not colorNear(core.editable:GetColor(core.colorIds[k]), want.R, want.G, want.B) then
        off += 1
      end
    end

    check("every core vertex takes the gradient along the bolt whitened by Heat", off == 0, `{off} off`)

    if glow then
      const shade = glow.editable:GetColor(glow.colorIds[1])

      check("the glow takes the bolt's color as it is", colorNear(shade, 1, 0, 0), `{shade}`)
    end

    -- a changed state: half width, glow strengths below 1, partly faded, and the head short of the main bolt's end
    const width = 0.5
    const glowRow = 0.8
    const state = { width = width, glow = 0.5, opacity = 0.75 }
    const strength = glowRow * state.glow
    const tint = geometry.GLOW.alpha * glowRow * state.glow

    -- what a core vertex at this fade should read: whitened by Heat less what it leans back toward the glow's color
    const function coreWant(u: number, fade: number, heat: number, tinted: number): Color3
      const r, g, b = gradient.sample(looks.keys, u)
      const lean = 1 - (1 - strength * (1 - fade)) * (1 - tinted * fade)

      return Color3.new(r, g, b):Lerp(WHITE, heat * (1 - lean))
    end
    const head = longest * 0.6
    const revealed = {}

    geometry.reveal(joints, head, 0, revealed)

    const drew = os.clock()

    mesh.draw(drawn, revealed, { width = width, glow = state.glow, opacity = 1 }, glowRow)
    table.insert(lines, `mesh.draw {string.format("%.3f", (os.clock() - drew) * 1000)} ms`)

    const plainOrigin = core.editable:GetColor(core.colorIds[1])

    check("a drawn bolt at full opacity keeps the core opaque", core.part.Transparency == CORE_REST)

    mesh.draw(drawn, revealed, { width = width, glow = state.glow, opacity = 0.99 }, glowRow)
    check(
      `the first faded frame goes straight to {TRANSPARENT}`,
      math.abs(core.part.Transparency - TRANSPARENT) < 1e-6,
      `{core.part.Transparency}`
    )

    mesh.draw(drawn, revealed, state, glowRow)

    const fadeTo = 1 - state.opacity

    check("a vertex with no shell over it takes no tint", core.editable:GetColor(core.colorIds[1]) == plainOrigin)
    check(
      `core transparency follows the opacity {string.format("%.3f", core.part.Transparency)}`,
      math.abs(core.part.Transparency - fadeTo) < 1e-6,
      `want {fadeTo}`
    )

    -- a shown main bolt joint, a hidden one, and a fork joint partway through its fade in
    local shown = nil
    local hidden = nil
    local fading = nil

    for i, joint in revealed do
      if joint.chain == 1 and joint.w > 0 and i > 2 and not shown then
        shown = i
      end

      if joint.chain == 1 and joint.w == 0 and not hidden then
        hidden = i
      end

      if joint.chain > 1 and joint.w > 0 and joint.fade > 0.1 and joint.fade < 0.9 and not fading then
        fading = i
      end
    end

    check("the reveal leaves a shown, a hidden and a fading joint", shown ~= nil and hidden ~= nil and fading ~= nil)

    if shown and hidden and fading then
      const tube = {}

      geometry.tube(revealed, geometry.CORE.sides, geometry.CORE.scale * width, tube)

      for _, at in { { "shown", shown }, { "hidden", hidden }, { "fading", fading } } do
        const k = ringStart(revealed, at[2], geometry.CORE.sides) + 3
        const read = core.editable:GetPosition(core.vertexIds[k])

        check(
          `core vertex of a {at[1]} joint reads back at width {width}`,
          near(read, tube[k]),
          `{read} want {tube[k]}`
        )
      end

      const ring = ringStart(revealed, shown, geometry.CORE.sides)
      const across = vector.magnitude(core.editable:GetPosition(core.vertexIds[ring + 1]) - revealed[shown].p)
      const wantAcross = revealed[shown].w * geometry.CORE.scale * width

      check(
        "core ring radius is joint w times 0.5 times the width",
        math.abs(across - wantAcross) < TOLERANCE,
        `{across} want {wantAcross}`
      )

      -- once faded, the core carries the tint the shell laid over it, by the glow's strength and its joint's fade
      const fade = revealed[shown].fade
      const want = coreWant(along[ring + 1], fade, looks.heat, tint)
      const read = core.editable:GetColor(core.colorIds[ring + 1])

      check(
        "a faded core takes the shell's tint",
        tint * fade > 0.01 and colorNear(read, want.R, want.G, want.B),
        `{read} want {want} at tint {tint * fade}`
      )

      if glow then
        const k = ringStart(revealed, fading, geometry.GLOW.sides) + 1
        const read = glow.editable:GetColorAlpha(glow.colorIds[k])
        const want = geometry.GLOW.alpha * glowRow * state.glow * state.opacity * revealed[fading].fade

        check(`glow alpha {string.format("%.4f", read)}`, alphaNear(read, want), `want {want}`)

        const shell = {}

        geometry.tube(revealed, geometry.GLOW.sides, geometry.GLOW.scale * width, shell)

        const position = glow.editable:GetPosition(glow.vertexIds[k])

        check(
          `glow vertex reads back at {geometry.GLOW.scale / geometry.CORE.scale} times the core's width`,
          near(position, shell[k]),
          `{position} want {shell[k]}`
        )
      end
    end

    -- Fade's end: the core fully transparent, the glow's alphas at 0, both at full width
    mesh.draw(drawn, revealed, { width = 1, glow = 1, opacity = 0 }, 1)
    check(
      "a Fade to opacity 0 leaves the core at Transparency 1",
      core.part.Transparency == 1,
      `{core.part.Transparency}`
    )

    if glow and shown then
      const k = ringStart(revealed, shown, geometry.GLOW.sides) + 1

      check("a Fade to opacity 0 leaves the glow's alpha at 0", glow.editable:GetColorAlpha(glow.colorIds[k]) == 0)
    end

    -- a recolor keeps the fades it does not touch, and a Heat alone leaves the glow
    mesh.draw(drawn, revealed, state, glowRow)

    const glowAt = if glow and fading then ringStart(revealed, fading, geometry.GLOW.sides) + 1 else nil
    const alphaBefore = if glow and glowAt then glow.editable:GetColorAlpha(glow.colorIds[glowAt]) else nil
    const glowBefore = if glow and glowAt then glow.editable:GetColor(glow.colorIds[glowAt]) else nil

    mesh.paint(drawn, nil, 0)

    const repainted = core.editable:GetColor(core.colorIds[1])
    const repaintedTip = core.editable:GetColor(core.colorIds[ringStart(joints, farthest, geometry.CORE.sides) + 1])

    check("mesh.paint at Heat 0 makes the origin the bolt's color", colorNear(repainted, 1, 0, 0), `{repainted}`)
    check("mesh.paint at Heat 0 makes the tip the bolt's color", colorNear(repaintedTip, 0, 0, 1), `{repaintedTip}`)

    if glow and glowAt then
      check("mesh.paint of a Heat alone leaves the glow", glow.editable:GetColor(glow.colorIds[glowAt]) == glowBefore)
    end

    mesh.paint(drawn, { GREEN }, nil)

    if glow and glowAt and alphaBefore then
      check("mesh.paint recolors the glow", colorNear(glow.editable:GetColor(glow.colorIds[glowAt]), 0, 1, 0))
      check("mesh.paint keeps the glow's alphas", glow.editable:GetColorAlpha(glow.colorIds[glowAt]) == alphaBefore)
    end

    if shown then
      const k = ringStart(revealed, shown, geometry.CORE.sides) + 1
      const read = core.editable:GetColor(core.colorIds[k])

      check("mesh.paint of a new gradient recolors the core", colorNear(read, 0, 1, 0), `{read}`)

      mesh.paint(drawn, nil, 1)

      const fade = revealed[shown].fade
      const lean = 1 - (1 - strength * (1 - fade)) * (1 - tint * fade)
      const want = Color3.new(0, 1, 0):Lerp(WHITE, 1 - lean)
      const hot = core.editable:GetColor(core.colorIds[k])

      check(
        "mesh.paint keeps the lean toward the glow under a new Heat",
        colorNear(hot, want.R, want.G, want.B),
        `{hot}`
      )
    end

    check("mesh.aim is gone", mesh.aim == nil)

    -- a rigid move changes every part's CFrame and no vertex
    const coreId = core.vertexIds[1]
    const offset = CFrame.new(5, 0, 0)
    const before = core.editable:GetPosition(coreId)

    mesh.move(drawn, offset)

    for _, name in { "core", "glow" } do
      const layer = drawn[name]

      if layer then
        check(`mesh.move places the {name} part`, layer.part.CFrame == offset, `{layer.part.CFrame}`)
      end
    end

    check("mesh.move writes no vertex", core.editable:GetPosition(coreId) == before)
    mesh.move(drawn, CFrame.identity)

    -- a finished bolt lets its drawing go at once
    mesh.free(drawn)

    for _, name in { "core", "glow" } do
      const layer = drawn[name]

      if layer then
        const read = pcall(function()
          return layer.editable:GetPosition(layer.vertexIds[1])
        end)

        check(`mesh.free removes the {name} part`, layer.part.Parent == nil)
        check(`mesh.free destroys the {name} mesh`, not read)
      end
    end
  end

  -- the same mesh module reaching a stand-in AssetService whose CreateEditableMesh answers nil
  local asked = 0
  const refusing = {
    CreateEditableMesh = function()
      asked += 1

      return nil
    end,
    CreateMeshPartAsync = function()
      error("a refused build should never make a part")
    end,
  }
  const refused = loadMesh({
    GetService = function()
      return refusing
    end,
  }, stage)
  const answer = refused.build(sdk, {}, joints, perChain, looks)

  check("a refused mesh.build answers nil", answer == nil and asked == 1, `asked {asked}`)
  check(
    "a refused mesh.build leaves nothing in Terrain or the holder",
    #terrain:GetChildren() == 0 and #holder:GetChildren() == 0,
    `{#terrain:GetChildren()} and {#holder:GetChildren()}`
  )

  -- a mesh part the engine will not make lets its EditableMesh go at once; the module kept the stand-in table it
  -- loaded with, so its functions are swapped in place
  local made = nil

  refusing.CreateEditableMesh = function()
    made = AssetService:CreateEditableMesh()

    return made
  end
  refusing.CreateMeshPartAsync = function()
    error("no mesh part today")
  end

  const unmade = refused.build(sdk, {}, joints, perChain, looks)
  const alive = made ~= nil and pcall(function()
    return made:GetPosition(made:GetVertices()[1])
  end)

  check("a failed mesh part answers nil", unmade == nil and made ~= nil)
  check("a failed mesh part destroys its EditableMesh", not alive)

  const parts = loadParts(stage)
  const shifted = path.fit(shape, ORIGIN + SHIFT, FINISH + SHIFT)
  const partJoints = geometry.joints(shape, shifted, 0.7, 0.3)
  local partLongest = 0

  for _, joint in partJoints do
    partLongest = math.max(partLongest, joint.arc)
  end

  const revealed = {}
  const building = os.clock()
  const partsDrawn = parts.build(sdk, {}, partJoints, perChain, looks)

  table.insert(
    lines,
    `parts.build {#partsDrawn.segments} segments {string.format("%.2f", (os.clock() - building) * 1000)} ms`
  )
  check(`parts segments {#partsDrawn.segments}`, #partsDrawn.segments == segments, `want {segments}`)

  geometry.reveal(partJoints, partLongest * 0.6, 0, revealed)

  const drew = os.clock()
  const partState = { width = 1, glow = 0.5, opacity = 0.75 }

  parts.draw(partsDrawn, revealed, partState, 0.8, true)
  table.insert(lines, `parts.draw {string.format("%.3f", (os.clock() - drew) * 1000)} ms`)

  local hiddenSegment = nil
  local shownSegment = nil
  local misplaced = 0

  for _, segment in partsDrawn.segments do
    const a = revealed[segment.from]
    const b = revealed[segment.from + 1]

    if a.w == 0 and b.w == 0 and not hiddenSegment then
      hiddenSegment = segment
    end

    if a.w > 0 and b.w > 0 and not shownSegment then
      shownSegment = segment
    end

    if segment.core.part.Parent ~= holder or (segment.glow and segment.glow.part.Parent ~= terrain) then
      misplaced += 1
    end
  end

  check("parts' cores sit under the holder and their glows under Terrain", misplaced == 0, `{misplaced} misplaced`)
  check("parts has a hidden and a shown segment", hiddenSegment ~= nil and shownSegment ~= nil)

  if hiddenSegment then
    check("a hidden segment's core is fully transparent", hiddenSegment.core.part.Transparency == 1)
  end

  if shownSegment then
    const a = revealed[shownSegment.from]
    const b = revealed[shownSegment.from + 1]
    const middle = (a.p + b.p) / 2
    const at = shownSegment.core.part.Position
    const r, g, bl = gradient.sample(looks.keys, (a.arc + b.arc) / 2 / partLongest)
    const tint = shownSegment.core.part.Color
    const glowPiece = shownSegment.glow
    const fade = (a.fade + b.fade) / 2
    -- the core leans back toward the glow's color by the glow's strength as far as the glow fades where it sits
    const lean = 0.8 * partState.glow * (1 - shownSegment.fade)
    const want = Color3.new(r, g, bl):Lerp(WHITE, looks.heat * (1 - lean))

    check("a shown core part sits at its segment's midpoint", near(at, middle), `{at} want {middle}`)
    check(
      `a shown core part follows the opacity {string.format("%.3f", shownSegment.core.part.Transparency)}`,
      math.abs(shownSegment.core.part.Transparency - 0.25) < 1e-6,
      "want 0.25"
    )
    check(
      "a shown core part takes the gradient at its middle whitened by Heat",
      colorNear(tint, want.R, want.G, want.B),
      `{tint} want {want}`
    )

    if glowPiece then
      const transparency = 1 - geometry.GLOW.alpha * 0.8 * partState.glow * partState.opacity * fade

      check(
        `a shown glow part's transparency {string.format("%.4f", glowPiece.part.Transparency)}`,
        math.abs(glowPiece.part.Transparency - transparency) < 1e-6,
        `want {transparency}`
      )
      check(
        "a shown glow part takes the bolt's color",
        colorNear(glowPiece.part.Color, r, g, bl),
        `{glowPiece.part.Color}`
      )
    end

    parts.paint(partsDrawn, nil, 0)

    const repainted = shownSegment.core.part.Color

    check("parts.paint at Heat 0 makes a core the bolt's color", colorNear(repainted, r, g, bl), `{repainted}`)

    parts.paint(partsDrawn, { GREEN }, nil)

    check("parts.paint of a new gradient recolors a core", colorNear(shownSegment.core.part.Color, 0, 1, 0))

    if glowPiece then
      check("parts.paint recolors a glow", colorNear(glowPiece.part.Color, 0, 1, 0), `{glowPiece.part.Color}`)
    end

    -- a reshape moves the arcs, but each core keeps the gradient it took when the bolt was made
    const before = {}

    for i, segment in partsDrawn.segments do
      before[i] = segment.core.part.Color
    end

    path.jitter(shape, next, 0.15)

    const reshaped = geometry.joints(shape, path.fit(shape, ORIGIN + SHIFT, FINISH + SHIFT * 1.5), 0.7, 0.3)
    const whole = {}

    geometry.reveal(reshaped, math.huge, 0, whole)
    parts.draw(partsDrawn, whole, partState, 0.8, true)

    local recolored = 0

    for i, segment in partsDrawn.segments do
      if segment.core.part.Color ~= before[i] then
        recolored += 1
      end
    end

    check("a reshape leaves every core's color", recolored == 0, `{recolored} recolored`)
    parts.draw(partsDrawn, revealed, partState, 0.8, true)

    -- a draw that only fades places nothing again, so a part moved aside stays where it was put
    const aside = shownSegment.core.part.CFrame + Vector3.new(0, 100, 0)

    shownSegment.core.part.CFrame = aside
    parts.draw(partsDrawn, revealed, { width = 1, glow = 1, opacity = 0 }, 1, false)
    check(
      "a draw that only fades moves no part",
      shownSegment.core.part.CFrame == aside,
      `{shownSegment.core.part.Position}`
    )
    check(
      "a Fade to opacity 0 leaves a shown core part at Transparency 1",
      shownSegment.core.part.Transparency == 1,
      `{shownSegment.core.part.Transparency}`
    )

    if glowPiece then
      check("a Fade to opacity 0 leaves a shown glow part at Transparency 1", glowPiece.part.Transparency == 1)
    end
  end

  parts.free(partsDrawn)

  local left = 0

  for _, segment in partsDrawn.segments do
    if segment.core.part.Parent ~= nil or (segment.glow and segment.glow.part.Parent ~= nil) then
      left += 1
    end
  end

  check("parts.free removes every piece", left == 0, `{left} left`)
end

const ran, problem = pcall(run)

if not ran then
  check("the check ran to its end", false, tostring(problem))
end

-- only what the check made is destroyed, by the references it held
for i = #held, 1, -1 do
  const thing = held[i]

  if typeof(thing) == "function" then
    pcall(thing)
  elseif typeof(thing) == "Instance" then
    thing:Destroy()
  end
end

const output = table.concat(lines, "\n")

if failed then
  error(`draw check failed\n{output}`, 0)
end

return output
