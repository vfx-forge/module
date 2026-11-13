local PluginGuiService = game:GetService("PluginGuiService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")

local timing_common = require("@mod/common/timing")

local pool = require("@srv/pool")
local containers = require("@srv/containers")

local rng = Random.new()

-- an asset that has not loaded reports a TimeLength of 0, which ends the
-- clone's timer about two frames in; the wait is bounded so a missing asset
-- still lets the emit finish
local LOAD_TIMEOUT = 5

local sound = {}

sound.id = "sound"
sound.display = { name = "Sound", icon = "sound", order = 70 }
sound.classifier = "Sound"
sound.copies = true

sound.attributes = {
  EmitCount = knob(1)
    :min(0)
    :label("Count")
    :hint("How many sounds to play, each drawn from the sound pool when the sound has one."),
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0)
    :min(0)
    :unit("seconds")
    :label("StopAfter")
    :hint("Seconds each sound plays before it is stopped, 0 to play it to its end."),
  EmitInterval = knob(NumberRange.new(0, 0))
    :min(0)
    :unit("seconds")
    :label("Interval")
    :hint("Seconds between one sound and the next."),
  RepeatCount = knob(1):min(0):label("RepeatCount"):hint("How many times each drawn sound plays."),
  RepeatInterval = knob(NumberRange.new(0, 0))
    :min(0)
    :unit("seconds")
    :label("RepeatInterval")
    :hint("Seconds between the plays of one drawn sound."),
  SoundPoolTag = knob(""):label("Name"):hint("CollectionService tag grouping sounds into a shared random pool."),
  SoundPoolWeight = knob(1):min(0):label("Rarity"):hint("Weight for random selection in sound pools."),
  SoundPoolIsSource = knob(false):label("IsSource"):hint("Whether this sound is the pool's source."),
  SoundPoolInheritAttributes = knob(false)
    :label("InheritAttributes")
    :hint("Whether the played clone inherits the pooled sound's attributes."),
}

-- the clone's own properties are its state; the old attribute names are the
-- rows' aliases, so an old quad or queue under them folds in
sound.properties = {
  Volume = knob():mod():label("Volume"):hint("Volume each played clone starts at."),
  PlaybackSpeed = knob():aliases("Speed"):mod():label("Speed"):hint("Playback speed each played clone starts at."),
  RollOffMinDistance = knob()
    :aliases("RollOff")
    :unit("studs")
    :mod()
    :label("RollOff")
    :hint("Distance in studs the clone plays at full volume within."),
}

-- the plugin's card. a property row, or a `property` entry, is the sound's own
-- property, which the card moves there from its engine category. groups and
-- rows run in the order Studio's own Properties widget lists them
sound.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitInterval" } },
  {
    title = "Emitter",
    entries = { "RollOffMinDistance", { property = "RollOffMaxDistance" }, { property = "RollOffMode" } },
  },
  {
    title = "Playback",
    entries = {
      { property = "Looped" },
      "PlaybackSpeed",
      { property = "PlayOnRemove" },
      { property = "SoundId" },
      "EmitDuration",
      "Volume",
    },
  },
  {
    title = "Regions",
    entries = { { property = "LoopRegion" }, { property = "PlaybackRegion" }, { property = "PlaybackRegionsEnabled" } },
  },
}

-- the pool and the repeats of what it draws, a card of their own
sound.cards = {
  ["Sound Pool"] = {
    {
      title = "Pool",
      entries = { "SoundPoolTag", "SoundPoolWeight", "SoundPoolIsSource", "SoundPoolInheritAttributes" },
    },
    { title = "Repeat", entries = { "RepeatCount", "RepeatInterval" } },
  },
}

-- the asset's own length, which an asset that has not loaded reports as zero
-- and the reader then maps to one. a host without the engine's sound clock
-- answers nothing, which the reader reads the same way
function sound.duration(ctx: reader.Ctx)
  local ok, length = pcall(function()
    return (ctx.ref :: Sound).TimeLength
  end)

  return if ok then length else nil
end

-- process wide rather than per plugin instance: the launcher keeps two payload
-- generations alive at once, so init runs while the outgoing one still holds a
-- widget under this id
local WIDGET_ID = "VFXForgeSoundPlayer"

local soundWidget: DockWidgetPluginGui?
local shut: RBXScriptConnection?
local emitterTemplate: Part?

-- the widget only holds sounds and is never shown, but another plugin
-- switched every plugin gui on once and it opened as an empty window
local function keepShut(widget: DockWidgetPluginGui)
  widget.Enabled = false

  shut = widget:GetPropertyChangedSignal("Enabled"):Connect(function()
    if widget.Enabled then
      widget.Enabled = false
    end
  end)
end

local function clearClones(widget: DockWidgetPluginGui)
  for _, child in widget:GetChildren() do
    child:Destroy()
  end
end

local function selectRandomSound(ref: Sound, poolTag: string): Sound?
  if poolTag == "" then
    return ref
  end

  local sounds = CollectionService:GetTagged(poolTag)

  local weights: { number } = {}
  local validSounds: { Sound } = {}

  local totalWeight = 0

  -- a sound a custom effect classifies is that effect's to play, never a draw
  for _, obj in sounds do
    if not obj:IsA("Sound") or registry.of(obj) ~= sound then
      continue
    end

    table.insert(validSounds, obj)

    -- a pool member is somebody else's instance, and a weight it never
    -- authored is this draw's business alone, so the read stamps nothing
    local weight = attr.get(obj, "SoundPoolWeight", 1, true)

    table.insert(weights, weight)
    totalWeight += weight
  end

  if #validSounds == 0 then
    return ref
  end

  if totalWeight > 0 then
    local roll = rng:NextNumber() * totalWeight
    local accumulated = 0

    for i, weight in weights do
      accumulated += weight

      if roll <= accumulated then
        return validSounds[i]
      end
    end
  end

  return validSounds[rng:NextInteger(1, #validSounds)]
end

-- each copy is held by `held`, which the clone's thread lets go once it ends
local function createSoundClone(ref: Sound, sourceSound: Sound, held: { any }): (Sound, Part?)
  local clone = pool.take(held, sourceSound) :: Sound

  local parent = ref:FindFirstAncestorWhichIsA("BasePart")

  local partClone

  if utility.PLUGIN_CONTEXT then
    if parent and emitterTemplate then
      partClone = pool.take(held, emitterTemplate, true) :: Part
      partClone.CFrame = parent.CFrame
      partClone.Parent = soundWidget

      clone.Parent = partClone
    else
      clone.Parent = soundWidget
    end
  else
    if parent then
      clone.Parent = parent
    else
      clone.Parent = containers.of("sound")
    end
  end

  return clone, partClone
end

-- one clone played to its end: its three tracks are seeded from its own
-- properties once it has loaded, over its own asset length, through the rows
-- of whichever sound the emit reads
local function play(ctx: reader.Ctx, props: any, clone: Sound, partClone: Part?, emitDuration: number, held: { any })
  local ref = ctx.ref :: Sound
  local scope = ctx.scope

  if clone.SoundId ~= "" and not clone.IsLoaded then
    local waited = 0

    while not clone.IsLoaded and waited < LOAD_TIMEOUT and clone.Parent do
      waited += lifetime.wait(scope, 0.05)
    end

    if not clone.Parent then
      return
    end
  end

  -- the rows read the clone's properties as the state they start from (a
  -- drawn pool sound's rows read that sound's, which the clone was copied
  -- from); the three calls below run without a yield between them, so no
  -- other clone of this emit can move the seam in the meantime
  ctx.obj = clone

  -- the clone's writers end before `held` gives it back
  if ctx.copied then
    ctx.copied(clone, held)
  end

  local volume = props.Volume(nil, clone.TimeLength)
  local speed = props.PlaybackSpeed(nil, clone.TimeLength)
  local rolloff = props.RollOffMinDistance(nil, clone.TimeLength)

  -- the sound's own time runs at its PlaybackSpeed on the effect's clock, and
  -- what it plays at is that times the clock, set once it plays
  local currentSpeed = clone.PlaybackSpeed
  local setPlayback = nil :: ((speed: number) -> ())?
  local releasePlayback = nil :: (() -> ())?

  -- what writes the clone every frame, cut when this returns, since the clone
  -- goes back to the pool then and may serve another effect
  local writers: { scheduler.Handle } = {}

  -- a row sampled on the sound's own time, its first value at once and then
  -- one a frame until that time reaches the row's end
  local function heard(row: reader.Track, write: (v: any) -> ())
    write(row.at(0))

    if not row.animated then
      return
    end

    local at = 0
    local handle

    handle = lifetime.step(scope, function(deltaTime: number)
      at = math.min(at + deltaTime * currentSpeed, row.duration)
      write(row.at(at))

      if at >= row.duration then
        handle:Disconnect()
      end
    end)

    table.insert(writers, handle)
  end

  heard(volume, function(v: any)
    clone.Volume = v
  end)

  currentSpeed = speed.at(0)
  clone.PlaybackSpeed = currentSpeed

  local speeding = tween.drive(scope, speed, function(v: any)
    currentSpeed = v

    if setPlayback then
      setPlayback(v)
    end
  end)

  heard(rolloff, function(v: any)
    clone.RollOffMinDistance = v
  end)

  if clone.PlayOnRemove and not utility.PLUGIN_CONTEXT then
    clone:Destroy()
  else
    clone:Play()
    setPlayback, releasePlayback = adapters.sound(scope, clone, currentSpeed)
  end

  if partClone then
    local parent = ref:FindFirstAncestorWhichIsA("BasePart")

    if parent then
      table.insert(
        writers,
        lifetime.step(scope, function()
          if partClone.Parent then
            partClone.CFrame = parent.CFrame
          end
        end, "follow")
      )
    end
  end

  if emitDuration > 0 then
    lifetime.wait(scope, emitDuration)
    clone:Stop()
  else
    -- the sound's own time run out to its length. it is not over while its
    -- speed is still moving, and a speed of 0 ends it unless one is
    local lasts = timing_common.duration(clone.TimeLength)
    local played = lifetime.join(scope)
    local counted = lifetime.add(played)
    local at = 0
    local handle

    handle = lifetime.step(scope, function(deltaTime: number)
      local moving = speeding ~= nil and speeding.Connected
      local stopped = currentSpeed <= 0 and not (at > 0 and moving)

      if (stopped or timing_common.done(at, lasts)) and not moving then
        handle:Disconnect()
        counted()
        return
      end

      if not stopped then
        at += deltaTime * currentSpeed
      end
    end)

    lifetime.awaitJoin(played)
  end

  -- the clone goes when this returns, so the clock has nothing more to tell it
  if releasePlayback then
    releasePlayback()
    setPlayback = nil
  end

  for _, handle in writers do
    handle:Disconnect()
  end
end

function sound.init()
  if not utility.PLUGIN_CONTEXT then
    return
  end

  local template = Instance.new("Part")
  template.Name = "SoundEmitter"
  template.Anchored = true
  template.CanCollide = false
  template.CanQuery = false
  template.CanTouch = false
  template.Transparency = 1
  template.Size = Vector3.one

  emitterTemplate = template

  local plugin = if script ~= nil then script:FindFirstAncestorOfClass("Plugin") else nil

  if not plugin then
    return
  end

  -- adopt before creating: a widget still standing belongs to the generation on
  -- its way out, and creating over it throws out of the require, which the
  -- launcher reports as the whole bundle failing to boot
  local existing = PluginGuiService:FindFirstChild(WIDGET_ID)

  if existing and existing:IsA("DockWidgetPluginGui") then
    soundWidget = existing

    clearClones(existing)
    keepShut(existing)

    return
  end

  soundWidget = plugin:CreateDockWidgetPluginGui(
    WIDGET_ID,
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 200, 100, 100, 50)
  )

  if soundWidget then
    soundWidget.Name = WIDGET_ID
    keepShut(soundWidget)
  end
end

function sound.deinit()
  -- clones only, never the widget: the incoming generation has already adopted
  -- it by the time this runs, and destroying it would leave that generation
  -- with a dead parent and no audible sound
  if shut then
    shut:Disconnect()
    shut = nil
  end

  if soundWidget then
    clearClones(soundWidget)

    soundWidget = nil
  end

  if emitterTemplate then
    emitterTemplate:Destroy()

    emitterTemplate = nil
  end
end

function sound.emit(ctx: reader.Ctx, attrs: any, props: any)
  local scope = ctx.scope

  if attrs.EmitCount <= 0 then
    return
  end

  local ref = ctx.ref :: Sound

  if ref.Playing then
    ref:Stop()
  end

  local isSource = attrs.SoundPoolIsSource
  local inherit = attrs.SoundPoolInheritAttributes

  -- with inheritance on, the pool is drawn once and the emit is the drawn
  -- sound's in every respect, its rows read through its own module
  if inherit and not isSource then
    local picked = selectRandomSound(ref, attrs.SoundPoolTag)

    if picked ~= nil and picked ~= ref then
      local pickedAttrs, pickedProps = registry.read(picked)

      if pickedAttrs ~= nil then
        ref = picked
        attrs, props = pickedAttrs, pickedProps

        -- rows read through the registry keep the context they were read
        -- with, so play's ctx.obj = clone below never moves their seed there,
        -- which is fine since the clone is a copy of the sound they read
        ctx = {
          ref = picked,
          obj = picked,
          scope = scope,
          effect = ctx.effect,
          shared = ctx.shared,
          copied = ctx.copied,
        }
      end
    end
  end

  local emitDuration = attrs.EmitDuration
  local emitCount = attrs.EmitCount
  local emitInterval = attrs.EmitInterval

  local repeatCount = attrs.RepeatCount
  local repeatInterval = attrs.RepeatInterval

  lifetime.wait(scope, attrs.EmitDelay)

  -- each clone plays on a thread the effect holds, so a clear closes it
  local clones = lifetime.join(scope)

  for i = 1, emitCount do
    local sourceSound = if inherit or isSource then ref else selectRandomSound(ref, attrs.SoundPoolTag)

    if not sourceSound then
      continue
    end

    for r = 1, repeatCount do
      lifetime.spawn(clones, function()
        local held = lifetime.hold(scope, {})
        local clone, partClone = createSoundClone(ref, sourceSound, held)

        play(ctx, props, clone, partClone, emitDuration, held)

        lifetime.releasePlain(held)
      end)

      if r < repeatCount and repeatInterval.Max > 0 then
        lifetime.wait(scope, rng:NextNumber(repeatInterval.Min, repeatInterval.Max))
      end
    end

    if i < emitCount and emitInterval.Max > 0 then
      lifetime.wait(scope, rng:NextNumber(emitInterval.Min, emitInterval.Max))
    end
  end

  lifetime.awaitJoin(clones)
end

return sound
