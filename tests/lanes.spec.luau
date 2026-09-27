local mods = require("@mod/mods")
local value = require("@mod/value")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

local EPSILON = 1e-9

frame.configure(harness.fakeEncoding, harness.fakeCompression)

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

local function delay(wait: number)
  return { kind = "delay", chain = false, wait = value.lit(wait) }
end

local function built(lanes: { [string]: { any } }, rest: any, span: number, piece: any)
  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, true, nil, piece)
end

-- a map read out of the old format, which is never framed
local function legacy(lanes: { [string]: { any } }, rest: any, span: number, piece: any)
  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, false, nil, piece)
end

-- the build a reader makes for a default of lanes: it says where the row rests,
-- because such a default may put nothing on the row's own lane
local function stating(lanes: { [string]: { any } }, rest: any, span: number, piece: any, stands: any)
  local opts = { value = stands }

  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, true, opts, piece)
end

-- an old half queue over a default of lanes: never framed, and the caller still
-- says where the row rests
local function filling(lanes: { [string]: { any } }, rest: any, span: number, piece: any, stands: any)
  local opts = { value = stands }

  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, false, opts, piece)
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

    -- a piece that froze the row at a moment composes only what started at or
    -- after it, over the value it is holding
    test("since skips every lane that had already started", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(1.5, 0.8, 1), 0.8)).toBe(true)
      expect(near(track.at(2.5, 0.8, 1), 0.4)).toBe(true)
    end)

    -- a lane that begins the instant a piece is born is part of what it is born
    -- into rather than something it already carries, so the boundary is the
    -- lane's and not the piece's
    test("a lane starting exactly at since composes, one below it is skipped", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { onward(0, 1) } }, 0, 4, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(1.9, 0.8, 2), 0.8)).toBe(true)
      expect(near(track.at(2, 0.8, 2), 0.8)).toBe(true)
      expect(near(track.at(2.5, 0.8, 2), 0.4)).toBe(true)
      expect(near(track.at(3, 0.8, 2), 0)).toBe(true)
    end)

    test("a row frozen at the emit still runs the lane that starts there", function()
      local track = built({ start = { tween(0, 1, 4) } }, 0, 4, nil)

      expect(near(track.at(0, 0.9, 0), 0)).toBe(true)
      expect(near(track.at(2, 0.9, 0), 0.5)).toBe(true)
      expect(near(track.at(4, 0.9, 0), 1)).toBe(true)
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

    -- a row whose default is a lane map rests at what that map's start says
    -- rather than at nothing, so an authored lane that begins where the row
    -- stands is judged from there rather than read as a kind nothing wanted
    test("an authored lane that chains is judged from where the row rests", function()
      local warnings = harness.captureWarnings(function()
        local track = built({ start = { onward(4, 1) } }, { start = { tween(0, 2, 1) } }, 1, nil)

        expect(near(track.at(0, 3), 3)).toBe(true)
        expect(near(track.at(1, 3), 4)).toBe(true)
      end)

      expect(#warnings).toBe(0)
    end)

    -- a default made of lanes rests where its lead begins, so a lane that
    -- chains with nothing under it reads from there rather than from nothing
    test("a chaining lane with no own composes over where the default lane begins", function()
      local track = built({ start = { onward(4, 1) } }, { start = { tween(0, 2, 1) } }, 1, nil)

      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(0.25), 1)).toBe(true)
      expect(near(track.at(0.5), 2)).toBe(true)
      expect(near(track.at(0.75), 3)).toBe(true)
      expect(near(track.at(1), 4)).toBe(true)
    end)

    test("a drawn default rests at the corner its draw begins from", function()
      local track = built({ start = { onward(4, 1) } }, mods.draw(1, 5), 1, nil)

      expect(near(track.at(0), 1)).toBe(true)
      expect(near(track.at(0.5), 2.5)).toBe(true)
      expect(near(track.at(1), 4)).toBe(true)
    end)

    -- an end lane triggers against the row's own span, so a start lane shorter
    -- than that span must not shorten what a driver steps
    test("an end lane keeps the span the row runs over", function()
      local track = built({ start = { tween(0, 1, 2) }, ["end"] = { tween(1, 0, 1) } }, 0, 5, nil)

      expect(track.span).toBe(5)
      expect(near(track.at(2), 1)).toBe(true)
      expect(near(track.at(4.5), 0.5)).toBe(true)
      expect(near(track.at(5), 0)).toBe(true)
    end)

    -- a default made of lanes leads from somewhere the row does not rest, so a
    -- row that silences that lead and whose other lanes all wait stands where
    -- the caller says it does
    test("a lane that waits leaves the row at the value the caller stated", function()
      local track = stating({ start = {}, ["end"] = { onward(1, 2) } }, { start = { tween(0.9, 0, 1) } }, 5, nil, 0)

      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(3), 0)).toBe(true)
      expect(near(track.at(4), 0.5)).toBe(true)
      expect(near(track.at(5), 1)).toBe(true)
    end)

    test("an event lane that has not fired leaves the row at the stated value", function()
      local piece = mods.piece({ "dissipate" })
      local track = stating({ start = {}, dissipate = { onward(1, 2) } }, { start = { tween(0.9, 0, 1) } }, 5, piece, 0)

      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(9), 0)).toBe(true)

      piece:fire("dissipate", 1)

      expect(near(track.at(1), 0)).toBe(true)
      expect(near(track.at(2), 0.5)).toBe(true)
      expect(near(track.at(3), 1)).toBe(true)
    end)

    -- the old format carried one trigger and no way to say anything about
    -- another lane, so a queue read out of it cannot have meant to silence one
    test("a legacy queue takes the start lane and leaves the others standing", function()
      local piece = mods.piece({ "dissipate" })
      local default = { start = { tween(1, 0, 1) }, dissipate = { onward(1, 1) } }
      local track = legacy({ start = { tween(0, 0.5, 2) } }, default, 4, piece)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(2), 0.5)).toBe(true)

      piece:fire("dissipate", 2)

      expect(near(track.at(2.5), 0.75)).toBe(true)
      expect(near(track.at(3), 1)).toBe(true)
    end)

    -- a default made of lanes that puts nothing on the row's own lane leaves an
    -- old half quad nothing to complete from but where the row rests, which is
    -- the half a row with no default of its own has always been filled from
    test("a half queue over a default that leads nowhere completes from the stated value", function()
      local piece = mods.piece({ "dissipate" })
      local half = { { kind = "tween", chain = false, duration = 2, finish = value.lit(0.5), partial = "start" } }
      local track = filling({ start = half }, { dissipate = { onward(1, 1) } }, 4, piece, 0)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(1), 0.25)).toBe(true)
      expect(near(track.at(2), 0.5)).toBe(true)
    end)

    -- a stored map owns the lanes it names and nothing else, framed or not, so
    -- a row edited on its start still runs the default exit beside it
    test("a framed map keeps the default lanes it does not name", function()
      local piece = mods.piece({ "dissipate" })
      local defaults = { start = { tween(0.9, 0, 0.4) }, dissipate = { onward(1, 0.3) } }
      local track = stating({ start = { tween(0, 0.5, 1) } }, defaults, 2, piece, 0)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(0.5), 0.25)).toBe(true)

      piece:fire("dissipate", 1)

      expect(near(track.at(1.3), 1)).toBe(true)
    end)

    -- an authored lane that cannot be read at all counts as unnamed, so the
    -- default lane of the same name keeps running beside a lane the authored
    -- map did manage to read
    test("an unreadable old-format lane leaves the default of the same name running", function()
      local defaults = mods.draw(1, 5)
      local half = { kind = "tween", chain = false, duration = 1, partial = "both" }
      local track = legacy({ start = { half }, ["end"] = { tween(0, 1, 1) } }, defaults, 5, nil)

      expect(track.has("start")).toBe(true)
      expect(track.has("end")).toBe(true)
      expect(near(track.at(4), 0)).toBe(true)
      expect(near(track.at(5), 1)).toBe(true)
    end)

    test("a named empty lane silences that default lane alone", function()
      local piece = mods.piece({ "dissipate" })
      local defaults = { start = { tween(0.9, 0, 0.4) }, dissipate = { onward(1, 0.3) } }
      local track = stating({ dissipate = {} }, defaults, 2, piece, 0)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(false)
      expect(near(track.at(0), 0.9)).toBe(true)
    end)

    test("a named lane that only waits silences that default lane alone", function()
      local piece = mods.piece({ "dissipate" })
      local defaults = { start = { tween(0.9, 0, 0.4) }, dissipate = { onward(1, 0.3) } }
      local track = stating({ start = { delay(1) } }, defaults, 2, piece, 0)

      expect(track.has("start")).toBe(false)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(0), 0)).toBe(true)
    end)

    test("a map naming no lane leaves every default running", function()
      local piece = mods.piece({ "dissipate" })
      local defaults = { start = { tween(0.9, 0, 0.4) }, dissipate = { onward(1, 0.3) } }
      local track = stating({}, defaults, 2, piece, 0)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(0), 0.9)).toBe(true)
    end)

    test("a map silencing every default lane rests at the stated value", function()
      local piece = mods.piece({ "dissipate" })
      local defaults = { start = { tween(0.9, 0, 0.4) }, dissipate = { onward(1, 0.3) } }
      local track = stating({ start = {}, dissipate = {} }, defaults, 2, piece, 0)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(0)
      expect(track.has("start")).toBe(false)
      expect(track.has("dissipate")).toBe(false)
    end)

    test("an empty map rests at the row's own value", function()
      local track = built({}, 3, 5, nil)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(3)
      expect(track.has("start")).toBe(false)
    end)

    -- the stored format carries a delay as an entry of its own lane, so the
    -- whole trip from the attribute to the track has to keep the gap it makes
    test("a framed delay holds the value it follows and starts the next entry after its gap", function()
      local ref = Instance.new("Attachment")
      local payload =
        { lanes = { start = { tween(0, 1, 1), { kind = "delay", chain = false, wait = 3 }, tween(1, 0, 1) } } }

      ref:SetAttribute(mods.attrName("attribute", "Width"), frame.frame(codec.encode(payload)))

      local lanes = mods.framed(ref, "attribute", "Width")

      expect(lanes ~= nil).toBe(true)

      local track = mods.build(ref, "attribute", "Width", 0, 5, nil, lanes, true, nil, nil)

      expect(near(track.at(0.5), 0.5)).toBe(true)
      expect(near(track.at(1), 1)).toBe(true)
      expect(near(track.at(2.5), 1)).toBe(true)
      expect(near(track.at(4), 1)).toBe(true)
      expect(near(track.at(4.5), 0.5)).toBe(true)
      expect(near(track.at(5), 0)).toBe(true)
    end)
  end)

  harness.describe("sequential lanes", function()
    test("a lane plays its entries one after another and holds the last finish", function()
      local track = built({ start = { tween(50, 10, 2), tween(10, 50, 1) } }, 50, 4, nil)

      expect(near(track.at(1), 30)).toBe(true)
      expect(near(track.at(2), 10)).toBe(true)
      expect(near(track.at(2.5), 30)).toBe(true)
      expect(near(track.at(3), 50)).toBe(true)
      expect(near(track.at(3.5), 50)).toBe(true)
    end)

    test("a delay holds the finish before it through the gap", function()
      local track = built({ start = { tween(0, 1, 1), delay(3), tween(1, 0, 1) } }, 0, 6, nil)

      expect(near(track.at(0.5), 0.5)).toBe(true)
      expect(near(track.at(2), 1)).toBe(true)
      expect(near(track.at(4.5), 0.5)).toBe(true)
      expect(near(track.at(5), 0)).toBe(true)
    end)

    test("an end lane plays its entries in order and ends with the effect", function()
      local track = built({ ["end"] = { tween(0, 1, 1), tween(1, 0.5, 1) } }, 0, 5, nil)

      expect(near(track.at(2), 0)).toBe(true)
      expect(near(track.at(3.5), 0.5)).toBe(true)
      expect(near(track.at(4), 1)).toBe(true)
      expect(near(track.at(4.5), 0.75)).toBe(true)
      expect(near(track.at(5), 0.5)).toBe(true)
    end)

    test("a no-duration entry on the start lane runs out the effect", function()
      local track = built({ start = { tween(0, 1, 1), tween(1, 0, nil) } }, 0, 5, nil)

      expect(near(track.at(1), 1)).toBe(true)
      expect(near(track.at(3), 0.5)).toBe(true)
      expect(near(track.at(5), 0)).toBe(true)
    end)

    test("a no-duration entry on the end lane takes no time", function()
      local track = built({ ["end"] = { tween(0, 1, 1), tween(1, 0, nil) } }, 0, 5, nil)

      expect(near(track.at(4.5), 0.5)).toBe(true)
      expect(near(track.at(5), 0)).toBe(true)
    end)

    test("a no-duration entry on an event lane runs out the effect from where it fired", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ dissipate = { onward(0, nil) } }, 1, 6, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(4), 0.5)).toBe(true)
      expect(near(track.at(6), 0)).toBe(true)

      piece:fire("dissipate", 4)

      expect(near(track.at(5), 0.5)).toBe(true)
      expect(near(track.at(6), 0)).toBe(true)
    end)

    test("an event lane that opens with a delay holds the value under it while it waits", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { delay(1), onward(0, 1) } }, 0, 6, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(2.5), 0.625)).toBe(true)
      expect(near(track.at(3), 0.75)).toBe(true)
      expect(near(track.at(3.5), 0.375)).toBe(true)
      expect(near(track.at(4), 0)).toBe(true)
    end)

    -- a non-chained first entry names its own start rather than composing over
    -- what the lane sits under, so a delay ahead of it does not hand the row to
    -- the lanes below: it holds that start from the moment the lane begins
    test("a non-chained first entry after a delay holds its own start rather than the value under it", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 4) }, dissipate = { delay(1), tween(5, 0, 1) } }, 0, 6, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(2.5), 5)).toBe(true)
      expect(near(track.at(3.5), 2.5)).toBe(true)
      expect(near(track.at(4), 0)).toBe(true)
    end)

    test("an end lane of only no-duration entries snaps to its finish as the effect ends", function()
      local plain = built({ ["end"] = { tween(1, 0, nil) } }, 1, 5, nil)
      local waited = built({ ["end"] = { delay(0), tween(1, 0, nil) } }, 1, 5, nil)

      for _, track in { plain, waited } do
        expect(near(track.at(0), 1)).toBe(true)
        expect(near(track.at(2.5), 1)).toBe(true)
        expect(near(track.at(4.9), 1)).toBe(true)
        expect(near(track.at(5), 0)).toBe(true)
      end
    end)

    test("an end lane that opens with a delay leaves the start lane playing through the wait", function()
      local track = built({ start = { tween(0, 1, 4) }, ["end"] = { delay(1), onward(0, 1) } }, 0, 4, nil)

      expect(near(track.at(2.5), 0.625)).toBe(true)
      expect(near(track.at(3), 0.75)).toBe(true)
      expect(near(track.at(3.5), 0.375)).toBe(true)
      expect(near(track.at(4), 0)).toBe(true)
    end)

    test("a lane that only waits is inert", function()
      expect(mods.inert({ delay(1) })).toBe(true)
      expect(mods.inert({ delay(1), tween(0, 1, 1) })).toBe(false)
    end)
  end)

  harness.describe("what a lane reaches and how long a fire says it runs", function()
    test("a track answers each lane's reach and nothing for a lane it does not hold", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ start = { tween(0, 1, 2) }, dissipate = { onward(0, 0.4), onward(1, 0.3) } }, 0, 5, piece)

      expect(track.reach("start")).toBe(2)
      expect(near(track.reach("dissipate"), 0.7)).toBe(true)
      expect(track.reach("end")).toBe(0)
    end)

    test("a row at rest reaches nothing on any lane", function()
      local track = built({}, 3, 5, nil)

      expect(track.reach("start")).toBe(0)
      expect(track.reach("dissipate")).toBe(0)
    end)

    -- a lane whose entries snap takes no time, and its reach says so rather
    -- than the row's span the sampler falls back to
    test("an event lane naming no duration reaches the row's span, and one that snaps reaches nothing", function()
      local piece = mods.piece({ "dissipate", "despawn" })
      local track = built({ dissipate = { onward(0, nil) }, despawn = { onward(0, 0) } }, 1, 6, piece)

      expect(track.reach("dissipate")).toBe(6)
      expect(track.reach("despawn")).toBe(0)
    end)

    -- the old reading, kept as a golden: fired past the row's span, a lane's
    -- entry naming no duration has no time left and lands at once
    test("a fire past the row's span that says nothing leaves such an entry no time", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ dissipate = { onward(0, nil) } }, 1, 1, piece)

      piece:fire("dissipate", 2)

      expect(near(track.at(2.5), 0)).toBe(true)
    end)

    test("a fire that says how long its phase runs gives such an entry that time", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ dissipate = { onward(0, nil) } }, 1, 1, piece)

      piece:fire("dissipate", 2, 2)

      expect(near(track.at(3), 0.5)).toBe(true)
      expect(near(track.at(4), 0)).toBe(true)
    end)

    test("firing again without a time goes back to what the effect has left", function()
      local piece = mods.piece({ "dissipate" })
      local track = built({ dissipate = { onward(0, nil) } }, 1, 1, piece)

      piece:fire("dissipate", 2, 2)
      piece:fire("dissipate", 0.5)

      expect(near(track.at(0.75), 0.5)).toBe(true)
      expect(near(track.at(1), 0)).toBe(true)
    end)

    test("a piece keeps a told time only once some fire names one", function()
      local piece = mods.piece({ "dissipate" })

      piece:fire("dissipate", 1)

      expect(piece.runs).toBe(nil)

      piece:fire("dissipate", 1, 0.5)

      expect(piece.runs.dissipate).toBe(0.5)

      piece:fire("dissipate", 1, 0 / 0)

      expect(piece.runs.dissipate).toBe(nil)
    end)
  end)
end)
