const SDK = require("@root/sdk/v1/types")

const rng = require("@mod/lightning/rng")
const mesh = require("@mod/lightning/mesh")
const path = require("@mod/lightning/path")
const rows = require("@mod/lightning/rows")
const kinds = require("@mod/lightning/kinds")
const walls = require("@mod/lightning/walls")
const parts = require("@mod/lightning/parts")
const cores = require("@mod/lightning/cores")
const nested = require("@mod/lightning/nested")
const riders = require("@mod/lightning/riders")
const strike = require("@mod/lightning/strike")
const impacts = require("@mod/lightning/impacts")
const gradient = require("@mod/lightning/gradient")
const geometry = require("@mod/lightning/geometry")
const timeline = require("@mod/lightning/timeline")
const highlight = require("@mod/lightning/highlight")

const NO_TIME = { Min = 0, Max = 0 }
const SEED_MAX = 2 ^ 31 - 2
const FLOW_ALONG = 1 / 15
const GONE_CHECK = 0.1
const LIGHT_RANGE = 60
const END_WARNING = "Lightning set to End needs an End point attachment, or an Attachment named End inside it."
const PARTS_WARNING = "EditableMesh is not available here, so the lightning is drawn with parts."
const BOLT_WARNING = "This can't ride inside Bolt. Put it in EmitAlong to play it on the bolt."
const HIGHLIGHT_WARNING = "Only the first Highlight in Bolt is used."
const LOCKED_WARNING = "Turn on Archivable for anything inside Bolt or EmitAlong so it can play."

const random = Random.new()

-- every ref whose loop already has a continuous bolt standing, so the loop's later ticks start none beside it
const Staying: { [Instance]: { any } } = {}

type along = { children: { Instance }, host: Attachment?, joint: number, due: boolean }

const effect = {}

effect.sdk_version = 1
effect.id = "forge_lightning"
effect.display = { name = "Lightning", icon = "lightning", category = "paths" }
effect.classifier = "Attachment.ForgeLightning"
effect.components = "> #End, > #EmitOnStart, > #EmitOnImpact, > #EmitAtTip, > #Bolt, > #EmitAlong, > #EmitOnFinish"
effect.constant = true
effect.layout = rows.layout
effect.params = rows.params

-- an Instant bolt has no appear phase, so its hidden time rows add nothing, and a continuous one holds until it is
-- let go, so it takes no hold and no restrikes from its rows
const function timing(attrs: any, staying: boolean?)
  return {
    appear = attrs.Appear,
    appearTime = if attrs.Appear == "Instant" then NO_TIME else attrs.AppearTime,
    hold = if staying then NO_TIME else attrs.Hold,
    restrikes = if staying then 0 else math.floor(attrs.Restrikes),
    disappear = attrs.Disappear,
    disappearTime = attrs.DisappearTime,
  }
end

-- a window's last tick can start as it closes and plays a whole bolt after it
function effect.duration(_: SDK.V1, attrs: any)
  return attrs.EmitDelay + attrs.EmitDuration + timeline.duration(timing(attrs))
end

function effect.template(_: SDK.V1)
  const attachment = Instance.new("Attachment")

  attachment.Name = "ForgeLightning"
  attachment:AddTag("ForgeLightning")

  const finish = Instance.new("Attachment")

  finish.Name = "End"
  finish.CFrame = CFrame.new(0, -20, 0)
  finish.Parent = attachment

  for _, name in { "EmitOnImpact", "Bolt", "EmitAlong" } do
    const folder = Instance.new("Folder")

    folder.Name = name
    folder.Parent = attachment
  end

  return attachment
end

const function sample(track: any, elapsed: number)
  return if track.animated then track:at(elapsed) else track.value
end

const function endOf(ref: Instance, picked: Attachment?): Attachment?
  if picked then
    return picked
  end

  const found = ref:FindFirstChild("End")

  return if found and found:IsA("Attachment") then found else nil
end

const function childrenOf(folder: Folder?): { Instance }
  return if folder then folder:GetChildren() else {}
end

-- what Bolt and EmitAlong hold, warning once for anything the lightning cannot drive, for a second Highlight and
-- for anything left out for not being Archivable
const function sortSlots(sdk: SDK.V1, ctx: SDK.Ctx, slots: { [string]: Folder }): (kinds.Sorted, kinds.Along)
  const riding = kinds.sort(childrenOf(slots.Bolt))
  const along = kinds.sortAlong(childrenOf(slots.EmitAlong))

  if riding.refused then
    sdk.warn(ctx, BOLT_WARNING)
  end

  if riding.extra then
    sdk.warn(ctx, HIGHLIGHT_WARNING)
  end

  if riding.locked or along.locked then
    sdk.warn(ctx, LOCKED_WARNING)
  end

  return riding, along
end

const function keysOf(sequence: ColorSequence): { gradient.key }
  const keys = {}

  for i, point in sequence.Keypoints do
    keys[i] = { t = point.Time, r = point.Value.R, g = point.Value.G, b = point.Value.B }
  end

  return keys
end

const function lightAt(sdk: SDK.V1, ctx: SDK.Ctx): (Attachment, PointLight)
  const holder = sdk.hold(ctx, Instance.new("Attachment"))

  holder.Name = "LightningLight"
  holder.Archivable = false

  const light = Instance.new("PointLight")

  light.Shadows = false
  light.Brightness = 0
  light.Parent = holder
  holder.Parent = sdk.container(ctx)

  return holder, light
end

function effect.emit(sdk: SDK.V1, ctx: SDK.Ctx, attrs: any)
  if sdk.context() == "server" then
    return
  end

  const ref = ctx.ref :: Attachment
  const continuous = attrs.Continuous == true
  -- a loop's tick stays until Enabled goes off, a Duration's emit for the Duration, a plain emit not at all
  const staying = continuous and (ctx.constant == true or attrs.EmitDuration > 0)
  const releaseAt = if staying and not ctx.constant then attrs.EmitDuration else nil
  local enabled = true

  if staying and ctx.constant then
    if Staying[ref] then
      return
    end

    const mark = {}

    Staying[ref] = mark

    const function letGo()
      if Staying[ref] == mark then
        Staying[ref] = nil
      end
    end

    sdk.hold(ctx, letGo)

    -- Enabled is read off the instance: the rows an emit is handed are frozen as it starts
    sdk.hold(
      ctx,
      ref:GetAttributeChangedSignal("Enabled"):Connect(function()
        if ref:GetAttribute("Enabled") ~= true then
          enabled = false
          letGo()
        end
      end)
    )
  end

  if attrs.EmitDelay > 0 then
    sdk.wait(ctx, attrs.EmitDelay)
  end

  if attrs.EmitDuration > 0 and not ctx.constant and not continuous then
    sdk.window(ctx, attrs.EmitDuration)

    return
  end

  -- turned off during the delay
  if staying and ctx.constant and ref:GetAttribute("Enabled") ~= true then
    return
  end

  -- a ref already out of the place would play its slots at its own offset, near the world's origin
  if not ref:IsDescendantOf(game) then
    return
  end

  const finishAt = if attrs.Target == "End" then endOf(ref, attrs.EndPoint) else nil

  if attrs.Target == "End" and not finishAt then
    sdk.warn(ctx, END_WARNING)

    return
  end

  const slots = nested.slots(ref)
  const join = sdk.join(ctx)
  const count = math.floor(attrs.Count)
  const riding, along = sortSlots(sdk, ctx, slots)
  const cover = if riding.highlight then highlight.make(sdk, ctx, riding.highlight, count) else nil
  const sprays = along.emitter
  const struck = along.strike
  local away = false

  -- an ancestor taken out of the place (a streamed out part, a model parented to nil) leaves the ref a parent
  sdk.hold(
    ctx,
    ref.AncestryChanged:Connect(function()
      away = not ref:IsDescendantOf(game)
    end)
  )

  const function gone()
    return away or ref.Parent == nil
  end

  -- each bolt's timing comes from a seed of its own, so the emit can read every plan before any bolt starts
  const timings = {}

  for i = 1, count do
    timings[i] = random:NextInteger(1, SEED_MAX)
  end

  -- one Highlight covers every bolt of the emit, so they all disappear together once the last hold is over, and none
  -- drops its share of the fill while another still holds it up
  local fadeAt: number? = nil

  if cover and not staying then
    local latest = 0

    for _, seed in timings do
      const own = timeline.plan(rng.generator(seed), timing(attrs))

      latest = math.max(latest, own.still)
    end

    fadeAt = latest
  end

  const function bolt(seed: number)
    const start = ref.WorldCFrame
    const taper = attrs.Taper
    const flowing = attrs.Motion == "Flow"
    const jitter = if flowing then 0 else attrs.Jitter
    const b: strike.Bolt = {
      next = rng.generator(random:NextInteger(1, SEED_MAX)),
      shape = nil :: any,
      fitted = {},
      joints = {},
      targets = {},
      trims = {},
      cuts = {},
      bends = {},
      cast = nil,
      aim = Vector3.yAxis,
      miss = nil,
      fitEnd = Vector3.zero,
      atFit = start,
      width = sample(attrs.Width, 0),
      longest = 0,
      middle = 1,
      length = 0,
    }

    const surfacing = slots.EmitOnImpact ~= nil
    const hits = strike.make(attrs, b, ref, start, finishAt, surfacing, 0)
    const ends = strike.ends(b.fitted)
    local list = strike.impacts(b, start, hits, ends, finishAt)
    const plan = timeline.plan(rng.generator(seed), timing(attrs, staying), fadeAt)

    if staying then
      timeline.stay(plan)
    end
    const appearCurve = sdk.curve(1, attrs.AppearCurve)
    const disappearCurve = sdk.curve(1, attrs.DisappearCurve)

    const function appearAt(t: number)
      return appearCurve:at(t)
    end

    const function disappearAt(t: number)
      return disappearCurve:at(t)
    end

    const perChain = {}

    for c, chain in b.fitted do
      perChain[c] = #chain
    end

    -- a mesh part made with every vertex on one point still draws them once they move apart (measured 2026-10-23),
    -- so the bolt is built as it stands at its first frame and never shows whole before it is drawn
    const shown = {}
    const opening = timeline.at(plan, 0, appearAt, disappearAt)

    geometry.reveal(b.joints, opening.head * b.longest, opening.tail * b.longest, shown)

    local heat = sample(attrs.Heat, 0)
    local sequence = sample(attrs.Gradient, 0)
    const holder = if cover then cover.model else cores.model(sdk, ctx)
    const looks = {
      glow = rows.glowing(attrs.Style, attrs.Glow),
      heat = heat,
      strength = math.clamp(sample(attrs.Glow, 0) * opening.glow, 0, 1),
      keys = keysOf(sequence),
      longest = b.longest,
      restart = attrs.GradientRestart,
      holder = holder,
    }
    local drawn: mesh.Drawn? = nil
    local blocks: parts.PartsDrawn? = nil

    if attrs.Style ~= "Segments" then
      drawn = mesh.build(sdk, ctx, shown, perChain, looks)

      if not drawn then
        sdk.warn(ctx, PARTS_WARNING)
      end
    end

    if not drawn then
      blocks = parts.build(sdk, ctx, b.joints, perChain, looks)
    end

    const r = riders.build(sdk, ctx, riding, perChain)
    const seen = if cover then highlight.join(cover) else nil
    local lamp: Attachment? = nil
    local light: PointLight? = nil

    if attrs.Light > 0 then
      lamp, light = lightAt(sdk, ctx)
    end

    -- fired by chain, since a bolt aimed again during its first strike lists its impacts anew
    const fired = {}
    const due = {}
    const arcs = {}
    local unfired = #list
    const drawnState = { head = 0, tail = 0, width = 0, stateGlow = 0, opacity = 0, glow = 0 }
    const lit = { brightness = -1, range = -1, color = nil :: Color3? }
    const spray: along = { children = sprays, host = nil, joint = 0, due = #sprays > 0 }
    const strikeAlong: along = { children = struck, host = nil, joint = 0, due = #struck > 0 }
    const period = if jitter > 0 then 1 / jitter else math.huge
    -- every ray after the strike's own is cast on this clock: a restrike or reshape forces an aim, Flow aims when it
    -- is due, and any other fit casts the walls only when it is due, so a moving End or a flowing bolt casts
    -- nothing on the frames between
    const aimClock = walls.clock(attrs.Jitter)
    local strikeIndex = 1
    local nextReshape = period
    local nextSpray = FLOW_ALONG
    local placed = CFrame.identity
    local fresh = true
    local tip: Attachment? = nil

    if slots.EmitOnStart then
      nested.host(sdk, ctx, slots.EmitOnStart:GetChildren(), "EmitOnStart", start)
    end

    if slots.EmitAtTip then
      tip = nested.host(sdk, ctx, slots.EmitAtTip:GetChildren(), "EmitAtTip", start)
    end

    -- glow is the Glow row, apart from state.glow, the timeline's own share of it
    const function settled(state: timeline.State, head: number, tail: number, glow: number)
      return not fresh
        and drawnState.head == head
        and drawnState.tail == tail
        and drawnState.width == state.width
        and drawnState.stateGlow == state.glow
        and drawnState.opacity == state.opacity
        and drawnState.glow == glow
    end

    const function remember(state: timeline.State, head: number, tail: number, glow: number)
      fresh = false
      drawnState.head = head
      drawnState.tail = tail
      drawnState.width = state.width
      drawnState.stateGlow = state.glow
      drawnState.opacity = state.opacity
      drawnState.glow = glow
    end

    -- arcs from this fit, the same one the head is measured on; nothing is read once every impact has fired
    const function fireImpacts(now: CFrame, head: number)
      if not slots.EmitOnImpact or unfired == 0 then
        return
      end

      for i, at in list do
        arcs[i] = b.joints[ends[at.chain]].arc
        due[i] = fired[at.chain] == true
      end

      for i = #list + 1, #arcs do
        arcs[i] = nil
        due[i] = nil
      end

      for _, index in impacts.due(arcs, due, head) do
        const at = list[index]

        fired[at.chain] = true
        unfired -= 1

        const ending = strike.live(finishAt)

        -- an impact carried by an End destroyed since is let go
        if at.onEnd and not ending then
          continue
        end

        const space = if at.onEnd and ending then ending.WorldCFrame else now
        const normal = space:VectorToWorldSpace(at.normal)
        const right, up = impacts.axes(normal, space:VectorToWorldSpace(at.travel), attrs.ImpactFacing)
        const frame = CFrame.fromMatrix(impacts.lifted(space:PointToWorldSpace(at.point), normal), right, up)

        nested.host(sdk, ctx, slots.EmitOnImpact:GetChildren(), "EmitOnImpact", frame)
      end
    end

    -- the shape aimed again from where the ref is, and while the first strike's impacts are still to fire, listed
    -- again from the surfaces this aim found
    const function aimAgain(now: CFrame)
      const surfaces = surfacing and strikeIndex == 1
      const found = strike.aim(attrs, b, ref, now, finishAt, surfaces)

      if not surfaces then
        return
      end

      list = strike.impacts(b, now, found, ends, finishAt)
      unfired = 0

      for _, at in list do
        if not fired[at.chain] then
          unfired += 1
        end
      end
    end

    -- a host keeps to its joint while the bolt shows; a hidden bolt's parked joints are not where it shows again
    const function follow(slot: along, toWorld: CFrame)
      const host = slot.host

      if not host then
        return
      end

      const at = toWorld:PointToWorldSpace(shown[slot.joint].p)

      if host.WorldPosition ~= at then
        host.WorldPosition = at
      end
    end

    -- held until a joint is drawn, so a point lands on the bolt and never on its parked, unrevealed joints
    const function emitAlong(slot: along, toWorld: CFrame, now: CFrame)
      const pick = geometry.pick(shown, b.next)

      if not pick then
        return
      end

      const point = CFrame.new(toWorld:PointToWorldSpace(shown[pick].p)) * now.Rotation

      slot.due = false
      slot.joint = pick

      if slot.host then
        nested.again(sdk, ctx, slot.host, point)
      else
        slot.host = nested.host(sdk, ctx, slot.children, "EmitAlong", point)
      end
    end

    const function frame(_: number, elapsed: number)
      -- a destroyed attachment reads its world frame as its own offset, which carried the bolt to the world's
      -- origin (measured 2026-10-23), so a bolt whose ref is gone stays put and draws as it does past its end
      const lost = gone()

      if timeline.staying(plan) and (lost or not enabled or (releaseAt ~= nil and elapsed >= releaseAt)) then
        timeline.release(plan, elapsed)
      end

      const now = if lost then b.atFit else ref.WorldCFrame
      const state = timeline.at(plan, if lost then plan.total + 1 else elapsed, appearAt, disappearAt)
      const width = sample(attrs.Width, elapsed)
      local shade = state.opacity

      if cover then
        shade, state.opacity = timeline.cover(state.opacity)
      end

      local changed = false
      local refit = false

      if state.strike > strikeIndex then
        -- impacts belong to the first strike, so a hitch that skips past its end still fires the ones not reached
        if strikeIndex == 1 then
          fireImpacts(now, math.huge)
        end

        strikeIndex = state.strike
        b.width = width
        strike.make(attrs, b, ref, now, finishAt, false, timeline.moving(plan, elapsed))
        walls.due(aimClock, elapsed, true)
        -- the new shape shows for a whole period once its blink is over
        nextReshape = elapsed + timeline.BLINK + period
        changed = true
        -- a restrike's frame falls in its blink, so the due flags wait for the bolt to show again
        spray.due = #sprays > 0
        strikeAlong.due = #struck > 0
      elseif state.visible and flowing and not timeline.waiting(plan, elapsed) then
        path.flow(b.shape, timeline.moving(plan, elapsed), attrs.FlowSpeed, attrs.Jagged)

        -- aimed on a clock of its own, fitting the offsets this frame flowed to, so the bolt never jumps a pattern
        if not lost and walls.due(aimClock, elapsed) then
          aimAgain(now)
          changed = true
        else
          refit = true
        end
      elseif state.visible and elapsed >= nextReshape and not timeline.waiting(plan, elapsed) then
        nextReshape = (math.floor(elapsed / period) + 1) * period
        path.jitter(b.shape, b.next, attrs.Jagged)
        spray.due = #sprays > 0

        if lost then
          refit = true
        else
          walls.due(aimClock, elapsed, true)
          aimAgain(now)
          changed = true
        end
      end

      const ending = if lost then nil else strike.live(finishAt)
      const finish = if ending then now:PointToObjectSpace(ending.WorldPosition) else b.fitEnd

      -- parts are placed in the world on every draw, so they follow a move by fitting again
      if refit or path.refits(b.fitEnd, finish) or (blocks ~= nil and now ~= b.atFit) then
        strike.fit(b, now, finish, width, taper, if not lost and walls.due(aimClock, elapsed) then "pass" else nil)
        changed = true
      elseif width ~= b.width then
        geometry.joints(b.shape, b.fitted, width, taper, b.joints)
        b.width = width
        changed = true
      end

      const still = now == b.atFit
      const toWorld = if still then CFrame.identity else now * b.atFit:Inverse()

      if drawn and toWorld ~= placed then
        placed = toWorld
        mesh.move(drawn, toWorld)
      end

      const glow = sample(attrs.Glow, elapsed)
      const head = if state.visible then state.head * b.longest else -math.huge
      const tail = state.tail * b.longest

      if changed or not settled(state, head, tail, glow) then
        -- a fade or a glow change alone leaves every joint where it was drawn
        const reshaped = changed
          or fresh
          or head ~= drawnState.head
          or tail ~= drawnState.tail
          or state.width ~= drawnState.width

        remember(state, head, tail, glow)
        geometry.reveal(b.joints, head, tail, shown)

        if drawn then
          mesh.draw(drawn, shown, state, glow)
        elseif blocks then
          parts.draw(blocks, shown, state, glow, reshaped)
        end
      end

      if r then
        riders.draw(r, shown, state, toWorld, b.middle, ends[1], b.width)
      end

      if cover and seen then
        seen.visible = state.visible
        seen.opacity = shade
        highlight.refresh(cover)
      end

      if attrs.Heat.animated or attrs.Gradient.animated then
        const nowHeat = sample(attrs.Heat, elapsed)
        const nowSequence = sample(attrs.Gradient, elapsed)

        -- a sequence compares by its keypoints, so a held lane recolors nothing
        if nowHeat ~= heat or nowSequence ~= sequence then
          const keys = if nowSequence ~= sequence then keysOf(nowSequence) else nil
          const changedHeat = if nowHeat ~= heat then nowHeat else nil

          heat = nowHeat
          sequence = nowSequence

          if drawn then
            mesh.paint(drawn, keys, changedHeat)
          elseif blocks then
            parts.paint(blocks, keys, changedHeat)
          end
        end
      end

      if lamp and light then
        -- the middle as shown, so a growing bolt's light rides its head until the head passes the middle, and a
        -- hidden bolt's parked joints never move it
        const middle = toWorld:PointToWorldSpace(shown[b.middle].p)

        if state.visible and lamp.WorldPosition ~= middle then
          lamp.WorldPosition = middle
        end

        const brightness = if state.visible then attrs.Light * state.flash else 0
        const range = math.min(b.length, LIGHT_RANGE)

        if brightness ~= lit.brightness then
          lit.brightness = brightness
          light.Brightness = brightness
        end

        if range ~= lit.range then
          lit.range = range
          light.Range = range
        end

        const glow = sample(attrs.LightColor, elapsed)

        if glow ~= lit.color then
          lit.color = glow
          light.Color = glow
        end
      end

      if not state.visible then
        return
      end

      if tip then
        const front = toWorld:PointToWorldSpace(shown[ends[1]].p)

        if tip.WorldPosition ~= front then
          tip.WorldPosition = front
        end
      end

      -- a Flow bolt never reshapes, so what it sprays along itself is emitted again on a clock of its own
      if flowing and elapsed >= nextSpray then
        nextSpray = (math.floor(elapsed / FLOW_ALONG) + 1) * FLOW_ALONG
        spray.due = #sprays > 0
      end

      follow(spray, toWorld)
      follow(strikeAlong, toWorld)

      if spray.due then
        emitAlong(spray, toWorld, now)
      end

      if strikeAlong.due then
        emitAlong(strikeAlong, toWorld, now)
      end

      if state.strike == 1 then
        fireImpacts(now, state.head * b.longest)
      end
    end

    frame(0, 0)

    const stop = sdk.step(ctx, frame, "late")

    -- the total is read on every wait, since a continuous bolt's is set only once it is let go
    local passed = 0

    while passed < plan.total and not gone() do
      const span = math.min(GONE_CHECK, plan.total - passed)

      passed += math.max(sdk.wait(ctx, span), span)
    end

    stop()

    if timeline.staying(plan) then
      timeline.release(plan, passed)
    end

    frame(0, plan.total + 1)

    -- the drawing goes now, while the nested effects it started keep the emit alive on their own
    if drawn then
      mesh.free(drawn)
    elseif blocks then
      parts.free(blocks)
    end

    if cover and seen then
      highlight.leave(cover, seen)
    else
      holder:Destroy()
    end

    if lamp then
      lamp:Destroy()
    end

    const lifetime = if r then riders.free(r) else 0

    if slots.EmitOnFinish and not gone() then
      nested.host(sdk, ctx, slots.EmitOnFinish:GetChildren(), "EmitOnFinish", ref.WorldCFrame)
    end

    -- points still showing particles stay where the bolt left them until the last of those has died
    if r then
      sdk.wait(ctx, lifetime)
      riders.last(r)
    end
  end

  for _, seed in timings do
    sdk.spawn(join, bolt, seed)
  end

  sdk.await(join)
end

return effect
