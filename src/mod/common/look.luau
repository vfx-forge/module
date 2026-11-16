const attr = require("@mod/attributes")
const mods = require("@mod/mods")
const curve = require("@mod/curve")
const color = require("@mod/color/color")
const tween = require("@mod/tween")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const frame_show = require("@mod/frame_show")
const texture_show = require("@mod/texture_show")
const flipbook_loop = require("@mod/flipbook_loop")
const flipbook_common = require("@mod/common/flipbook")

const emitters = require("@root/emitters")

const frame_store = require("@srv/frame_store")

const WHITE = Color3.new(1, 1, 1)

const common = {}

export type Sets = {
  frames: frame_store.Set?,
  textures: frame_store.Set?,
}

-- the piece's decals as utility.getMeshDecals answers them, read before a
-- frame's decal joins the piece, where it would pass for one of its own
export type Decals = {
  list: { Decal },
  flipbooks: { [Decal]: any },
  twins: { [Decal]: Decal },
}

export type Options = {
  -- the instance whose loop toggles a playing loop watches, else the template
  owner: Instance?,
  decals: Decals?,
  -- read the flipbooks' Mode, StartRandom and Reverse rows rather than their
  -- Loop toggles
  modes: boolean?,
  -- an unset change duration is the piece's own, not the row's default
  ownDefault: boolean?,
  -- draws the random starts
  rng: { NextNumber: (self: any) -> number }?,
  -- the piece moves through states that set its decals' transparency and
  -- glow and its surface, so no row tweens them
  stated: boolean?,
}

export type Look = {
  size: (size: Vector3) -> (),
  scale: (size: Vector3, mesh: SpecialMesh?) -> (),
  depth: (k: number) -> (),
  refit: () -> (),
  offset: () -> CFrame,
  glow: (strength: number, tint: Color3, color: Color3) -> (),
  play: () -> (),
  wait: () -> (),
  linger: () -> (),
  life: number,
}

-- a decal's own glow rows, which the decal's card writes on the decal
const function glowStrength(decal: Decal, duration: number)
  const rest = attr.get(decal, "GlowStrength", 1, true, function(v)
    return if type(v) == "number" then math.max(v, 0) else 1
  end)

  return mods.track(decal, "attribute", "GlowStrength", rest, duration)
end

-- a track played on its own span, written once when it never moves
const function play(scope: lifetime.effect, track: mods.Track, write: (v: any) -> ())
  write(track.at(0))

  if track.animated then
    tween.play(scope, curve.new(track.span, "linear"), function(_, _, elapsed: number)
      write(track.at(elapsed))
    end)
  end
end

-- the decal's color, blended toward its twin and run through its own Color3
-- modifiers, times the strength when it glows by its color. never clamped, so
-- a strength past 1 brightens it past white. the mesh claims Color3 on its
-- decal in every glow mode, so this is its one writer
const function decalColor(scope: lifetime.effect, decal: Decal, twin: Color3, duration: number, glows: boolean)
  const rest = decal.Color3
  const blends = rest ~= twin
  const eased = curve.new(duration, attr.get(decal, "Color_Curve", utility.default_bezier, true))
  const tinted = mods.track(decal, "property", "Color3", rest, duration)
  const strength = if glows then glowStrength(decal, duration) else nil

  const function at(elapsed: number)
    const alpha = if duration > 0 then eased:at(math.min(elapsed / duration, 1)) else 1
    const base = if blends then color.blend(rest, twin, alpha, true) else rest
    const c = tinted.at(elapsed, base)

    if strength == nil then
      return c
    end

    const s = math.max(strength.at(elapsed), 0)

    return Color3.new(c.R * s, c.G * s, c.B * s)
  end

  -- written even when nothing moves, since a lane holding one color is not
  -- animated and still sets it
  decal.Color3 = at(0)

  if not blends and not tinted.animated and not (strength ~= nil and strength.animated) then
    return
  end

  local span = if blends then duration else 0

  for _, track in { tinted, strength } do
    if track.animated then
      span = math.max(span, track.span)
    end
  end

  tween.play(scope, curve.new(span, "linear"), function(_, _, elapsed: number)
    decal.Color3 = at(elapsed)
  end)
end

const function emissiveGlow(scope: lifetime.effect, decal: Decal, duration: number)
  const rest = attr.get(decal, "GlowTint", WHITE, true, function(v)
    return if typeof(v) == "Color3" then v else WHITE
  end)

  play(scope, glowStrength(decal, duration), function(v: number)
    decal.EmissiveStrength = math.max(v, 0)
  end)

  play(scope, mods.track(decal, "attribute", "GlowTint", rest, duration), function(v: Color3)
    decal.EmissiveTint = v
  end)
end

-- what a mesh piece wears over its life: its frames, its material frames, its
-- glow, its decals and its transparency. `start` plays the frames, so the first
-- pose already stands at the frame's offset; `play` starts the rest once the
-- piece's nested emits have read it as it was taken, and settles `life`
function common.start(
  scope: any,
  piece: BasePart,
  template: BasePart,
  attrs: any,
  duration: number,
  sets: Sets,
  opts: Options?
): Look
  const set = sets.frames
  const textureSet = sets.textures
  const owner = if opts and opts.owner then opts.owner else template
  const decals = if opts then opts.decals else nil
  const modes = opts ~= nil and opts.modes == true
  const rng = if opts then opts.rng else nil
  const stated = opts ~= nil and opts.stated == true

  const destroyDelay = attrs.DestroyDelay or 0

  const legacy_isFlipbook = attrs.Flipbook
  const legacy_flipbookFadeOffset = attrs.FlipbookFadeOffset or 0

  const legacy_decalST = attrs.DecalStartTransparency or 0
  -- no end holds the decal where it starts rather than fading it; the legacy
  -- mesh's row always names one, so only the forge mesh's decal holds
  const legacy_decalET = if attrs.DecalEndTransparency ~= nil then attrs.DecalEndTransparency else legacy_decalST

  const objMesh = piece:FindFirstChildOfClass("SpecialMesh")
  const surface = piece:FindFirstChildOfClass("SurfaceAppearance")

  const frameCount = if set then #set.frames else 0
  const textureCount = if textureSet then #textureSet.frames else 0
  const textures = if textureSet and textureCount > 0 then texture_show.new(textureSet, piece) else nil

  -- a texture set shown takes the surface, so the frames bring only their shapes
  const shown = if set and frameCount > 0
    then frame_show.new(set, piece, template, if textures then { materials = false } else nil)
    else nil

  local offset = Vector3.zero
  local frameIndex = 1
  local currentSize = template.Size

  -- the share a ZOffset draws the piece at toward the camera (look.depth),
  -- up here because a frame's fit reads it
  local depth = 1
  local longestFlipbookDuration = 0

  -- a loop counting 0 plays for the piece's whole life, known only once every
  -- flipbook has its length, so it shows its first frame now and starts then
  const bounded: { (life: number) -> () } = {}

  -- every loop counting below 0 still playing, which the piece outlives
  const looping = lifetime.join(scope)

  -- a loop counting below 0 plays until `running` answers false for `toggle` on
  -- `obj`, then to the end of its cycle. a read of an instance after its rows
  -- resolve, since that switch while the loop plays is the only way it ends
  const function endless(
    obj: Instance,
    toggle: string,
    running: (v: any) -> boolean,
    cycle: number,
    write: (elapsed: number, cycles: number) -> ()
  )
    -- a cycle of no length stands at its end from the start
    if not (cycle > 0) then
      write(0, 0)
      return
    end

    const stop = flipbook_loop.endless(scope, cycle, write, lifetime.add(looping))

    lifetime.hold(
      scope,
      attr.observe(obj, toggle, function(v: any)
        if not running(v) then
          stop()
        end
      end)
    )
  end

  -- whether a loop's switch leaves it running, a toggle or a mode that is not
  -- OneShot, either read as `fallback` while unset
  const function running(fallback: any)
    return function(v: any)
      const now = if v == nil then fallback else v

      return now == true or now == "Loop" or now == "PingPong"
    end
  end

  const function loop(
    obj: Instance,
    shape: any,
    count: number,
    cycle: number,
    cycles: number,
    length: number,
    write: (alpha: number) -> (),
    mode: flipbook_common.mode?,
    start: number?
  )
    if cycles > 0 then
      flipbook_loop.play(scope, shape, cycle, cycles, length, write, mode, start)
      return
    end

    const eased = curve.new(1, shape)

    if count < 0 then
      const toggle = if modes then "FlipbookMode" else "FlipbookLoop"

      endless(obj, toggle, running(if modes then mode or "OneShot" else false), cycle, function(elapsed, played)
        write(eased:at(flipbook_common.phase(elapsed, cycle, played, mode, start)))
      end)

      return
    end

    write(eased:at(0))

    table.insert(bounded, function(life: number)
      flipbook_loop.play(scope, shape, cycle, 0, life, write, mode, start)
    end)
  end

  const look = {} :: Look

  look.life = 0

  -- while frames play on a piece with no special mesh, the frame's fit is the
  -- piece's size, so a size lands through the frame shown
  function look.size(size: Vector3)
    currentSize = size

    if shown == nil or objMesh ~= nil then
      piece.Size = size
    end

    if shown then
      offset = shown.show(frameIndex, size, depth)
    end
  end

  -- the frame fitted again at the size it has, once a special mesh's scale
  -- has moved under it
  function look.refit()
    if shown then
      offset = shown.show(frameIndex, currentSize, depth)
    end
  end

  -- the piece's size and the share a ZOffset draws it at toward the camera
  -- (orient_common.toward): what is written is the size times the share, so
  -- the piece looks the same nearer the camera. `mesh` is the special mesh
  -- that carries the size, nil when the part's own size does
  local asked: Vector3? = nil
  local carrier: SpecialMesh? = nil
  local carrierOffset = Vector3.zero

  const function written()
    const size = (asked :: Vector3) * depth

    if carrier ~= nil then
      carrier.Scale = size

      -- a mesh drawn off its part moves toward the camera with the rest of it
      if carrierOffset ~= Vector3.zero then
        carrier.Offset = carrierOffset * depth
      end

      look.refit()
    else
      look.size(size)
    end
  end

  function look.scale(size: Vector3, mesh: SpecialMesh?)
    if mesh ~= nil and mesh ~= carrier then
      carrierOffset = mesh.Offset
    end

    asked, carrier = size, mesh
    written()
  end

  -- a share within a hair of the last is not written again: the camera
  -- drifting a little moves nothing anyone sees, and a walking camera would
  -- otherwise rewrite every ZOffset piece's size every frame. 0.2% is a
  -- fifth of a pixel on a piece 100 pixels across. Back to 1 is always
  -- written, so a piece with no camera any more is its own size again
  function look.depth(k: number)
    if k == depth or (k ~= 1 and math.abs(k - depth) <= 2e-3 * depth) then
      return
    end

    depth = k

    if asked ~= nil then
      written()
    end
  end

  -- the frame's center off the union's, along the piece's own axes
  function look.offset()
    return if shown then CFrame.new(offset) else CFrame.identity
  end

  if shown then
    -- a defer runs ahead of the clones, so the frame's material is given back
    -- before a piece cloned whole is destroyed with it
    lifetime.defer(scope, shown.release)

    const mode: flipbook_common.mode? = if modes then attrs.FlipbookMode or "OneShot" else nil
    const looped = if modes then mode ~= "OneShot" else attrs.FlipbookLoop
    const reverse = modes and attrs.FlipbookReverse == true
    const start = if modes and attrs.FlipbookStartRandom == true and rng then rng:NextNumber() else nil

    -- a loop starts that far into its cycle, one cycle wraps round its frames
    const wrap = if start and not looped then math.floor(start * frameCount) else 0

    const function write(alpha: number)
      local index = flipbook_common.pick(frameCount, alpha, mode)

      if wrap > 0 then
        index = (index - 1 + wrap) % frameCount + 1
      end

      frameIndex = if reverse then frameCount + 1 - index else index
      offset = shown.show(frameIndex, currentSize, depth)
    end

    const own = if opts
        and opts.ownDefault
        and attr.get(owner, "FlipbookChangeDuration", nil, true) == nil
        and attr.get(owner, "Flipbook_Change_Duration", nil, true) == nil
      then duration
      else attrs.FlipbookChangeDuration

    if looped then
      const cycle, cycles, length =
        flipbook_common.cycles(own, duration, attrs.SyncDuration, true, attrs.FlipbookLoopCount)

      longestFlipbookDuration = length
      loop(owner, attrs.FlipbookChangeCurve, attrs.FlipbookLoopCount, cycle, cycles, length, write, mode, start)
    else
      const changeDuration = if attrs.SyncDuration then duration else own

      longestFlipbookDuration = changeDuration

      tween.play(scope, curve.new(changeDuration, attrs.FlipbookChangeCurve), write)
    end

    const fade = attrs.FrameTransparency(nil, duration)

    -- a fade at rest leaves every decal frame at its own transparency
    if fade.animated or fade.at(0) ~= 0 then
      tween.drive(scope, fade, function(v: number)
        shown.fade(v)
      end)
    end
  end

  -- the template's own surface, which the piece's copy of it wears times the
  -- glow, read on the first glow
  local authored: any = nil
  local based = false

  -- the surface the piece wears multiplied by these: a texture set's frame, a
  -- mesh frame's material, else its own surface over the template's
  function look.glow(strength: number, tint: Color3, tone: Color3)
    if textures then
      textures.glow(strength, tint, tone)
      return
    end

    if shown and set and set.materials then
      shown.glow(strength, tint, tone)
      return
    end

    if not based then
      based = true
      authored = template:FindFirstChildOfClass("SurfaceAppearance")
    end

    if surface == nil or authored == nil then
      return
    end

    const baseTint, baseColor = authored.EmissiveTint, authored.Color

    surface.EmissiveStrength = authored.EmissiveStrength * strength
    surface.EmissiveTint = Color3.new(baseTint.R * tint.R, baseTint.G * tint.G, baseTint.B * tint.B)
    surface.Color = Color3.new(baseColor.R * tone.R, baseColor.G * tone.G, baseColor.B * tone.B)
  end

  const function glow()
    const strength = attrs.EmissiveStrength(nil, duration)
    const tint = attrs.EmissiveTint(nil, duration)
    const surfaceColor = attrs.SurfaceColor(nil, duration)

    -- a glow at rest writes nothing, so every material keeps its own
    if
      not strength.animated
      and not tint.animated
      and not surfaceColor.animated
      and strength.at(0) == 1
      and tint.at(0) == WHITE
      and surfaceColor.at(0) == WHITE
    then
      return
    end

    local glowStrength, glowTint, glowColor = strength.at(0), tint.at(0), surfaceColor.at(0)

    tween.drive(scope, strength, function(v: number)
      glowStrength = v
      look.glow(glowStrength, glowTint, glowColor)
    end)

    tween.drive(scope, tint, function(v: Color3)
      glowTint = v
      look.glow(glowStrength, glowTint, glowColor)
    end)

    tween.drive(scope, surfaceColor, function(v: Color3)
      glowColor = v
      look.glow(glowStrength, glowTint, glowColor)
    end)
  end

  const function legacyFlipbook(list: { Decal })
    table.sort(list, function(a, b)
      local x = a.Name:match("%d+") or 0
      local y = b.Name:match("%d+") or 0

      return tonumber(x) < tonumber(y)
    end)

    const displayDecal = Instance.new("Decal")
    displayDecal.Parent = piece

    lifetime.hold(scope, displayDecal)

    if legacy_flipbookFadeOffset > 0 then
      if legacy_decalST ~= legacy_decalET then
        tween.play(scope, curve.new(duration + legacy_flipbookFadeOffset, "easeOut"), function(alpha: number)
          displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
        end)
      end
    end

    tween.play(scope, curve.new(duration, "easeOut"), function(alpha: number)
      const index = math.max(math.round(#list * alpha), 1)
      const target = list[index]

      displayDecal.Texture = target.Texture

      displayDecal.Color3 = target.Color3
      displayDecal.ZIndex = target.ZIndex

      if legacy_flipbookFadeOffset == 0 then
        displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
        displayDecal.ZIndex = target.ZIndex
      end
    end)
  end

  const function decalLooks(found: Decals)
    -- the list can name a decal twice, and a glow reads the color it multiplies
    -- off the decal it writes, so each decal glows once
    const glowing: { [Instance]: boolean } = {}

    for _, decal in found.list do
      const from = decal
      const to = found.twins[from]

      -- this knob is authored on the DECAL rather than on the owner: ownership is
      -- keyed to the instance dispatch routes to, and the decal is dispatched
      -- on its own through emitNested. the decal's own resting value, which
      -- the plugin's Transparency row writes, leads the model's old pair
      const decalST = attr.get(from, "Transparency", legacy_decalST, true, function(v)
        return if type(v) == "number" then v else legacy_decalST
      end)

      -- a decal storing nothing holds where it rests unless its owner names
      -- an end for it, as the legacy mesh always does
      const decalET = if attrs.DecalEndTransparency ~= nil then legacy_decalET else decalST
      -- the states set a stated piece's decals, transparency and glow
      if not stated then
        const decalTp = mods.track(from, "attribute", "Transparency", mods.ramp(decalST, decalET), duration)

        decal.Transparency = decalTp.at(0)

        if decalTp.animated then
          tween.play(scope, curve.new(decalTp.span, "linear"), function(_, _, elapsed: number)
            decal.Transparency = decalTp.at(elapsed)
          end)
        end

        const glowMode = attr.get(from, "GlowMode", "None", true)
        const first = not glowing[decal]

        glowing[decal] = true

        -- an animator on the decal's Color3 is the explicit ask, so the mesh
        -- leaves the color to it
        const animated = emitters.animated(decal)

        if first and not (animated ~= nil and animated.Color3) then
          decalColor(scope, decal, to.Color3, duration, glowMode == "Color")
        end

        if glowMode == "Emissive" and first then
          emissiveGlow(scope, decal, duration)
        end
      end

      const flipbook = found.flipbooks[from]

      if flipbook then
        const config = {
          ref = from,
          frames = flipbook,
          effectDuration = duration,
          syncDuration = attr.get(from, "SyncDuration", false, true) == true,

          curve = attr.get(from, "Flipbook_Change_Curve", utility.linear_bezier, true),
          duration = attr.get(from, "Flipbook_Change_Duration", duration, true),

          setTexture = function(texture)
            decal.Texture = texture
          end,
        }

        const write = flipbook_common.createUpdateCallback(config)

        if attr.get(from, "FlipbookLoop", false, true) == true then
          const count = attr.get(from, "FlipbookLoopCount", 0, true, function(v)
            return if type(v) == "number" and v == v then v else 0
          end)

          const cycle, cycles, length =
            flipbook_common.cycles(config.duration, duration, config.syncDuration, true, count)

          longestFlipbookDuration = math.max(longestFlipbookDuration, length)
          -- switched on the template's own decal, the one this piece's decal copies
          loop(template:FindFirstChild(from.Name) or from, config.curve, count, cycle, cycles, length, write)
        else
          const changeDuration = flipbook_common.getChangeDuration(config)

          if changeDuration > longestFlipbookDuration then
            longestFlipbookDuration = changeDuration
          end

          tween.play(scope, curve.new(changeDuration, config.curve), write)
        end
      end
    end
  end

  -- the transparency, the glow, the decals and the material frames, then the
  -- life the longest of them decides
  function look.play()
    -- a caller without the row writes the piece's transparency itself
    if attrs.PartTransparency ~= nil then
      tween.drive(scope, attrs.PartTransparency(nil, duration), function(v: number)
        piece.Transparency = v
      end)
    end

    if not stated then
      glow()
    end

    if decals and legacy_isFlipbook then
      legacyFlipbook(decals.list)
    elseif decals then
      decalLooks(decals)
    end

    const fps = attrs.TextureFps
    const textureSync = attrs.TextureSyncDuration
    const textureMode: flipbook_common.mode? = if modes then attrs.TextureMode or "OneShot" else nil
    const textureLooped = if modes then textureMode ~= "OneShot" else attrs.TextureLoop
    const textureSteps = flipbook_common.steps(textureCount, textureMode)
    const textureReverse = modes and attrs.TextureReverse == true
    const textureStart = if modes
        and attrs.TextureStartRandom == true
        and rng
      then math.floor(rng:NextNumber() * textureSteps)
      else nil

    const textureCycle, textureCycles, textureLength =
      flipbook_common.cycles(textureSteps / fps, duration, textureSync, textureLooped, attrs.TextureLoopCount)

    if textures then
      longestFlipbookDuration = math.max(longestFlipbookDuration, textureLength)
    end

    const life = math.max(duration, longestFlipbookDuration) + legacy_flipbookFadeOffset

    look.life = life

    for _, begin in bounded do
      begin(life + destroyDelay)
    end

    if textures then
      lifetime.defer(scope, textures.release)

      const rate = if textureSync then textureSteps / textureCycle else fps
      local textureIndex = 0

      const function wear(elapsed: number, cycles: number)
        const index =
          flipbook_common.frame(elapsed, rate, textureCount, cycles, textureMode, textureReverse, textureStart)

        if index ~= textureIndex then
          textureIndex = index
          textures.show(index)
        end
      end

      if textureCycles == 0 and attrs.TextureLoopCount < 0 then
        const toggle = if modes then "TextureMode" else "TextureLoop"

        endless(owner, toggle, running(if modes then textureMode or "OneShot" else true), textureCycle, wear)
      else
        -- a loop counting 0 wears the textures for as long as the piece is up
        const worn = if textureCycles == 0 then life + destroyDelay else textureLength

        tween.play(scope, curve.new(worn, "linear"), function(_, _, elapsed: number)
          wear(elapsed, textureCycles)
        end)
      end
    end
  end

  -- parks for every loop counting below 0, whose end starts the destroy
  -- delay, for a piece whose life has already ended
  function look.linger()
    lifetime.awaitJoin(looping)
    tween.wait(scope, curve.new(destroyDelay, "linear"))
  end

  -- parks for the piece's life, then for what lingers after it
  function look.wait()
    if looping.count > 0 then
      tween.wait(scope, curve.new(look.life, "linear"))
      look.linger()
    else
      tween.wait(scope, curve.new(look.life + destroyDelay, "linear"))
    end
  end

  return look
end

return common
