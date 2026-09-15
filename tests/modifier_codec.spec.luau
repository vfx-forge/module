local Z = require("@z")
local codec = require("@mod/modifier_codec")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Color3, NumberSequence = harness.datatypes.Color3, harness.datatypes.NumberSequence
local Instance = harness.datatypes.Instance
local Vector3 = harness.datatypes.Vector3

local function curve(): buffer
  return buffer.fromstring("CURVEBYTES")
end

-- the version 1 layout, rebuilt here because the codec only writes version 2
-- now. this is the payload a store that predates lanes wrote, and the fold on
-- the way in is the whole reason it still reads
local function legacyPayload(queue: { any }): buffer
  local modifier = Z.schema({
    kind = Z.str8,
    chain = Z.bool,
    duration = Z.some(Z.f64),
    start = Z.some(Z.table),
    finish = Z.some(Z.table),
    curve = Z.some(Z.buffer16),
    weight = Z.some(Z.buffer16),
    envelope = Z.some(Z.buffer16),
    extra = Z.some(Z.table),
  })

  local entries = {}

  for i, m in queue do
    entries[i] = {
      kind = m.kind or "",
      chain = m.chain == true,
      duration = m.duration,
      start = m.start,
      finish = m.finish,
      curve = m.curve,
      weight = m.weight,
      envelope = m.envelope,
      extra = m.extra,
    }
  end

  local buf, err = Z.ser(Z.schema({ v = Z.u8, queue = Z.schema8({ modifier }) }), { v = 1, queue = entries })

  assert(err == nil and typeof(buf) == "buffer", "the version 1 payload could not be built")

  return buf :: buffer
end

harness.suite(function()
  harness.describe("modifier_codec", function()
    test("decode rejects a payload that is not a queue at all", function()
      expect(function()
        codec.decode(buffer.fromstring("not a queue"))
      end).toThrow()
    end)

    -- decode picks its schema off the last byte before it reads anything, so
    -- the layout ending in the version is load bearing rather than incidental
    test("the version is the last byte of the payload", function()
      local buf = codec.encode(codec.empty())

      expect(buffer.readu8(buf, buffer.len(buf) - 1)).toBe(2)
    end)

    test("decode rejects a newer payload version", function()
      local buf = codec.encode({ v = 2, lanes = {} })

      buffer.writeu8(buf, buffer.len(buf) - 1, 3)

      expect(function()
        codec.decode(buf)
      end).toThrow()
    end)

    test("decode rejects a payload truncated mid-modifier", function()
      local full = codec.encode({
        v = 1,
        queue = { { kind = "tween", chain = false, curve = buffer.fromstring("CURVEBYTES") } },
      } :: any)
      local cut = buffer.create(buffer.len(full) - 4)
      buffer.copy(cut, 0, full, 0, buffer.len(cut))
      expect(function()
        codec.decode(cut)
      end).toThrow()
    end)

    test("encode rejects a queue whose queue field is not a table", function()
      expect(function()
        codec.encode({ v = 1, queue = "nope" } :: any)
      end).toThrow()
    end)

    test("encode names a type it cannot represent rather than dropping it", function()
      local q =
        { v = 1, queue = { { kind = "tween", chain = false, start = { t = "lit", v = Instance.new("Folder") } } } }
      expect(function()
        codec.encode(q :: any)
      end).toThrow()
    end)

    test("round-trips a mixed queue (datatypes + curve buffer)", function()
      local q = {
        v = 1,
        queue = {
          {
            kind = "tween",
            chain = false,
            duration = 2,
            start = { t = "lit", v = Color3.new(1, 0, 0) },
            finish = { t = "lit", v = Color3.new(0, 1, 0) },
            curve = curve(),
          },
          {
            kind = "randomizer",
            chain = true,
            start = { t = "lit", v = NumberSequence.new(0) },
            finish = { t = "lit", v = NumberSequence.new(1) },
            weight = curve(),
          },
        },
      }
      local d = codec.decode(codec.encode(q))
      expect(d.v).toBe(2)
      expect(d.lanes.start[1].kind).toBe("tween")
      expect(d.lanes.start[1].duration).toBe(2)
      expect(d.lanes.start[1].start.v).toBe(Color3.new(1, 0, 0))
      expect(d.lanes.start[1].finish.v).toBe(Color3.new(0, 1, 0))
      expect(buffer.tostring(d.lanes.start[1].curve)).toBe("CURVEBYTES")
      expect(d.lanes.start[2].chain).toBe(true)
      expect(d.lanes.start[2].start.v).toBe(NumberSequence.new(0))
    end)

    test("preserves unknown modifier kind and unknown fields", function()
      local q = { v = 1, queue = { { kind = "future_kind", chain = false, custom = 42 } } }
      local d = codec.decode(codec.encode(q))
      expect(d.lanes.start[1].kind).toBe("future_kind")
      expect(d.lanes.start[1].custom).toBe(42)
    end)

    local function roundTrip(v: any): any
      local q = { v = 1, queue = { { kind = "tween", chain = false, start = { t = "lit", v = v } } } }
      return codec.decode(codec.encode(q :: any)).lanes.start[1].start.v
    end

    test("round-trips the exactly-representable endpoint datatypes", function()
      local d = harness.datatypes
      local cases = {
        d.Vector2.new(1.5, -2.5),
        d.Vector3.new(1.5, -2.5, 3.5),
        d.UDim.new(0.5, -12),
        d.UDim2.new(0.25, 4, 0.75, -8),
        d.NumberRange.new(2, 7),
        d.NumberSequence.new(0.25),
        123.456,
        true,
        "a string endpoint",
      }

      for _, v in cases do
        local back = roundTrip(v)
        expect(typeof(back)).toBe(typeof(v))
        expect(back).toBe(v)
      end
    end)

    -- Z stores a Color3 as three bytes via Color3.fromRGB, so an endpoint colour
    -- lands on the nearest 8-bit-per-channel colour. pinned deliberately: it is
    -- the sRGB output resolution and quantizing is idempotent (a second round
    -- trip does not drift further), but it IS lossier than the engine's own
    -- float Color3, so a change here should be a decision and not a surprise
    test("quantizes an endpoint colour to 8 bits per channel", function()
      local Color3 = harness.datatypes.Color3
      local back = roundTrip(Color3.new(0.25, 0.5, 0.75))
      expect(typeof(back)).toBe("Color3")
      expect(back).toBe(Color3.fromRGB(64, 128, 191))
      expect(roundTrip(back)).toBe(back)
    end)

    test("round-trips a raw array of maps, which is how a gradient stores stops", function()
      local Color3 = harness.datatypes.Color3
      local q = {
        v = 1,
        queue = {
          {
            kind = "gradient",
            chain = false,
            stops = {
              { time = 0, color = Color3.new(1, 0, 0), alpha = 0 },
              { time = 0.5, color = Color3.new(0, 1, 0), alpha = 0.25 },
            },
            blend = "linear",
          },
        },
      }
      local m = codec.decode(codec.encode(q :: any)).lanes.start[1]
      expect(#m.stops).toBe(2)
      expect(m.stops[1].color).toBe(Color3.new(1, 0, 0))
      expect(m.stops[2].time).toBe(0.5)
      expect(m.stops[2].alpha).toBe(0.25)
      expect(m.blend).toBe("linear")
    end)

    -- legacy_mods lifts a legacy child's ResetOnFinish onto its modifier as
    -- `reset`, a field the schema does not name, so the applier only sees it if
    -- `extra` carries a boolean faithfully. false is the interesting one,
    -- because a decoder that confused it with absence would silently reset
    test("round-trips a boolean field the schema does not name", function()
      local yes = { v = 1, queue = { { kind = "tween", chain = false, reset = true } } }
      local no = { v = 1, queue = { { kind = "tween", chain = false, reset = false } } }

      expect(codec.decode(codec.encode(yes :: any)).lanes.start[1].reset).toBe(true)
      expect(codec.decode(codec.encode(no :: any)).lanes.start[1].reset).toBe(false)
    end)

    -- a rate is not one of the schema's KNOWN fields, deliberately: adding one
    -- would append to a positional layout and fail every queue already
    -- authored's read-the-whole-buffer check. So it rides `extra`, in both
    -- spellings, a plain number for a constant, and a nested table carrying a
    -- shape BUFFER for one that ramps. Nothing else in the format nests a
    -- buffer inside a table, so the two together are the shape to pin
    test("round-trips a rate, constant and ramped", function()
      local constant = { v = 1, queue = { { kind = "tween", chain = false, fps = 30 } } }

      expect(codec.decode(codec.encode(constant :: any)).lanes.start[1].fps).toBe(30)

      local ramped = {
        v = 1,
        queue = { { kind = "tween", chain = false, fps = { from = 12, to = 60, curve = curve() } } },
      }

      local out = codec.decode(codec.encode(ramped :: any)).lanes.start[1].fps

      expect(out.from).toBe(12)
      expect(out.to).toBe(60)
      expect(buffer.tostring(out.curve)).toBe("CURVEBYTES")
    end)

    test("round-trips field names and string values outside the dictionary", function()
      local q = {
        v = 1,
        queue = { { kind = "future_kind", chain = false, some_unlisted_field = "an unlisted value" } },
      }
      local m = codec.decode(codec.encode(q :: any)).lanes.start[1]
      expect(m.kind).toBe("future_kind")
      expect(m.some_unlisted_field).toBe("an unlisted value")
    end)

    test("the same queue always encodes to the same bytes", function()
      local function build()
        return {
          v = 1,
          queue = {
            { kind = "tween", chain = false, duration = 2, zzz = 1, aaa = 2, start = { t = "lit", v = 3 } },
          },
        }
      end
      expect(buffer.tostring(codec.encode(build() :: any))).toBe(buffer.tostring(codec.encode(build() :: any)))
    end)

    test("round-trips a var Value, an unknown tagged Value, and an envelope buffer", function()
      local q = {
        v = 1,
        queue = {
          {
            kind = "tween",
            chain = false,
            start = { t = "var", ref = "MyVar" },
            finish = { t = "future_tag", custom_field = 1 },
            envelope = buffer.fromstring("ENVBYTES"),
          },
        },
      }
      local d = codec.decode(codec.encode(q))
      local m = d.lanes.start[1]
      expect(m.start.t).toBe("var")
      expect(m.start.ref).toBe("MyVar")
      expect(m.finish.t).toBe("future_tag")
      expect(m.finish.custom_field).toBe(1)
      expect(buffer.tostring(m.envelope)).toBe("ENVBYTES")
    end)

    -- the draw tag was added to value.luau with no schema entry of its own,
    -- which only holds because a Value is stored self-describing. this pins that
    test("round-trips a draw Value with no schema entry of its own", function()
      local q = {
        v = 2,
        lanes = {
          start = {
            {
              kind = "tween",
              chain = false,
              start = { t = "draw", a = -2.5, b = 7 },
              finish = { t = "draw", a = Vector3.new(1, 2, 3), b = Vector3.new(4, 5, 6) },
            },
          },
        },
      }
      local m = codec.decode(codec.encode(q)).lanes.start[1]
      expect(m.start.t).toBe("draw")
      expect(m.start.a).toBe(-2.5)
      expect(m.start.b).toBe(7)
      expect(m.finish.t).toBe("draw")
      expect(m.finish.a).toEqual(Vector3.new(1, 2, 3))
      expect(m.finish.b).toEqual(Vector3.new(4, 5, 6))
    end)

    test("round-trips a lane map, offsets and all", function()
      local q = {
        v = 2,
        lanes = {
          start = { { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 0 } } },
          dissipate = {
            { kind = "tween", chain = false, offset = { t = "lit", v = 0.25 }, finish = { t = "lit", v = 1 } },
          },
        },
      }

      local d = codec.decode(codec.encode(q))

      expect(d.v).toBe(2)
      expect(#d.lanes.start).toBe(1)
      expect(d.lanes.start[1].duration).toBe(1)
      expect(d.lanes.dissipate[1].offset.v).toBe(0.25)
      expect(d.lanes.dissipate[1].finish.v).toBe(1)
    end)

    -- an offset stores as a Value the way an endpoint does, so a drawn one
    -- needs no schema entry; one written by hand as a number stores as a literal
    test("an offset written as a plain number stores as a literal", function()
      local q = { v = 2, lanes = { start = { { kind = "tween", chain = false, offset = 2 } } } }

      expect(codec.decode(codec.encode(q)).lanes.start[1].offset.v).toBe(2)
    end)

    test("empty is a payload with no lanes at all", function()
      local d = codec.decode(codec.encode(codec.empty()))

      expect(d.v).toBe(2)
      expect(d.lanes.start).toBe(nil)
    end)

    -- a version 1 queue is the start lane, because that is the one trigger it
    -- ever had
    test("a version 1 payload decodes to a start lane", function()
      local buf = legacyPayload({
        { kind = "tween", chain = false, duration = 2, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 10 } },
      })

      local d = codec.decode(buf)

      expect(d.v).toBe(2)
      expect(#d.lanes.start).toBe(1)
      expect(d.lanes.start[1].duration).toBe(2)
      expect(d.lanes.start[1].finish.v).toBe(10)
    end)

    test("a version 1 delay folds into the offset of the entry after it", function()
      local buf = legacyPayload({
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 1 } } },
        { kind = "tween", chain = false, duration = 2, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 10 } },
      })

      local lane = codec.decode(buf).lanes.start

      expect(#lane).toBe(1)
      expect(lane[1].kind).toBe("tween")
      expect(lane[1].offset.v).toBe(1)
    end)

    -- a delay shifted everything after it under version 1, not just the one
    -- entry right after it, so its wait has to ride every entry the fold
    -- passes before the next delay
    test("a version 1 delay rides every entry after it, not just the first", function()
      local buf = legacyPayload({
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 1 } } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 1 } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 1 }, finish = { t = "lit", v = 2 } },
      })

      local lane = codec.decode(buf).lanes.start

      expect(#lane).toBe(2)
      expect(lane[1].offset.v).toBe(1)
      expect(lane[2].offset.v).toBe(1)
    end)

    test("two version 1 delays in a row sum into the offset of the entry after them", function()
      local buf = legacyPayload({
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 1 } } },
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 2 } } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 1 } },
      })

      local lane = codec.decode(buf).lanes.start

      expect(#lane).toBe(1)
      expect(lane[1].offset.v).toBe(3)
    end)

    test("a second version 1 delay adds to what is already riding, for the entries after it", function()
      local buf = legacyPayload({
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 1 } } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 1 } },
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 2 } } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 1 }, finish = { t = "lit", v = 2 } },
      })

      local lane = codec.decode(buf).lanes.start

      expect(#lane).toBe(2)
      expect(lane[1].offset.v).toBe(1)
      expect(lane[2].offset.v).toBe(3)
    end)

    test("a drawn version 1 wait rides every entry after it as its own draw", function()
      local buf = legacyPayload({
        { kind = "delay", chain = false, extra = { wait = { t = "rand", min = 2, max = 5 } } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 1 } },
        { kind = "tween", chain = false, duration = 1, start = { t = "lit", v = 1 }, finish = { t = "lit", v = 2 } },
      })

      local lane = codec.decode(buf).lanes.start

      expect(#lane).toBe(2)
      expect(lane[1].offset.t).toBe("draw")
      expect(lane[1].offset.a).toBe(2)
      expect(lane[1].offset.b).toBe(5)
      expect(lane[2].offset.t).toBe("draw")
      expect(lane[2].offset.a).toBe(2)
      expect(lane[2].offset.b).toBe(5)
      expect(lane[1].offset == lane[2].offset).toBe(false)
    end)

    test("a version 1 delay with nothing after it is dropped, and a rand endpoint reads as a draw", function()
      local trailing = legacyPayload({
        { kind = "tween", chain = false, duration = 1, start = { t = "rand", min = 1, max = 3 } },
        { kind = "delay", chain = false, extra = { wait = { t = "lit", v = 5 } } },
      })

      local lane = codec.decode(trailing).lanes.start

      expect(#lane).toBe(1)
      expect(lane[1].offset).toBe(nil)
      expect(lane[1].start.t).toBe("draw")
      expect(lane[1].start.a).toBe(1)
      expect(lane[1].start.b).toBe(3)
    end)
  end)
end)
