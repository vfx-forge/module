local mods = require("@mod/mods")
local value = require("@mod/value")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local Vector3 = harness.datatypes.Vector3

-- the lanes and the sampler as they stood before the fast paths, dev 22f78f0:
-- the general path every fast one has to answer exactly as
local before = require("@tests/fixtures/mods_22f78f0")

local EASE = curves.PRESETS.easeIn

-- every time a driver can hand a row, the ones either side of each entry's
-- start and end, and the ones nothing should ever hand it
local TIMES = {
  -0.25,
  0,
  0.01,
  0.1,
  0.2,
  0.25,
  1 / 3,
  0.4,
  0.5,
  0.6,
  0.75,
  0.9,
  0.99,
  1,
  1.1,
  1.25,
  1.5,
  2,
  2.5,
  3,
  4,
  10,
  0 / 0,
  math.huge,
}

local function tween(startV: any, finishV: any, duration: number?, shape: any?)
  return {
    kind = "tween",
    chain = false,
    duration = duration,
    start = value.lit(startV),
    finish = value.lit(finishV),
    curve = shape,
  }
end

local function onward(finishV: any, duration: number?, shape: any?)
  return { kind = "tween", chain = true, duration = duration, finish = value.lit(finishV), curve = shape }
end

local function delay(wait: number)
  return { kind = "delay", chain = false, wait = value.lit(wait) }
end

local function envelope(widths: { number }): buffer
  local buf = buffer.create(#widths * 4)

  for i, w in widths do
    buffer.writef32(buf, (i - 1) * 4, w)
  end

  return buf
end

-- a nan is the one value that is not itself, and the general path hands one
-- back for a clock nobody can read
local function same(a: any, b: any): boolean
  if type(a) == "number" and type(b) == "number" and a ~= a and b ~= b then
    return true
  end

  return a == b
end

-- a list can hold no nil, so this stands in for one: nothing handed in
local NONE = table.freeze({})

local function given(v: any): any
  return if v == NONE then nil else v
end

-- one reading as a comparable record: what it answered, or that it threw
local function read(fn: () -> any): { any }
  local ok, got = pcall(fn)

  return { ok, if ok then got else nil }
end

local function differences(new: { { any } }, old: { { any } }, labels: { string }): { string }
  local out = {}

  for i, got in new do
    local want = old[i]

    if got[1] ~= want[1] or not same(got[2], want[2]) then
      table.insert(out, `{labels[i]}: {tostring(got[2])} where the general path answers {tostring(want[2])}`)
    end
  end

  return out
end

-- one build of the same row from each side, both drawing from the stand-in
-- Random's fixed seed, so a row that draws draws the same on both
local function pair(
  lanes: { [string]: { any } },
  rest: any,
  span: number,
  events: { string }?,
  opts: any?,
  env: { [string]: any }?
)
  local ref = Instance.new("Attachment")
  local newPiece = mods.piece(events)
  local oldPiece = before.piece(events)
  local new = mods.build(ref, "attribute", "Width", rest, span, env, lanes, true, opts, newPiece)
  local old = before.build(ref, "attribute", "Width", rest, span, env, lanes, true, opts, oldPiece)

  return {
    new = new,
    old = old,
    fire = function(name: string, at: number, runFor: number?)
      newPiece:fire(name, at, runFor)
      oldPiece:fire(name, at, runFor)
    end,
  }
end

-- every time, with nothing handed in, with a value handed in, and frozen
-- before, at and after the row's own triggers
local function sweep(rows: any, into: { new: { { any } }, old: { { any } }, labels: { string } }, tag: string)
  for _, held in { NONE, 7 } do
    for _, frozen in { NONE, 0, 0.3, 0.5, 2 } do
      local own, since = given(held), given(frozen)

      for _, t in TIMES do
        table.insert(
          into.new,
          read(function()
            return rows.new.at(t, own, since)
          end)
        )

        table.insert(
          into.old,
          read(function()
            return rows.old.at(t, own, since)
          end)
        )

        table.insert(into.labels, `{tag} at {t} over {tostring(own)} since {tostring(since)}`)
      end
    end
  end
end

local function fresh()
  return { new = {}, old = {}, labels = {} }
end

local function settle(into: any)
  local wrong = differences(into.new, into.old, into.labels)
  local answered = 0

  for _, got in into.new do
    if got[1] then
      answered += 1
    end
  end

  -- a case whose every reading throws compares nothing
  expect(answered > #into.new / 2).toBe(true)

  if #wrong > 0 then
    print(`{#wrong} readings differ, the first: {wrong[1]}`)
  end

  expect(#wrong).toBe(0)
end

-- every time with and without a base, told a different time left in turn
local function sampled(new: any, old: any, into: any, lefts: { any }, tag: string)
  for _, told in lefts do
    for _, held in { NONE, 3, Vector3.new(1, 2, 3) } do
      local own, left = given(held), given(told)

      for _, t in TIMES do
        table.insert(
          into.new,
          read(function()
            return new(t, own, left)
          end)
        )

        table.insert(
          into.old,
          read(function()
            return old(t, own, left)
          end)
        )

        table.insert(into.labels, `{tag} at {t} over {tostring(own)} with {tostring(left)} left`)
      end
    end
  end
end

-- the sampler a lane builds, from each side over the same rolls
local function samplers(queue: { any }, span: number, env: { [string]: any }?)
  local ref = Instance.new("Attachment")
  local rolls = mods.roll(queue, env)
  local reach, linked = mods.span(queue, span, rolls)
  local new = mods.sampler(ref, "attribute", "Width", reach, queue, rolls, linked)
  local old = before.sampler(ref, "attribute", "Width", reach, queue, rolls, linked)

  return new, old
end

local function compared(queue: { any }, span: number, lefts: { any })
  local into = fresh()
  local new, old = samplers(queue, span, nil)

  sampled(new, old, into, lefts, "")

  return into
end

harness.suite(function()
  harness.describe("a row of one lane answers what the lane fold answers", function()
    test("a start lane of one tween, eased or not", function()
      local into = fresh()

      sweep(pair({ start = { tween(0, 1, 1) } }, 0, 1), into, "plain")
      sweep(pair({ start = { tween(0, 1, 1, EASE) } }, 0, 1), into, "eased")
      sweep(pair({ start = { tween(2, 5, nil, EASE) } }, 0, 1.5), into, "open")

      settle(into)
    end)

    test("a start lane of chained entries with waits between", function()
      local into = fresh()
      local queue = { tween(0, 1, 0.3, EASE), delay(0.1), onward(0.5, 0.3), delay(0.2), onward(2) }

      sweep(pair({ start = queue }, 0, 2), into, "chained")
      sweep(pair({ start = { delay(0.4), onward(4, 0.5) } }, 1, 2), into, "led by a wait")

      settle(into)
    end)

    test("an end lane alone, inside and longer than the row's span", function()
      local into = fresh()

      sweep(pair({ ["end"] = { onward(0, 0.5, EASE) } }, 1, 2), into, "inside")
      sweep(pair({ ["end"] = { tween(0, 1, 3) } }, 0, 1), into, "longer")

      settle(into)
    end)

    test("an event lane alone, before and after it fires, fired again and told how long it runs", function()
      local into = fresh()
      local queue = { onward(0, nil, EASE) }
      local rows = pair({ dissipate = queue }, 1, 3, { "dissipate" })

      sweep(rows, into, "unfired")

      rows.fire("dissipate", 0.5)
      sweep(rows, into, "fired at 0.5")

      rows.fire("dissipate", 1.25)
      sweep(rows, into, "fired again at 1.25")

      rows.fire("dissipate", 0.2, 0.4)
      sweep(rows, into, "fired at 0.2 for 0.4")

      rows.fire("dissipate", 2)
      sweep(rows, into, "fired at 2 for what is left")

      settle(into)
    end)

    test("a stored event lane that says nothing hands the row to the default of its name", function()
      local into = fresh()
      -- two ends nothing supplies sample nothing over whatever the row holds,
      -- and a stored map that silences the start leaves the event lane alone
      -- on the row. a drawn start keeps the build from judging the lanes by
      -- kind, which would drop the silent lane before it ever fell back
      local nowhere = value.var("Missing")
      local stored = {
        start = {},
        dissipate = { { kind = "tween", chain = false, duration = 1, start = nowhere, finish = nowhere } },
      }
      local default = {
        start = { { kind = "tween", chain = false, duration = 1, start = value.draw(0, 2), finish = value.lit(1) } },
        dissipate = { onward(5, 1) },
      }
      local rows = pair(stored, default, 3, { "dissipate" })

      rows.fire("dissipate", 0.5)

      -- the default's own answer, so the case cannot pass without the fallback
      expect(rows.new.at(1.5, 0)).toBe(5)

      sweep(rows, into, "fallen back")
      settle(into)
    end)

    test("a lane that draws its endpoints, weighted, and a randomizer", function()
      local into = fresh()
      local drawn = {
        kind = "tween",
        chain = false,
        duration = 1,
        start = value.draw(0, 10, EASE),
        finish = value.draw(20, 30),
      }
      local random =
        { kind = "randomizer", chain = false, start = value.lit(0), finish = value.lit(100), weight = EASE }

      sweep(pair({ start = { drawn } }, 0, 1), into, "drawn")
      sweep(pair({ start = { random, onward(0, 1) } }, 0, 1), into, "randomized")

      settle(into)
    end)
  end)

  harness.describe("a compiled sampler answers what evaluate answers", function()
    test("chained entries, waits and an entry naming no duration told a different time left each call", function()
      local queue = { tween(0, 1, 0.3, EASE), delay(0.1), onward(0.5, 0.3), onward(2), delay(0.25), onward(9) }

      settle(compared(queue, 2, { NONE, 3, 0.5, 3, 0, 1.75, 0 / 0, 0.5 }))
    end)

    test("drawn endpoints, weighted and not, and a var read from the environment", function()
      local env = { Base = 4 }
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 0.5,
          start = value.draw(0, 10, EASE),
          finish = value.draw(40, 50),
        },
        { kind = "tween", chain = false, duration = 0.5, start = value.var("Base"), finish = value.draw(20, 30) },
        { kind = "tween", chain = false, start = value.var("Missing"), finish = value.lit(1) },
      }
      local into = fresh()
      local new, old = samplers(queue, 2, env)

      sampled(new, old, into, { NONE, 1 }, "")

      -- the environment is the caller's, so a var follows it between frames
      env.Base = 8
      sampled(new, old, into, { NONE }, "moved")

      settle(into)
    end)

    test("a randomizer drawn once and once per component, chained and not", function()
      local axes = {
        kind = "randomizer",
        chain = false,
        start = value.lit(Vector3.new(0, 0, 0)),
        finish = value.lit(Vector3.new(10, 20, 30)),
        perComponent = true,
        weight = EASE,
      }
      local chained = { kind = "randomizer", chain = true, finish = value.lit(Vector3.new(5, 5, 5)), weight = EASE }
      local once = { kind = "randomizer", chain = false, start = value.lit(0), finish = value.lit(1), duration = 0.5 }
      local into = fresh()

      for i, queue in { { axes }, { axes, chained }, { once, onward(4, 0.5) } } do
        local new, old = samplers(queue, 1, nil)

        sampled(new, old, into, { NONE }, `queue {i}`)
      end

      settle(into)
    end)

    test("parallel legacy entries, each on its own wait", function()
      local queue = {
        { kind = "delay", chain = false, parallel = true, wait = value.lit(0.5) },
        { kind = "tween", chain = false, parallel = true, duration = 1, start = value.lit(0), finish = value.lit(1) },
        {
          kind = "tween",
          chain = false,
          parallel = true,
          duration = 0.25,
          start = value.lit(5),
          finish = value.lit(6),
        },
        { kind = "tween", chain = true, parallel = true, finish = value.lit(9), curve = EASE },
      }

      settle(compared(queue, 2, { NONE, 1 }))
    end)

    test("an envelope, a named rate, a rate that ramps, a chain of points and a kind nothing knows", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 0.5,
          start = value.lit(0),
          finish = value.lit(100),
          envelope = envelope({ 0, 0.4, 0.1 }),
        },
        { kind = "tween", chain = true, duration = 0.5, finish = value.lit(50), fps = 12 },
        {
          kind = "tween",
          chain = true,
          duration = 0.5,
          finish = value.lit(0),
          fps = { from = 4, to = 40, curve = EASE },
        },
        {
          kind = "tween",
          chain = true,
          duration = 0.5,
          finish = value.lit(10),
          curve = { vector.create(0, 0), vector.create(1, 1) },
        },
        { kind = "mystery", chain = false, start = value.lit(3) },
        { kind = "sequence", duration = 4 },
        onward(1),
      }

      settle(compared(queue, 3, { NONE, 2, 0.5 }))
    end)
  end)

  harness.describe("a row of several lanes answers what it answered before", function()
    test("an event lane fired over a running start lane, frozen and not", function()
      local into = fresh()
      local lanes = {
        start = { tween(0, 1, 2, EASE) },
        dissipate = { onward(0, nil, EASE) },
        flare = { onward(3, 0.25), onward(1, 0.25) },
      }
      local rows = pair(lanes, 0, 3, { "dissipate", "flare" })

      sweep(rows, into, "unfired")

      rows.fire("flare", 0.5)
      sweep(rows, into, "flared")

      rows.fire("dissipate", 1)
      sweep(rows, into, "dissipating")

      rows.fire("flare", 1)
      sweep(rows, into, "flared in the same frame")

      for _, lane in { "start", "end", "dissipate", "flare", "nope" } do
        for _, at in { 0, 0.5, 1, 2 } do
          table.insert(
            into.new,
            read(function()
              return rows.new.still(lane, at)
            end)
          )

          table.insert(
            into.old,
            read(function()
              return rows.old.still(lane, at)
            end)
          )

          table.insert(into.labels, `still {lane} at {at}`)
        end

        table.insert(into.new, { true, rows.new.reach(lane) })
        table.insert(into.old, { true, rows.old.reach(lane) })
        table.insert(into.labels, `reach {lane}`)
      end

      settle(into)
    end)

    test("an environment that moved before a lane fires places the lane as it stands then", function()
      local into = fresh()
      local waits = { kind = "delay", chain = false, wait = value.var("W") }

      for _, lanes in
        {
          { start = { tween(0, 1, 1) }, dissipate = { waits, onward(5, 0.5) } },
          { dissipate = { waits, onward(5, 0.5) } },
        }
      do
        local env = { W = 0.2 }
        local rows = pair(lanes, 0, 2, { "dissipate" }, nil, env)

        sweep(rows, into, "unfired")

        env.W = 0.6
        rows.fire("dissipate", 0.5)
        sweep(rows, into, "fired after the wait moved")

        env.W = 0.1
        sweep(rows, into, "the wait moved again after the fire")

        rows.fire("dissipate", 1)
        sweep(rows, into, "fired again")
      end

      settle(into)
    end)

    test("an environment that moved after the build leaves a start lane where it was placed", function()
      local into = fresh()
      local env = { W = 0.2 }
      local lanes = {
        start = { { kind = "delay", chain = false, wait = value.var("W") }, tween(0, 1, 0.5), onward(3) },
      }
      local rows = pair(lanes, 0, 2, nil, nil, env)

      sweep(rows, into, "built")

      env.W = 0.6
      sweep(rows, into, "moved")

      settle(into)
    end)

    test("a start lane and an end lane", function()
      local into = fresh()

      sweep(pair({ start = { tween(0, 1, 1) }, ["end"] = { onward(0, 0.5) } }, 0, 2), into, "both")

      settle(into)
    end)
  end)
end)
