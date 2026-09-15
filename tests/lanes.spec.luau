local mods = require("@mod/mods")
local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

local EPSILON = 1e-9

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

-- no curve, so alpha is progress outright and every reading below is the plain
-- fraction of the way along rather than a bezier's approximation of one
local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

-- an entry that begins wherever the row stands: a chain with nothing before it
-- in its own lane reads the value the lanes under it hold
local function onward(finishV: any, duration: number?)
  return { kind = "tween", chain = true, duration = duration, finish = value.lit(finishV) }
end

local function built(lanes: { [string]: { any } }, rest: any, span: number, piece: any)
  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, true, nil, piece)
end

harness.suite(function()
  harness.describe("mods.piece", function()
    test("a piece refuses a name its module never declared", function()
      local piece = mods.piece({ "dissipate" })

      expect(function()
        piece:fire("nope", 0)
      end).toThrow()

      expect(function()
        mods.piece():fire("dissipate", 0)
      end).toThrow()
    end)

    test("a fired name is remembered at the elapsed it was fired at", function()
      local piece = mods.piece({ "dissipate" })

      piece:fire("dissipate", 1.5)

      expect(piece.fired.dissipate).toBe(1.5)
    end)
  end)

  harness.describe("the lane fold", function()
    -- the end lane runs against the piece's own clock, so its trigger is the
    -- moment the row's span leaves exactly its reach
    test("an end lane starts where its reach fits inside the row's span", function()
      local track = built({ ["end"] = { tween(0, 1, 2) } }, 0, 5, nil)

      expect(track.span).toBe(5)
      expect(track.has("end")).toBe(true)
      expect(near(track.at(2), 0)).toBe(true)
      expect(near(track.at(4), 0.5)).toBe(true)
      expect(near(track.at(5), 1)).toBe(true)
    end)

    test("a lifetime shorter than the end lane's reach starts it at once", function()
      local track = built({ ["end"] = { tween(0, 1, 2) } }, 0, 1, nil)

      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(1), 0.5)).toBe(true)
    end)

    test("an event lane fired mid run takes over from where the row stands and holds its end", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      expect(near(track.at(2), 0.5)).toBe(true)

      piece:fire("dissipate", 2)

      expect(near(track.at(2), 0.5)).toBe(true)
      expect(near(track.at(2.5), 0.25)).toBe(true)
      expect(near(track.at(3), 0)).toBe(true)
      expect(near(track.at(9), 0)).toBe(true)
    end)

    test("two lanes fired in the same frame go to the later one in lane order", function()
      local piece = mods.piece({ "one", "two" })
      local track = built({
        start = { tween(0, 1, 4) },
        one = { onward(0.25, 1) },
        two = { onward(0.75, 1) },
      }, 0, 4, piece)

      piece:fire("one", 1)
      piece:fire("two", 1)

      expect(near(track.at(2), 0.75)).toBe(true)
    end)

    -- a piece that froze the row at a moment composes only what fired after it,
    -- over the value it is holding
    test("since skips every lane that had already started", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(1.5, 0.8, 1), 0.8)).toBe(true)
      expect(near(track.at(2.5, 0.8, 1), 0.4)).toBe(true)
    end)

    test("own replaces the value the lanes compose over", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ dissipate = { onward(0, 2) } }, 0, 4, piece)

      piece:fire("dissipate", 0)

      expect(near(track.at(0, 1), 1)).toBe(true)
      expect(near(track.at(1, 1), 0.5)).toBe(true)
    end)

    test("an unfired event lane leaves the row to the lanes that did fire", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(4), 1)).toBe(true)
      expect(near(track.at(40), 1)).toBe(true)
    end)

    test("firing again restarts the lane's clock", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      piece:fire("dissipate", 1)
      expect(near(track.at(1.5), 0.125)).toBe(true)

      piece:fire("dissipate", 3)
      expect(near(track.at(3.5), 0.375)).toBe(true)
    end)

    test("a lane no piece declares is not a lane at all", function()
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, nil)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(false)
    end)

    -- the module that fires an event owns the clock it fires on, so the lane
    -- must not stretch the span the effect steps for
    test("the span is the start lane's reach and an event lane does not count", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 2) }, dissipate = { onward(0, 9) } }, 0, 5, piece)

      expect(track.span).toBe(2)
      expect(track.animated).toBe(true)
    end)

    test("an empty map rests at the row's own value", function()
      local track = built({}, 3, 5, nil)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(3)
      expect(track.has("start")).toBe(false)
    end)
  end)
end)
