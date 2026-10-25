-- run through the Studio MCP's execute_luau with a plugin build that carries this lightning
-- plays short bolts through the plugin's runtime (shared.vfx) and checks that EmitOnFinish fires once a bolt has
-- disappeared, that the bolt's own drawing has left Terrain by then while an effect it started still plays, that
-- an End bolt with no End warns and draws nothing, that the template carries its folders, that a Highlight in Bolt
-- covers every core of the emit once, that Bolt refuses what it cannot drive, that a child Bolt or EmitAlong
-- cannot clone warns, that a Sound in EmitAlong plays once per strike, that bolts under one Highlight disappear
-- together, and that a bolt without one reshapes while it thins
-- with CLEAN true it only removes what an earlier run left; any FAIL raises with the whole output
const CLEAN = false

const LogService = game:GetService("LogService")
const RunService = game:GetService("RunService")
const HttpService = game:GetService("HttpService")
const PluginGuiService = game:GetService("PluginGuiService")

const NAME = "LightningFinishCheck"
const KEY = "lightning_finish_check"
const ORIGIN = Vector3.new(-300, 80, -300)
const WAIT_MAX = 3
const LONG_LIFETIME = 2
const DRAWING = { LightningCore = true, LightningCores = true, LightningGlow = true, LightningLight = true }
const END_WARNING = "Lightning set to End needs an Attachment named End inside it."
const BOLT_WARNING = "This can't ride inside Bolt. Put it in EmitAlong to play it on the bolt."
const LOCKED_WARNING = "Turn on Archivable for anything inside Bolt or EmitAlong so it can play."
const SOUND_PLAYER = "VFXForgeSoundPlayer"

-- only what an earlier run recorded is destroyed, never anything found by name
const function clean()
  const record = shared[KEY]

  shared[KEY] = nil

  if not record then
    return
  end

  for _, connection in record.connections do
    connection:Disconnect()
  end

  for _, instance in record.made do
    instance:Destroy()
  end
end

clean()

if CLEAN then
  return "cleaned"
end

const vfx = shared.vfx

if type(vfx) ~= "table" or type(vfx.emit) ~= "function" then
  error("the plugin's runtime is not in shared.vfx", 0)
end

const record = { made = {}, connections = {} }

shared[KEY] = record

const folder = Instance.new("Folder")

folder.Name = NAME
table.insert(record.made, folder)
folder.Parent = workspace

const lines = {}
local failed = false

const function check(name: string, ok: boolean, detail: string?)
  if not ok then
    failed = true
  end

  table.insert(lines, `{if ok then "ok" else "FAIL"} {name}{if ok or not detail then "" else `: {detail}`}`)
end

-- an emitter in a nested host plays once and keeps the emit alive for its particles' lifetime
const function slot(parent: Instance, name: string, lifetime: number)
  const holder = Instance.new("Folder")
  const emitter = Instance.new("ParticleEmitter")

  holder.Name = name
  emitter.Enabled = false
  emitter.Rate = 0
  emitter.Lifetime = NumberRange.new(lifetime)
  emitter:SetAttribute("EmitCount", 1)
  emitter.Parent = holder
  holder.Parent = parent
end

const function bolt(label: string, offset: number, withEnd: boolean, attributes: { [string]: any }): Attachment
  const anchor = Instance.new("Part")

  anchor.Name = `Anchor{label}`
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanQuery = false
  anchor.Transparency = 1
  anchor.Size = Vector3.one
  anchor.CFrame = CFrame.new(ORIGIN + Vector3.new(offset, 0, 0))
  anchor.Parent = folder

  const attachment = Instance.new("Attachment")

  -- a unique name so this run's warnings are told apart in the log
  attachment.Name = `ForgeLightning{HttpService:GenerateGUID(false)}`
  attachment:AddTag("ForgeLightning")

  for name, value in attributes do
    attachment:SetAttribute(name, value)
  end

  if withEnd then
    const finish = Instance.new("Attachment")

    finish.Name = "End"
    finish.CFrame = CFrame.new(0, -20, 0)
    finish.Parent = attachment
  end

  attachment.Parent = anchor

  return attachment
end

-- what this run's emits put in Terrain, in the order it arrived
const added = {}

table.insert(
  record.connections,
  workspace.Terrain.ChildAdded:Connect(function(child)
    table.insert(added, { child = child, at = os.clock() })
  end)
)

const function since(start: number, name: string)
  for _, entry in added do
    if entry.at >= start and entry.child.Name == name then
      return entry
    end
  end

  return nil
end

const timing = {
  Appear = "Instant",
  Hold = NumberRange.new(0.2),
  Restrikes = 0,
  DisappearTime = 0.1,
  Light = 2,
}

for i, style in { "Glow", "Segments" } do
  const attributes = table.clone(timing)

  attributes.Style = style

  const ref = bolt(style, 30 * i, true, attributes)

  slot(ref, "EmitOnStart", LONG_LIFETIME)
  slot(ref, "EmitOnFinish", 0.5)

  const start = os.clock()

  vfx.emit(ref)

  local finish = nil

  while not finish and os.clock() - start < WAIT_MAX do
    task.wait()
    finish = since(start, "EmitOnFinish")
  end

  check(`{style}: EmitOnFinish fires`, finish ~= nil)

  if finish then
    const drawn = {}
    local left = 0

    for _, entry in added do
      if entry.at >= start and DRAWING[entry.child.Name] then
        table.insert(drawn, entry.child)

        if entry.child.Parent ~= nil then
          left += 1
        end
      end
    end

    const started = since(start, "EmitOnStart")
    const after = finish.at - start

    -- the bolt's 0.3 s is counted in the runtime's frame steps, not by os.clock, and the Glow bolt's EmitOnFinish
    -- landed 1 to 3 ms short of 0.3 s by os.clock (measured 2026-10-24)
    check(`{style}: EmitOnFinish fires once the bolt is gone`, after >= 0.28, `after {after} s`)
    check(`{style}: the bolt drew`, #drawn >= 2, `{#drawn} pieces`)
    check(`{style}: its drawing has left Terrain when EmitOnFinish fires`, left == 0, `{left} of {#drawn} left`)
    check(
      `{style}: an effect the bolt started still plays then`,
      started ~= nil and started.child.Parent == workspace.Terrain
    )
    check(
      `{style}: EmitOnFinish's host sits at the origin`,
      (finish.child.WorldPosition - ref.WorldPosition).Magnitude < 1e-3,
      `{finish.child.WorldPosition}`
    )
  end
end

const function drawingOf(start: number)
  const drawn = {}

  for _, entry in added do
    if entry.at >= start and DRAWING[entry.child.Name] then
      table.insert(drawn, entry.child)
    end
  end

  return drawn
end

const function leftOf(drawn: { Instance })
  local left = 0

  for _, piece in drawn do
    if piece.Parent ~= nil then
      left += 1
    end
  end

  return left
end

-- a bolt whose part is taken out of the place, its attachment left on it, ends at once and fires nothing
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(3)

  const ref = bolt("Away", 150, true, attributes)
  const anchor = ref.Parent :: Instance

  slot(ref, "EmitOnFinish", 0.5)
  table.insert(record.made, anchor)

  const start = os.clock()

  vfx.emit(ref)
  task.wait(0.2)

  const drawn = drawingOf(start)

  anchor.Parent = nil
  task.wait(0.5)

  check("a bolt taken out of the place drew first", #drawn >= 2, `{#drawn} pieces`)
  check("a bolt taken out of the place lets its drawing go", leftOf(drawn) == 0, `{leftOf(drawn)} left`)
  check("a bolt taken out of the place fires no EmitOnFinish", since(start, "EmitOnFinish") == nil)
end

-- a bolt whose End is destroyed keeps the end it had rather than the End's own offset
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(1)

  const ref = bolt("EndGone", 180, true, attributes)
  const start = os.clock()

  vfx.emit(ref)
  task.wait(0.2)

  const light = since(start, "LightningLight")
  const finish = ref:FindFirstChild("End")

  if finish then
    finish:Destroy()
  end

  task.wait(0.3)

  const middle = ref.WorldPosition + Vector3.new(0, -10, 0)
  const at = if light then (light.child :: Attachment).WorldPosition else Vector3.zero

  check("a bolt lights its middle", light ~= nil)
  check(
    "a bolt whose End is destroyed stays where it was",
    (Vector3.new(at.X, 0, at.Z) - Vector3.new(middle.X, 0, middle.Z)).Magnitude < 2 and math.abs(at.Y - middle.Y) < 3,
    `light at {at}, want near {middle}`
  )
end

-- an End bolt with no End warns once for all its bolts and draws nothing
do
  const attributes = table.clone(timing)

  attributes.Count = 3

  const ref = bolt("Missing", 120, false, attributes)
  const start = os.clock()

  vfx.emit(ref)
  task.wait(0.5)

  local drew = 0

  for _, entry in added do
    if entry.at >= start and DRAWING[entry.child.Name] then
      drew += 1
    end
  end

  local warned = 0

  -- the history keeps a fixed number of lines, so it is searched whole for this run's own name
  for _, line in LogService:GetLogHistory() do
    -- a warning reads "on <path>: <text>", a raise puts its source position between the two
    if string.find(line.message, `{ref.Name}: {END_WARNING}`, 1, true) then
      warned += 1
    end
  end

  check("End with no End draws nothing", drew == 0, `{drew} pieces`)
  check("End with no End warns once", warned == 1, `{warned} warnings`)
end

-- what any emit of this run put in Terrain since start, and how many of those are still there
const function madeSince(start: number)
  const made = {}

  for _, entry in added do
    if entry.at >= start then
      table.insert(made, entry.child)
    end
  end

  return made
end

const function finished(env: any)
  const begun = os.clock()

  while env.Finished:getStatus() == "Started" and os.clock() - begun < WAIT_MAX do
    task.wait()
  end

  return env.Finished:getStatus() ~= "Started"
end

const function warnings(ref: Instance, text: string)
  local count = 0

  for _, line in LogService:GetLogHistory() do
    if string.find(line.message, `{ref.Name}: {text}`, 1, true) then
      count += 1
    end
  end

  return count
end

const function folderIn(parent: Instance, name: string): Folder
  const made = Instance.new("Folder")

  made.Name = name
  made.Parent = parent

  return made
end

-- the template the adder makes, from the effect the runtime registered
do
  const loaded, made = pcall(function()
    return vfx.effects.get("forge_lightning").template()
  end)
  const effect = made
  const template = if loaded then made else nil

  for _, name in { "End", "EmitOnImpact", "Bolt", "EmitAlong" } do
    const child = if template then template:FindFirstChild(name) else nil
    const want = if name == "End" then "Attachment" else "Folder"

    check(
      `the template holds {name}`,
      child ~= nil and child.ClassName == want,
      if template then nil else tostring(effect)
    )
  end

  if template then
    template:Destroy()
  end
end

-- three bolts with a Highlight in Bolt share one Highlight over a Model of their three cores, the glows left out
do
  const attributes = table.clone(timing)

  attributes.Count = 3
  attributes.Hold = NumberRange.new(0.4)
  attributes.Disappear = "Fade"
  attributes.DisappearTime = 0.2
  attributes.Light = 0

  const ref = bolt("Highlight", 210, true, attributes)
  const folder = folderIn(ref, "Bolt")
  const template = Instance.new("Highlight")

  template.FillColor = Color3.new(0, 0, 0)
  template.FillTransparency = 0
  template.Parent = folder

  const highlights = {}
  const watch = workspace.Terrain.DescendantAdded:Connect(function(child)
    if child:IsA("Highlight") then
      table.insert(highlights, child)
    end
  end)

  table.insert(record.connections, watch)

  const start = os.clock()
  const env = vfx.emit(ref)

  task.wait(0.25)

  const shown = highlights[1]
  const adornee = if shown then shown.Adornee else nil
  local cores = 0
  local glows = 0

  if adornee then
    for _, piece in adornee:GetChildren() do
      if piece.Name == "LightningCore" then
        cores += 1
      elseif piece.Name == "LightningGlow" then
        glows += 1
      end
    end
  end

  check("a Highlight in Bolt makes one Highlight for the emit", #highlights == 1, `{#highlights} Highlights`)
  check("it adorns a Model", adornee ~= nil and adornee:IsA("Model"), tostring(adornee))
  check("the Model holds the three cores and no glow", cores == 3 and glows == 0, `{cores} cores, {glows} glows`)
  check("the Highlight shows mid hold", shown ~= nil and shown.Enabled, if shown then "off" else "none")

  const done = finished(env)

  watch:Disconnect()

  local left = 0

  for _, child in madeSince(start) do
    if child.Parent ~= nil then
      left += 1
    end
  end

  check("the emit ends", done)
  check("after the emit nothing it made is left in Terrain", left == 0, `{left} left`)
  check("the Highlight is gone after the emit", shown == nil or shown.Parent == nil)
end

-- a Shockwave in Bolt is not played and warns once for every bolt of the emit
do
  const attributes = table.clone(timing)

  attributes.Count = 2

  const ref = bolt("Refused", 240, true, attributes)
  const folder = folderIn(ref, "Bolt")
  const shockwave = Instance.new("Attachment")
  const rings = folderIn(shockwave, "Rings")
  const ring = Instance.new("Part")
  const mark = `LightningRefused{HttpService:GenerateGUID(false)}`

  shockwave.Name = mark
  shockwave:AddTag("Shockwave")
  ring.Name = mark
  ring.Anchored = true
  ring.Parent = rings
  shockwave.Parent = folder

  local played = 0
  const watch = workspace.DescendantAdded:Connect(function(child)
    if child.Name == mark then
      played += 1
    end
  end)

  table.insert(record.connections, watch)

  const env = vfx.emit(ref)

  finished(env)
  task.wait(0.2)
  watch:Disconnect()

  check("a Shockwave in Bolt warns once", warnings(ref, BOLT_WARNING) == 1, `{warnings(ref, BOLT_WARNING)} warnings`)
  check("a Shockwave in Bolt plays nothing", played == 0, `{played} copies`)
end

-- a child that is not Archivable cannot be cloned, so in Bolt or EmitAlong it is named for that, once an emit, and
-- not sent to EmitAlong
do
  const attributes = table.clone(timing)

  attributes.Count = 2

  const ref = bolt("Locked", 420, true, attributes)

  for _, name in { "Bolt", "EmitAlong" } do
    const emitter = Instance.new("ParticleEmitter")

    emitter.Enabled = false
    emitter.Archivable = false
    emitter.Parent = folderIn(ref, name)
  end

  finished(vfx.emit(ref))

  check(
    "a child that is not Archivable warns once to turn Archivable on",
    warnings(ref, LOCKED_WARNING) == 1,
    `{warnings(ref, LOCKED_WARNING)} warnings`
  )
  check(
    "and is not told to go in EmitAlong",
    warnings(ref, BOLT_WARNING) == 0,
    `{warnings(ref, BOLT_WARNING)} warnings`
  )
end

-- in Studio the runtime plays a sound through its own widget, reusing its copies, and Played did not fire for every
-- play there (measured 2026-10-24), so a play is a frame in which a copy of the sound arrives in the widget
const player = PluginGuiService:FindFirstChild(SOUND_PLAYER)
local beat = 0

table.insert(
  record.connections,
  RunService.Heartbeat:Connect(function()
    beat += 1
  end)
)

const function countPlays(mark: string): () -> number
  const frames = {}
  local plays = 0

  if player then
    table.insert(
      record.connections,
      player.DescendantAdded:Connect(function(piece)
        if piece.Name == mark and not frames[beat] then
          frames[beat] = true
          plays += 1
        end
      end)
    )
  end

  return function()
    return plays
  end
end

-- a Sound in EmitAlong plays at each strike and never at a reshape: Restrikes 1 is two strikes over a dozen reshapes
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(0.6)
  attributes.Restrikes = 1
  attributes.Jitter = 20
  attributes.Light = 0

  const ref = bolt("Sound", 270, true, attributes)
  const folder = folderIn(ref, "EmitAlong")
  const sound = Instance.new("Sound")
  const mark = `LightningAlong{HttpService:GenerateGUID(false)}`

  sound.Name = mark
  sound.Volume = 0
  sound.Parent = folder

  const plays = countPlays(mark)

  const start = os.clock()
  const env = vfx.emit(ref)
  const done = finished(env)

  task.wait(0.1)

  local left = 0

  for _, child in madeSince(start) do
    if child.Parent ~= nil then
      left += 1
    end
  end

  check("the runtime's sound player is there", player ~= nil)
  check("a Sound in EmitAlong plays once per strike, not per reshape", plays() == 2, `{plays()} plays`)
  check("the Sound's emit ends", done)
  check("after it nothing it made is left in Terrain", left == 0, `{left} left`)
end

-- an emitter in EmitAlong is emitted again at a restrike even with Jitter 0, when nothing else reshapes; a Sound
-- under it rides the same host, so each emit of the host is a play
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(0.6)
  attributes.Restrikes = 1
  attributes.Jitter = 0
  attributes.Light = 0

  const ref = bolt("Spray", 300, true, attributes)
  const emitter = Instance.new("ParticleEmitter")
  const sound = Instance.new("Sound")
  const mark = `LightningSpray{HttpService:GenerateGUID(false)}`

  emitter.Enabled = false
  emitter.Rate = 0
  emitter.Lifetime = NumberRange.new(0.1)
  sound.Name = mark
  sound.Volume = 0
  sound.Parent = emitter
  emitter.Parent = folderIn(ref, "EmitAlong")

  const plays = countPlays(mark)
  const env = vfx.emit(ref)

  finished(env)
  check("an emitter in EmitAlong is emitted at the strike and again at the restrike", plays() == 2, `{plays()} emits`)
end

-- a Highlight in Bolt fades with the bolt from the artist's transparencies and hides through a restrike's blink, over
-- a core kept opaque while it shows, since a Highlight draws nothing over a part that is not (measured 2026-10-24)
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(0.4)
  attributes.Restrikes = 1
  attributes.Disappear = "Fade"
  attributes.DisappearTime = 0.3
  attributes.Light = 0

  const ref = bolt("Fade", 330, true, attributes)
  const template = Instance.new("Highlight")

  template.FillTransparency = 0.2
  template.OutlineTransparency = 0
  template.Parent = folderIn(ref, "Bolt")

  -- sampled every frame, since a change signal connected once the Highlight arrives missed its first switch on
  -- (measured 2026-10-24)
  const switches = {}
  const fills = {}
  const outlines = {}
  local seeThrough = 0
  local shown: Highlight? = nil
  const watch = workspace.Terrain.DescendantAdded:Connect(function(child)
    if child:IsA("Highlight") then
      shown = child
    end
  end)
  const sampler = RunService.Heartbeat:Connect(function()
    if not shown then
      return
    end

    if switches[#switches] ~= shown.Enabled then
      table.insert(switches, shown.Enabled)
    end

    table.insert(fills, shown.FillTransparency)
    table.insert(outlines, shown.OutlineTransparency)

    if not shown.Enabled or not shown.Parent then
      return
    end

    for _, core in shown.Parent:GetChildren() do
      if core:IsA("BasePart") and core.Transparency > 0 then
        seeThrough += 1
      end
    end
  end)

  table.insert(record.connections, watch)
  table.insert(record.connections, sampler)

  const env = vfx.emit(ref)

  finished(env)
  watch:Disconnect()
  sampler:Disconnect()

  -- shown, hidden for the blink, shown again
  local blinked = false

  for i = 3, #switches do
    if switches[i - 2] and not switches[i - 1] and switches[i] then
      blinked = true
    end
  end

  const function lifted(values: { number }, artist: number)
    for _, value in values do
      if value > artist + 0.05 and value < 0.99 then
        return true
      end
    end

    return false
  end

  const went = {}

  for i, on in switches do
    went[i] = if on then "on" else "off"
  end

  check("the Highlight hides through the restrike's blink", blinked, `Enabled went {table.concat(went, ", ")}`)
  check("the Highlight's fill fades up from the artist's mid fade", lifted(fills, 0.2), `{#fills} frames`)
  check("the Highlight's outline fades up from the artist's mid fade", lifted(outlines, 0), `{#outlines} frames`)
  check("a core under a showing Highlight stays opaque", seeThrough == 0, `{seeThrough} frames`)
end

-- three bolts under one Highlight, each with its own appear and hold, start to disappear at one moment: each core
-- leaves Transparency 0 halfway through a linear Fade, so the three times match
do
  const attributes = table.clone(timing)

  attributes.Count = 3
  attributes.Appear = "Strike"
  attributes.AppearTime = NumberRange.new(0.02, 0.15)
  attributes.Hold = NumberRange.new(0.1, 0.5)
  attributes.Disappear = "Fade"
  attributes.DisappearTime = 0.3
  attributes.DisappearCurve = "linear"
  attributes.Light = 0

  const ref = bolt("Together", 360, true, attributes)
  const template = Instance.new("Highlight")

  template.FillTransparency = 0
  template.Parent = folderIn(ref, "Bolt")

  const left = {}
  local model: Instance? = nil
  local env: any = nil
  const watch = workspace.Terrain.DescendantAdded:Connect(function(child)
    if child:IsA("Highlight") then
      model = child.Parent
    end
  end)
  const sampler = RunService.Heartbeat:Connect(function()
    if not model or not env then
      return
    end

    for _, core in (model :: Instance):GetChildren() do
      if core:IsA("BasePart") and core.Transparency > 0 and left[core] == nil then
        left[core] = env:GetTime()
      end
    end
  end)

  table.insert(record.connections, watch)
  table.insert(record.connections, sampler)

  env = vfx.emit(ref)
  finished(env)
  watch:Disconnect()
  sampler:Disconnect()

  local first = math.huge
  local last = -math.huge
  local seen = 0

  for _, at in left do
    seen += 1
    first = math.min(first, at)
    last = math.max(last, at)
  end

  check(
    "three bolts under one Highlight start to disappear together",
    seen == 3 and last - first < 0.02,
    `{seen} cores, {string.format("%.3f", last - first)} s apart`
  )
end

-- a Jitter bolt with no Highlight keeps reshaping while it thins; a ring's middle is its joint whatever the width,
-- so a moved middle is a new shape
do
  const attributes = table.clone(timing)

  attributes.Hold = NumberRange.new(0.1)
  attributes.Jitter = 30
  attributes.Disappear = "Thin"
  attributes.DisappearTime = 0.5
  attributes.Light = 0

  const ref = bolt("Thinning", 390, true, attributes)
  local core: MeshPart? = nil
  local env: any = nil
  local last: Vector3? = nil
  local shapes = 0
  const watch = workspace.Terrain.ChildAdded:Connect(function(child)
    if child.Name == "LightningCores" and not core then
      task.defer(function()
        core = child:FindFirstChildWhichIsA("MeshPart")
      end)
    end
  end)
  const sampler = RunService.Heartbeat:Connect(function()
    if not core or not env then
      return
    end

    const at = env:GetTime()
    const mesh = (core :: MeshPart).MeshContent.Object :: EditableMesh?

    if not mesh or at < 0.15 or at > 0.55 then
      return
    end

    const ids = mesh:GetVertices()
    local middle = Vector3.zero

    for i = 41, 45 do
      middle += mesh:GetPosition(ids[i])
    end

    middle /= 5

    if last and (middle - last).Magnitude > 1e-3 then
      shapes += 1
    end

    last = middle
  end)

  table.insert(record.connections, watch)
  table.insert(record.connections, sampler)

  env = vfx.emit(ref)
  finished(env)
  watch:Disconnect()
  sampler:Disconnect()

  check("a Jitter bolt with no Highlight reshapes while it thins", shapes >= 5, `{shapes} reshapes`)
end

clean()

const output = table.concat(lines, "\n")

if failed then
  error(`finish check failed\n{output}`, 0)
end

return output
