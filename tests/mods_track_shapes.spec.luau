local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance

-- the half of mods that reads a queue off an instance and draws for it, which
-- mods.track is the one way in to. it used to be the Studio lane's alone, on
-- the reading that a spec here can reach neither an Instance nor a Random, and
-- only the second half of that was true.
-- the harness stands a Random in now, so which branch each of these takes has a
-- floor that does not need Studio; what a REAL Random spreads across is still
-- the plugin's vector_randomizer.spec, which is the part a stand-in cannot say
frame.configure(harness.fakeEncoding, harness.fakeCompression)

local EPSILON = 1e-9

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

-- no curve, so alpha is progress outright and every reading below is the plain
-- fraction of the way along rather than a bezier's approximation of one
local function tween(startV: any, finishV: any, duration: number?, offset: number?)
  return {
    kind = "tween",
    chain = false,
    duration = duration,
    offset = if offset then value.lit(offset) else nil,
    start = value.lit(startV),
    finish = value.lit(finishV),
  }
end

-- an instance carrying the queue the way an authored one does, framed and
-- encoded, because mods.track reads its own rather than taking a preread
local function authored(name: string, queue: { any })
  local obj = Instance.new("Attachment")
  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))

  return obj
end

-- a queue with nothing drawn in it still needs rolls, and supplying them keeps
-- the sampler cases below independent of the harness's stand-in Random
local still: mods.Rolls = { draws = {}, picks = {}, envelope = 0 }

harness.suite(function()
  harness.describe("mods.sampler over an offset queue", function()
    -- the reach is 7 here: an offset of 2 pushes a modifier that runs for 5 out
    -- to it. seeding the linked run from that reach measured a 5 second phase
    -- against 7, and the knob stopped 71% of the way along and stayed there for
    -- the rest of every emit
    test("a lent run seeds a linked modifier rather than the reach", function()
      local queue = { tween(0, 10, nil, 2) }
      local span, linked = mods.span(queue, 5)
      local sample = mods.sampler(Instance.new("Attachment"), "attribute", "Size", span, queue, still, linked) :: any

      expect(span).toBe(7)
      expect(linked).toBe(5)
      expect(near(sample(2), 0)).ok()
      expect(near(sample(4.5), 5)).ok()
      expect(near(sample(7), 10)).ok()
    end)

    -- and the argument is load bearing rather than a number that happens to
    -- agree: a caller that lends nothing has only the reach to measure against,
    -- which is the 71% reading above
    test("a sampler told nothing about the run measures against the reach", function()
      local queue = { tween(0, 10, nil, 2) }
      local sample = mods.sampler(Instance.new("Attachment"), "attribute", "Size", 7, queue, still) :: any

      expect(near(sample(7), 10 * (5 / 7))).ok()
    end)
  end)

  harness.describe("mods.track", function()
    -- the same threading through the function every effect actually calls: the
    -- span it hands back is the reach, and what it hands the sampler is the run
    test("threads the run it took beside the reach", function()
      local obj = authored("Size", { tween(0, 10, nil, 2) })
      local track = mods.track(obj, "attribute", "Size", 0, 5)

      expect(track.span).toBe(7)
      expect(near(track.at(7), 10)).ok()
    end)

    -- an effect assigns a sample straight into its own arithmetic, and a stepper
    -- that throws is never cleaned up: tween runs its cleanup only on a frame the
    -- counter returns from normally, so one wrong type repeats the same error
    -- every frame for as long as the scope lives
    test("a knob that names a type is handed no driver for another one", function()
      local obj = authored("Speed", { tween(Vector3.new(0, 0, 0), Vector3.new(10, 10, 10), 1) })

      local warnings = harness.captureWarnings(function()
        local track = mods.track(obj, "attribute", "Speed", 0, 5)

        expect(track.animated).toBe(false)
        expect(track.at(0)).toBe(0)
        expect(track.span).toBe(5)
      end)

      expect(#warnings).toBe(1)
    end)

    -- and it is the type that refused it rather than anything about the queue,
    -- which the same attribute driving a knob that asked for a Vector3, and one
    -- whose default names no type at all, is what says
    test("the same queue drives a knob that asked for what it samples", function()
      local obj = authored("Speed", { tween(Vector3.new(0, 0, 0), Vector3.new(10, 10, 10), 1) })

      expect(mods.track(obj, "attribute", "Speed", Vector3.new(0, 0, 0), 5).animated).ok()
      expect(mods.track(obj, "attribute", "Speed", nil, 5).animated).ok()
    end)

    test("a number knob keeps the driver its queue samples", function()
      local obj = authored("Speed", { tween(0, 10, 1) })
      local track = mods.track(obj, "attribute", "Speed", 0, 5)

      expect(track.animated).ok()
      expect(track.span).toBe(1)
    end)
  end)

  harness.describe("mods.roll over a randomizer", function()
    local function randomizer(startV: value.Value, finishV: value.Value, perComponent: boolean?)
      return { kind = "randomizer", chain = false, start = startV, finish = finishV, perComponent = perComponent }
    end

    local zero = value.lit(Vector3.new(0, 0, 0))
    local ten = value.lit(Vector3.new(10, 10, 10))

    -- two endpoints name a SEGMENT, and a size drawn along one is a scaled copy
    -- of the same shape every time. that is what an authored randomizer and a
    -- RayValue child both mean, so only the shape that asks for a box gets one
    test("two vectors on their own draw one alpha", function()
      expect(type(mods.roll({ randomizer(zero, ten) }).draws[1])).toBe("number")
    end)

    -- a legacy Min/Max pair names a box instead: three independent draws, so a
    -- part comes out with its own proportions rather than as a scaled copy
    test("the flag over two vectors draws one alpha per axis", function()
      local draw = mods.roll({ randomizer(zero, ten, true) }).draws[1] :: any

      expect(type(draw)).toBe("table")
      expect(#draw).toBe(3)
    end)

    -- evaluate's per component branch needs two vectors to interpolate between,
    -- so a pair that is not two vectors stays on the numeric path rather than
    -- handing it a table it would carry into arithmetic that throws
    test("the flag over anything but two vectors still draws one alpha", function()
      expect(type(mods.roll({ randomizer(zero, value.lit(2), true) }).draws[1])).toBe("number")
      expect(type(mods.roll({ randomizer(value.lit(1), value.lit(2), true) }).draws[1])).toBe("number")
    end)

    -- and both ends are judged on what they RESOLVE to, so a var is read at the
    -- value this instance carries rather than at the tagged table it is stored
    -- as, which is a table whatever it holds
    test("a var endpoint is judged on what the environment holds", function()
      local queue = { randomizer(value.var("Base"), ten, true) }

      expect(type(mods.roll(queue, { Base = Vector3.new(0, 0, 0) }).draws[1])).toBe("table")
      expect(type(mods.roll(queue).draws[1])).toBe("number")
    end)
  end)
end)
