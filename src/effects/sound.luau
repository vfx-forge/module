local PluginGuiService = game:GetService("PluginGuiService")

local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local reader = require("@mod/reader")
local utility = require("@mod/utility")

local sound = {}

-- process wide rather than per plugin instance: the launcher keeps two payload
-- generations alive at once, so init runs while the outgoing one still holds a
-- widget under this id
local WIDGET_ID = "VFXForgeSoundPlayer"

local soundWidget: DockWidgetPluginGui?
local shut: RBXScriptConnection?
local emitterTemplate: Part?

const play = lazy.unit("sound", function()
  return require("@root/play/sound").bind(sound, function()
    return soundWidget, emitterTemplate
  end)
end)

sound.id = "sound"
sound.display = { name = "Sound", icon = "sound", order = 70 }
sound.classifier = "Sound"
sound.copies = true

sound.attributes = {
  EmitCount = knob(1)
    :min(0)
    :label("Count")
    :hint("How many sounds to play, each drawn from the sound pool when the sound has one."),
  EmitDelay = knob(0):min(0):unit("seconds"):ranged():label("Delay"):hint("Seconds before the effect starts emitting."),
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

-- the widget only holds sounds and is never shown, but another plugin
-- switched every plugin gui on once and it opened as an empty window
local function keepShut(widget: DockWidgetPluginGui)
  widget.Enabled = false

  if shut then
    shut:Disconnect()
  end

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

function sound.emit(ctx: any, attrs: any, props: any)
  return play().emit(ctx, attrs, props)
end

return sound
