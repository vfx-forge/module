local clock = require("@mod/clock")
local value = require("@mod/value")
local roblox = require("@lune/roblox")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local retime = require("@mod/retime")
local spin = require("@vfx/spin")
local test, expect = harness.test, harness.expect

frame.configure(harness.fakeEncoding, harness.fakeCompression)

-- lune's Model has no pivot or scale of its own
const SCALE: { [Instance]: number } = {}
const PIVOT: { [Instance]: CFrame } = {}

roblox.implementMethod("Model", "GetScale", function(m: Instance)
  return SCALE[m] or 1
end)

roblox.implementMethod("Model", "ScaleTo", function(m: Instance, s: number)
  SCALE[m] = s
end)

roblox.implementMethod("Model", "GetPivot", function(m: Instance)
  return PIVOT[m] or CFrame.new()
end)

roblox.implementMethod("Model", "PivotTo", function(m: Instance, cf: CFrame)
  PIVOT[m] = cf
end)

-- frames of 1/32 s, sampled every 0.25 s
const FRAME = 1 / 32
const EVERY = 8

-- how far the pre-change spin had turned, 0 to 1 of SpinRotation times
-- SpinDuration, every 0.25 s of real time, played under the frames above. it
-- has turned all the way from the first sample past each list on
const TURNED = {
  -- his: SpinDuration 2, SpinSpeed 1 ramping in over SpinSpeed_Duration 2
  ramped = {
    0.024316631,
    0.086081244,
    0.173866658,
    0.278029851,
    0.392244711,
    0.512447351,
    0.635915656,
    0.760737287,
    0.885737338,
  },
  -- an unauthored speed, 0 to 1 over the default 0.1 s
  plain = { 0.119262692, 0.244262686, 0.369262718, 0.494262655, 0.619262782, 0.744262719, 0.869262618, 0.994262821 },
  -- SpinSpeed 2 ramping in over 0.5 s
  fast = { 0.148935880, 0.391654051, 0.641654001, 0.891653951 },
  -- SpinDuration 1.5, ResetDelay 0.5, a stored speed lane 0.5 to 1.5 over 1 s
  laned = { 0.106770826, 0.255208330, 0.445312511, 0.677083331, 0.927083357 },
  -- SpinDuration and the speed left unset, ResetOnFinish on
  unset = { 0.477050616, 0.977050820 },
}

local function tween(a: number, b: number, opts: { [string]: any }?)
  const m: { [string]: any } = { kind = "tween", chain = false, start = value.lit(a), finish = value.lit(b) }

  for k, v in opts or {} do
    m[k] = v
  end

  return m
end

local function framed(lanes: { [string]: { any } }): string
  return frame.frame(codec.encode({ lanes = lanes }))
end

-- his Scale: up from nearly nothing over the spin, then a quarter of it back
-- down from wherever it stands
const SCALE_LANES = {
  start = { tween(0.001, 1, { seedable = true }) },
  ["end"] = { { kind = "tween", chain = true, finish = value.lit(0.001), share = 0.25 } },
}

-- the scale his lanes give at `t` seconds of the spin's own effect time
local function scaleAt(t: number): number
  if t <= 1.5 then
    return 0.001 + 0.999 * t / 2
  end

  const from = 0.001 + 0.999 * 0.75

  return from + (0.001 - from) * math.min((t - 1.5) / 0.5, 1)
end

local function model(attrs: { [string]: any }, mods: { [string]: { [string]: { any } } }?): Model
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(spin)

  const m = harness.make("Model", harness.make("Folder")) :: Model
  harness.make("Part", m)

  m:SetAttribute("ResetOnFinish", false)

  for k, v in attrs do
    m:SetAttribute(k, v)
  end

  for name, lanes in mods or {} do
    m:AddTag("ForgeModifiers")
    m:SetAttribute(`ForgeAttrMods_{name}`, framed(lanes))
  end

  return m
end

type Sample = { t: number, scale: number, pivot: CFrame, running: boolean }

-- emits the model and samples it every 0.25 s for `seconds`
local function play(m: Model, seconds: number, before: ((env: any) -> ())?): { Sample }
  const env = effects.emit(0, m)

  if before ~= nil then
    before(env)
  end

  const finished = env.Finished
  const out = {}

  for i = 1, math.round(seconds / FRAME) do
    scheduler.frame(FRAME)

    if i % EVERY == 0 then
      table.insert(out, {
        t = i * FRAME,
        scale = SCALE[m] or 1,
        pivot = PIVOT[m] or CFrame.new(),
        running = finished:getStatus() == "Started",
      })
    end
  end

  effects.deinit()

  return out
end

local function near(a: number, b: number, what: string)
  assert(math.abs(a - b) < 1e-4, `{what}: expected {b}, got {a}`)
end

local function samePose(a: CFrame, b: CFrame, what: string)
  const x = { a:GetComponents() }
  const y = { b:GetComponents() }

  for i = 1, 12 do
    assert(math.abs(x[i] - y[i]) < 1e-4, `{what}: pose off by {math.abs(x[i] - y[i])} in component {i}`)
  end
end

-- the pose the pre-change spin left a model turning `rate` degrees a second
-- for `duration` at `turned` of the way
local function poseAt(rate: Vector3, duration: number, turned: number): CFrame
  const r = rate * duration * turned * math.pi / 180

  return CFrame.fromOrientation(r.X, r.Y, r.Z)
end

-- models saved as a rate, each with how far the pre-change spin had turned
-- every 0.25 s and where it stood once that list ran out
const RATED = {
  {
    turned = TURNED.ramped,
    attrs = {
      SpinDuration = 2,
      SpinRotation = Vector3.new(360, 360, 360),
      SpinSpeed = 1,
      SpinSpeed_Duration = 2,
    },
  },
  { turned = TURNED.plain, attrs = { SpinDuration = 2, SpinRotation = Vector3.new(0, 45, 0) } },
  {
    turned = TURNED.fast,
    attrs = {
      SpinDuration = 2,
      SpinRotation = Vector3.new(20, 45, -10),
      SpinSpeed = 2,
      SpinSpeed_Duration = 0.5,
    },
  },
  {
    turned = TURNED.laned,
    attrs = { SpinDuration = 1.5, ResetDelay = 0.5, SpinRotation = Vector3.new(0, 60, 0) },
    mods = { SpinSpeed = { start = { tween(0.5, 1.5, { duration = 1 }) } } },
  },
  -- no duration stored, so the default half second, and put back at the end
  { turned = TURNED.unset, rest = 0, attrs = { ResetOnFinish = true, SpinRotation = Vector3.new(0, 180, 0) } },
}

local function poseOf(setup: any, i: number): CFrame
  const turned = setup.turned[i] or setup.rest or 1

  return poseAt(setup.attrs.SpinRotation, setup.attrs.SpinDuration or 0.5, turned)
end

harness.suite(function()
  harness.describe("a spin model's clocks", function()
    test("its Scale runs SpinDuration of real time while a ramping Speed stretches only the rotation", function()
      const m = model({
        SpinDuration = 2,
        SpinRotation = Vector3.new(0, 45, 0),
        SpinSpeed = 1,
        SpinSpeed_Duration = 2,
      }, { Scale = SCALE_LANES })

      for _, s in play(m, 4) do
        near(s.scale, scaleAt(s.t), `scale at {s.t} s`)
      end
    end)

    test("its Scale is finished at exactly SpinDuration, and not a frame before", function()
      const m = model({
        SpinDuration = 2,
        SpinRotation = Vector3.new(0, 45, 0),
        SpinSpeed = 1,
        SpinSpeed_Duration = 2,
      }, { Scale = SCALE_LANES })

      const env = effects.emit(0, m)

      for _ = 1, 63 do
        scheduler.frame(FRAME)
      end

      assert(SCALE[m] > 0.01, `the scale was done before 2 s, at {SCALE[m]}`)

      scheduler.frame(FRAME)
      near(SCALE[m], 0.001, "scale at 2 s")

      -- the rotation, stretched by the ramp, still holds the emit open
      expect(env.Finished:getStatus()).toBe("Started")

      effects.deinit()
    end)

    test("a speed from outside still slows or hurries its Scale: half speed ends it at 4 s, double at 1 s", function()
      for _, case in { { speed = 0.5, ends = 4 }, { speed = 2, ends = 1 } } do
        const m = model({
          SpinDuration = 2,
          SpinRotation = Vector3.new(0, 45, 0),
          SpinSpeed = 1,
          SpinSpeed_Duration = 2,
        }, { Scale = SCALE_LANES })

        const samples = play(m, 5, function(env: any)
          if case.speed < 1 then
            env:SetSpeed(case.speed)
          else
            clock.setGlobalSpeed(case.speed)
          end
        end)

        for _, s in samples do
          near(s.scale, scaleAt(s.t * case.speed), `scale at {s.t} s under {case.speed}x`)

          if s.t < case.ends then
            assert(s.scale > 0.01, `under {case.speed}x the scale was done at {s.t} s`)
          end
        end
      end
    end)

    test("a model saved as a rate turns as it did before Turn was a row", function()
      for n, setup in RATED do
        const m = model(setup.attrs, setup.mods)

        for i, s in play(m, 4, nil) do
          samePose(s.pivot, poseOf(setup, i), `setup {n} at {s.t} s`)
        end
      end
    end)

    test("converting a model saved as a rate writes its turn and plays the same pose at every sampled time", function()
      for n, setup in RATED do
        const m = model(setup.attrs, setup.mods)
        const sets, removes = spin.upgrade(m)

        assert(sets ~= nil and removes ~= nil, `setup {n} was not converted`)

        const turn = setup.attrs.SpinRotation * (setup.attrs.SpinDuration or 0.5)

        samePose(
          CFrame.fromOrientation(sets.SpinTurn.X, sets.SpinTurn.Y, sets.SpinTurn.Z),
          CFrame.fromOrientation(turn.X, turn.Y, turn.Z),
          `setup {n}'s turn`
        )

        for key, v in sets do
          m:SetAttribute(key, v)
        end

        for _, key in removes do
          m:SetAttribute(key, nil)
        end

        expect(m:GetAttribute("SpinRotation")).toBe(nil)
        expect(spin.upgrade(m)).toBe(nil)

        for i, s in play(m, 4, nil) do
          samePose(s.pivot, poseOf(setup, i), `converted setup {n} at {s.t} s`)
        end
      end
    end)

    test("its Turn is how far it turns in all, whatever the duration or a retime makes of its pace", function()
      for _, duration in { 1, 2, 3 } do
        const m = model({ SpinDuration = duration, SpinTurn = Vector3.new(0, 90, 0) })
        const samples = play(m, 4, nil)

        samePose(samples[#samples].pivot, CFrame.fromOrientation(0, math.pi / 2, 0), `the turn over {duration} s`)

        retime.apply(m, 2, 0.5)

        expect(m:GetAttribute("SpinDuration")).toBe(duration / 2)
        expect(m:GetAttribute("SpinTurn")).toBe(Vector3.new(0, 90, 0))
      end
    end)
  end)
end)
