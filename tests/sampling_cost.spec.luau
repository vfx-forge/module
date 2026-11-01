local mods = require("@mod/mods")
local value = require("@mod/value")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local test = harness.test
local Instance = harness.datatypes.Instance

-- the lanes and the sampler as they stood before the fast paths, dev 22f78f0,
-- verbatim but for the one require that points the copy at its own modifiers
local before = require("@tests/fixtures/mods_22f78f0")

local ROUNDS = 9
local FRAMES = 240
local PASSES = 20
local BUILDS = 1000

local function tween(startV: any, finishV: any, duration: number?, shaped: boolean?)
  return {
    kind = "tween",
    chain = false,
    duration = duration,
    start = value.lit(startV),
    finish = value.lit(finishV),
    curve = if shaped then curves.default() else nil,
  }
end

local function onward(finishV: any, duration: number?)
  return { kind = "tween", chain = true, duration = duration, finish = value.lit(finishV) }
end

local function delay(wait: number)
  return { kind = "delay", chain = false, wait = value.lit(wait) }
end

-- the rows a slam is made of: a fade on the start lane, the same eased, a
-- queue that rises, waits and settles, and a start lane an event lane takes over
local SHAPES = {
  {
    name = "start tween",
    lanes = { start = { tween(0, 1, 1) } },
  },
  {
    name = "curved tween",
    lanes = { start = { tween(0, 1, 1, true) } },
  },
  {
    name = "chained queue",
    lanes = { start = { tween(0, 1, 0.3, true), delay(0.1), onward(0.5, 0.3), onward(2) } },
  },
  {
    name = "event lane",
    lanes = { start = { tween(0, 1, 1, true) }, dissipate = { onward(0) } },
    fire = 0.5,
  },
}

local function trackOf(lib: any, shape: any)
  local piece = lib.piece({ "dissipate" })
  local track = lib.build(Instance.new("Attachment"), "attribute", "Width", 0, 1, nil, shape.lanes, true, nil, piece)

  if shape.fire ~= nil then
    piece:fire("dissipate", shape.fire)
  end

  return track
end

-- a frame per sixtieth of a second across the row's span and past it, as a
-- driver steps it, timed per call
local function timed(track: any)
  local at = track.at
  local started = os.clock()

  for _ = 1, PASSES do
    for i = 0, FRAMES - 1 do
      at(i / 200)
    end
  end

  return (os.clock() - started) / (PASSES * FRAMES)
end

-- a row built and sampled once, as an emit builds it and its driver writes the
-- first value at once
local function builtOnce(lib: any, shape: any)
  local ref = Instance.new("Attachment")
  local started = os.clock()

  for _ = 1, BUILDS do
    local piece = lib.piece({ "dissipate" })
    local track = lib.build(ref, "attribute", "Width", 0, 1, nil, shape.lanes, true, nil, piece)

    track.at(0)
  end

  return (os.clock() - started) / BUILDS
end

harness.suite(function()
  harness.describe("the cost of sampling a row", function()
    test("every row shape's sampling is timed against the lanes before the fast paths", function()
      local lines = {}

      for _, shape in SHAPES do
        local new = trackOf(mods, shape)
        local old = trackOf(before, shape)

        -- alternate rounds, each side's fastest, so the collector and a busy
        -- runner weigh on both alike
        local fast, slow = math.huge, math.huge

        for _ = 1, ROUNDS do
          fast = math.min(fast, timed(new))
          slow = math.min(slow, timed(old))
        end

        table.insert(
          lines,
          `{shape.name} {string.format("%.0f", fast * 1e9)} ns, {string.format("%.0f", slow * 1e9)} ns before`
        )
      end

      print(`a row's at per call: {table.concat(lines, ", ")}`)
    end)

    test("building a row and its first sample is timed against before the fast paths", function()
      local lines = {}

      for _, shape in SHAPES do
        local fast, slow = math.huge, math.huge

        for _ = 1, ROUNDS do
          fast = math.min(fast, builtOnce(mods, shape))
          slow = math.min(slow, builtOnce(before, shape))
        end

        table.insert(
          lines,
          `{shape.name} {string.format("%.2f", fast * 1e6)} us, {string.format("%.2f", slow * 1e6)} us before`
        )
      end

      print(`a row built and sampled once: {table.concat(lines, ", ")}`)
    end)
  end)
end)
