local codec = require("@mod/modifier_codec")

local function assertEqual(actual: unknown, expected: unknown, label: string)
  assert(actual == expected, `{label}: expected {tostring(expected)}, got {tostring(actual)}`)
end

local function roundTrip(v: any): any
  local q = { v = 2, lanes = { start = { { kind = "tween", chain = false, start = { t = "lit", v = v } } } } }
  return codec.decode(codec.encode(q :: any)).lanes.start[1].start.v
end

-- pins endpoint colour precision against the engine's own Color3 and
-- ColorSequence, a stronger claim than the lune spec's pin against lune's
-- emulated ones
return {
  {
    name = "an endpoint colour round trips at full precision",
    run = function()
      local colour = Color3.new(0.1234567, 0.5, 0.987654)
      assertEqual(roundTrip(colour), colour, "round tripped color")
    end,
  },

  {
    name = "a colour sequence endpoint keeps stops closer than 1/255 apart",
    run = function()
      local stops = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
        ColorSequenceKeypoint.new(0.29045, Color3.new(0.2, 0.4, 0.6)),
        ColorSequenceKeypoint.new(0.2905, Color3.new(0.123, 0.456, 0.789)),
        ColorSequenceKeypoint.new(1, Color3.new(0, 0, 1)),
      })
      assertEqual(roundTrip(stops), stops, "round tripped sequence")
    end,
  },

  {
    name = "round-trips a gradient's raw stop array with real colors and exact times",
    run = function()
      local q = {
        v = 2,
        lanes = {
          start = {
            {
              kind = "gradient",
              chain = false,
              stops = {
                { time = 0, color = Color3.new(1, 0, 0), alpha = 0 },
                { time = 0.5, color = Color3.new(0, 1, 0), alpha = 0.25 },
              },
            },
          },
        },
      }
      local m = codec.decode(codec.encode(q :: any)).lanes.start[1]
      assertEqual(#m.stops, 2, "stop count")
      assertEqual(m.stops[1].color, Color3.new(1, 0, 0), "stop 1 color")
      assertEqual(m.stops[1].time, 0, "stop 1 time")
      assertEqual(m.stops[2].color, Color3.new(0, 1, 0), "stop 2 color")
      assertEqual(m.stops[2].time, 0.5, "stop 2 time")
      assertEqual(m.stops[2].alpha, 0.25, "stop 2 alpha")
    end,
  },
}
