-- The license is placed inside a string in order for it to be preserved when the code is decompiled
-- Even if the engine retains the entire string in memory, it's only around 3.5kB
local _ = [[
Preamble.
Disclaimer: nothing stated in this preamble is legal advice.

This is a simple license that allows anyone to use the emit module in their Roblox games.

1. You cannot use the module in anything that isn't a Roblox game. For example, it means
that you cannot create a plugin using this module.

2. You are allowed to use the module commercially in your games.

3. You are free to share the module with other developers so they can use it in their games,
as long as the license is retained.

4. You can modify and share the module as long as you follow the terms of the license. All
derivates of the module must have the same license.

5. If you break the terms and conditions of the license, you are required to stop the use and
distribution of the module immediately.

End of preamble.

VFX Forge Developer License (VFX-DL) Version 1.1

Copyright (c) 2025 zilibobi

1. Definitions.
   - "Module" means the source code and any compiled form of the Emit Module.
   - "You" means any individual or organization exercising the rights granted herein.
   - "Derivative Work" means any work based upon or incorporating the Module.
   - "Roblox Experience" means a user-facing game or simulation that runs on the
   Roblox platform, created using Roblox Studio and played via the Roblox client.

2. Grant of Rights.
   Permission is hereby granted, free of charge, to You to use, reproduce,
   prepare Derivative Works of, publicly display, publicly perform, sublicense,
   and distribute the Module, **solely when embedded in the runtime environment of
   a Roblox Experience** (including playtesting in Roblox Studio), and **not** when
   loaded by any Roblox Studio plugin or other developer tool, running in any context
   that has access to API methods or permissions unavailable to runtime scripts within
   Roblox Experiences (excluding the Roblox Studio command bar feature, when used for
   the purpose of viewing finished effects). You may distribute the Module or Derivative
   Work to other developers, provided they use it only within the permitted runtime
   context described above.

3. Conditions.
   a. Copyleft.
       Any Derivative Work, including modified or extended versions of the Module, that
       You distribute must be licensed under the exact same terms as this VFX-DL.
   b. Redistribution.
       You must include a copy of this license text with any distribution of the Module or Derivative Work.
   c. No Other Contexts.
       You may not embed, load, or distribute the Module within any Roblox Studio
       plugin, editor extension, command-line tool, test harness, or any code running
       under Studio outside of normal game runtime.

4. Disclaimer of Warranty.
    The Module is provided "AS IS," without warranty of any kind, express or implied,
    including but not limited to the warranties of merchantability, fitness for a
    particular purpose, and noninfringement.

5. Limitation of Liability.
    In no event shall the authors or copyright holders be liable for any claim,
    damages, or other liability arising from, out of, or in connection with the
    Module or the use or other dealings in the Module.

6. Termination.
    If You violate the terms of this License, Your rights under this VFX-DL will
    terminate automatically. Upon termination, You must cease all use and distribution
    of the Module and any Derivative Works.

7. Versioning.
    This license applies to Version 1.1 of the VFX-DL. Future versions may be published
    by the copyright holder.

8. Commercial use.
    This License permits commercial use within the scope defined in Section 2.

9. Trademarks and branding.
    Nothing in this License grants permission to use the trade names, trademarks, service marks,
    or product names of the Licensor.
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local clock = require("@mod/clock")
local logger = require("@mod/logger")
local retime = require("@mod/retime")
local resize = require("@mod/resize")
local recolor = require("@mod/recolor")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local attributes = require("@mod/attributes")

local Beam = require("@vfx/beam")
local Mesh = require("@vfx/mesh")
local Spin = require("@vfx/spin")
local Sound = require("@vfx/sound")
local Trail = require("@vfx/trail")
local Bezier = require("@vfx/bezier")
local Screen = require("@vfx/screen")
local Particle = require("@vfx/particle")
local Animator = require("@vfx/animator")
local Controller = require("@vfx/controller")
local Lightning = require("@vfx/lightning")
local Shockwave = require("@vfx/shockwave")
local CameraShake = require("@vfx/camera_shake")
local ShockwaveRing = require("@vfx/shockwave_ring")
local ShockwaveLine = require("@vfx/shockwave_line")
local ShockwaveDebris = require("@vfx/shockwave_debris")

local pool = require("@srv/pool")
local mover = require("@srv/mover")
local effects = require("@srv/effects")
local containers = require("@srv/containers")
local texture_loader = require("@srv/texture_loader")
local enabled_effects = require("@srv/enabled_effects")

local watch = require("@root/sdk/watch")

local PluginContext = utility.PLUGIN_CONTEXT
local ServerContext = utility.SERVER_CONTEXT

-- `discover` false leaves tagged custom effects to a host that registers them
-- itself, as the plugin does to reload them as they are edited
type params = { discover: boolean? }

local api = {}

api.scope = {}
api.setup = false

local warnedScale = false

-- the built-ins register once, when the module loads
registry.register(Beam)
registry.register(Trail)
registry.register(Particle)
registry.register(Spin)
registry.register(Screen)
registry.register(CameraShake)
registry.register(Sound)
registry.register(Shockwave)
registry.register(ShockwaveRing)
registry.register(ShockwaveLine)
registry.register(ShockwaveDebris)
registry.register(Bezier)
registry.register(Lightning)
registry.register(Mesh)
registry.register(Controller)
registry.register(Animator)

function api.init(params: params?)
  if api.setup then
    return
  end

  if ServerContext then
    task.spawn(function()
      local done = false
      local tries = 0

      local lastErr

      repeat
        tries += 1

        local ok, err = pcall(utility.setCollisionGroups, utility.COLLISION_GROUPS)

        done = ok
        lastErr = err

        if not done then
          task.wait(tries)
        end
      until done or tries >= 5

      if not done then
        logger.warn(
          `couldn't register necessary collision groups after {tries} tries with the last error being: {lastErr}`
        )
      end
    end)
  end

  api.setup = true

  if params == nil or params.discover ~= false then
    watch.start()
  end

  if RunService:IsServer() and not PluginContext then
    return
  end

  scheduler.start()

  pool.init(api.scope)

  shared.vfx = api

  -- init services
  effects.init(api)

  texture_loader.init(api.scope)
  enabled_effects.init(api.scope, effects)

  -- init effects
  Sound.init()
  CameraShake.init()
  ShockwaveDebris.init()
end

function api.deinit()
  if not api.setup then
    return
  end

  api.setup = false

  shared.vfx = nil

  watch.stop()

  if RunService:IsServer() and not PluginContext then
    return
  end

  -- the live emits are cleared first, while the pool their parts go back to
  -- still stands, a loop's ticks among them
  effects.deinit()
  enabled_effects.clear()

  utility.cleanupScope(api.scope)

  mover.clear()

  Sound.deinit()
  CameraShake.deinit()
  ShockwaveDebris.deinit()

  -- after the shake has put the camera back, and before the plugin unloads, so
  -- no effect resumes into what is torn down
  scheduler.stop()

  local cleanupObjects = CollectionService:GetTagged(utility.CLEANUP_TAG)

  for _, obj in cleanupObjects do
    obj:Destroy()
  end

  -- last, with everything above let go, so what a teardown missed goes with it
  containers.clear()
end

local function fullEmit(depth: number, ...: any)
  if not api.setup then
    logger.error("not initialized")
  end

  return effects.emit(depth, ...)
end

-- a leading number was the old scale argument, which never reached an effect
function api.emit(...: any)
  if type((...)) ~= "number" then
    return fullEmit(0, ...)
  end

  if not warnedScale then
    warnedScale = true
    logger.warn("the scale argument was removed from emit and is ignored, pass the instances alone")
  end

  return fullEmit(0, select(2, ...))
end

function api.emitWithDepth(depth: number, ...: Instance)
  return fullEmit(depth, ...)
end

-- the seconds of one frame an emit may spend starting its effects before the
-- rest wait for the next frame; nil or 0 starts every effect in the call
function api.setBudget(seconds: number?)
  if seconds ~= nil and (type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge) then
    logger.warn(`setBudget takes a finite number of seconds or nil, not {seconds}`)
    return
  end

  effects.budget = seconds
end

function api.getBudget(): number?
  return effects.budget
end

function api.cacheAttributes(obj: Instance, shallow: boolean)
  if utility.SERVER_CONTEXT then
    logger.error("attributes can only be cached in a client-side context")
  end

  if not obj:IsDescendantOf(ReplicatedStorage) then
    logger.error("attributes can only be cached for VFX inside ReplicatedStorage")
  end

  attributes.cache(obj)

  if shallow then
    return
  end

  for _, v in obj:GetDescendants() do
    attributes.cache(v)
  end
end

function api.restoreAttributes(obj: Instance, shallow: boolean?)
  if utility.SERVER_CONTEXT then
    logger.error("attributes can only be restored in a client-side context")
  end

  attributes.restore(obj)

  if shallow then
    return
  end

  for _, v in obj:GetDescendants() do
    attributes.restore(v)
  end
end

-- an emitter or beam a custom effect classifies is that effect's, switched
-- through its row like any other
local function setEnabled(obj: Instance, enabled: boolean)
  local module = registry.of(obj)

  if module == Particle or module == Beam then
    (obj :: any).Enabled = enabled
    return
  end

  enabled_effects.switch(obj, enabled)
end

function api.enable(obj: Instance)
  setEnabled(obj, true)

  for _, v in obj:GetDescendants() do
    setEnabled(v, true)
  end
end

function api.disable(obj: Instance)
  setEnabled(obj, false)

  for _, v in obj:GetDescendants() do
    setEnabled(v, false)
  end
end

function api.retime(factor: number, ...: Instance)
  retime.batch(factor, ...)
end

function api.resize(factor: number, ...: Instance)
  resize.batch(factor, ...)
end

function api.recolor(color: Color3, mode: "replace" | "multiply", ...: Instance)
  recolor(color, mode, ...)
end

-- what is registered, built-in and custom, to read and never to change
api.effects = table.freeze({
  list = function()
    return registry.list()
  end,

  get = function(id: string)
    return registry.get(id)
  end,
})

function api.setSpeed(speed: number)
  clock.setGlobalSpeed(clock.checked(speed, "setSpeed"))
end

-- the speed set, which a pause leaves as it is
function api.getSpeed()
  return clock.global.speed
end

function api.pause()
  clock.setGlobalPaused(true)
end

function api.resume()
  clock.setGlobalPaused(false)
end

function api.isPaused()
  return clock.global.paused
end

-- the global speed times every Global controller, whether paused or not
function api.getEffectiveSpeed()
  return clock.effective()
end

api.SpeedChanged = clock.speedChanged
api.PausedChanged = clock.pausedChanged

-- the value ForgeVFX would write to a property, read in place of having it
-- written until the hook disconnects. the current camera's CFrame is the
-- camera shake's
function api.hookProperty(obj: Instance, property: string)
  if obj == workspace.CurrentCamera and property == "CFrame" then
    return CameraShake.hook()
  end

  return lifetime.hook(obj, "property", property)
end

function api.hookAttribute(obj: Instance, name: string)
  return lifetime.hook(obj, "attribute", name)
end

return api
