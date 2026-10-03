local fs = require("@lune/fs")
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect
local row = harness.row

local facade = require("@root/sdk/v1/facade")

local CFrame = harness.datatypes.CFrame
local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3

local sdk = facade.sdk

-- the internal module a custom effect becomes, its emit run under the facade
local function custom(id: string, emit: (sdk: any, ctx: any, attrs: any, props: any) -> ())
  registry.register({
    id = id,
    display = { name = id },
    classifier = "Folder",
    attributes = {},
    properties = {},
    emit = function(ctx: any, attrs: any, props: any)
      facade.run(emit, ctx, attrs, props)
    end,
  })
end

local function fresh()
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
end

local function play(): (any, Instance)
  local folder = harness.make("Folder")

  return effects.emit(0, folder), folder
end

local function ended(env: any): boolean
  return env.Finished:getStatus() == "Resolved"
end

-- the field names a block of the types file declares at one indent
local function fieldsOf(lines: { string }, from: number, indent: string): ({ [string]: boolean }, { [string]: number })
  local names = {}
  local nested = {}
  local i = from

  while i <= #lines do
    local line = lines[i]

    if string.match(line, `^{string.sub(indent, 3)}}`) then
      break
    end

    local name = string.match(line, `^{indent}([%w_]+):`)

    if name ~= nil then
      names[name] = true

      if string.match(line, "{%s*$") then
        nested[name] = i + 1
      end
    end

    i += 1
  end

  return names, nested
end

harness.suite(function()
  harness.describe("the sdk 1 facade", function()
    test("every facade function has a type and every type a function", function()
      local lines = string.split(fs.readFile("src/sdk/v1/types.luau"), "\n")
      local start = table.find(lines, "export type V1 = {") :: number
      local names, nested = fieldsOf(lines, start + 1, "  ")

      for name, value in sdk do
        expect(`{name} {names[name] == true}`).toBe(`{name} true`)

        if type(value) == "table" then
          local inner = fieldsOf(lines, nested[name], "    ")

          for field in value do
            expect(`{name}.{field} {inner[field] == true}`).toBe(`{name}.{field} true`)
          end

          for field in inner do
            expect(`{name}.{field} {value[field] ~= nil}`).toBe(`{name}.{field} true`)
          end
        end
      end

      for name in names do
        expect(`{name} {sdk[name] ~= nil}`).toBe(`{name} true`)
      end
    end)

    test("is frozen, and so is every table on it", function()
      expect(table.isfrozen(sdk)).toBe(true)
      expect(table.isfrozen(facade)).toBe(true)

      for _, value in sdk do
        if type(value) == "table" then
          expect(table.isfrozen(value)).toBe(true)
        end
      end
    end)

    test("knob and mod build the rows and default modifiers the built-ins use", function()
      local row = sdk.knob(0.5):min(0):unit("seconds"):mod(sdk.mod.from(0):duration(1))

      expect(knob.is(row)).toBe(true)
      expect(mod.is(row.modDefault[1])).toBe(true)
      expect(mod.is(sdk.mod.to(1))).toBe(true)
    end)

    test("a call without the ctx emit was handed is refused with the reason", function()
      local ok, err = pcall(sdk.wait, 5 :: any, 1)

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "sdk.wait takes the ctx emit was handed", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("sdk.curve", function()
    test("takes the duration first, and answers a frozen curve", function()
      local c = sdk.curve(2, "easeIn")

      expect(c.duration).toBe(2)
      expect(table.isfrozen(c)).toBe(true)
      expect(math.abs(c:at(1) - 1) < 1e-6).toBe(true)
      expect(c:at(0.5) < 0.4).toBe(true)
    end)

    test("reads every preset, and a curve param's value", function()
      for name, serialized in curves.PRESETS do
        expect(math.abs(sdk.curve(1, name):at(0.3) - sdk.curve(1, serialized):at(0.3)) < 1e-9).toBe(true)
      end
    end)

    test("refuses a name that is no preset, naming the presets", function()
      local ok, err = pcall(sdk.curve, 1, "easeout")

      expect(ok).toBe(false)
      expect(
        string.find(tostring(err), "easeout is no curve preset, use linear, easeIn, easeOut or easeInOut", 1, true)
          ~= nil
      ).toBe(true)
    end)

    test("refuses a bad chain with the reason, and a point that is no vector", function()
      local ok, err = pcall(sdk.curve, 1, { vector.create(0, 0), vector.create(0.5, 1), vector.create(1, 1) })

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "a curve takes 2 or 3n + 1 points, got 3", 1, true) ~= nil).toBe(true)

      ok, err = pcall(sdk.curve, 1, { vector.create(0, 0), 1 :: any })

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "point 2 is a number, not a vector", 1, true) ~= nil).toBe(true)
    end)

    test("reads a chain when it is made, so changing the table later changes nothing", function()
      local chain = { vector.create(0, 0), vector.create(1, 1) }
      local first = sdk.curve(1, chain)

      chain[2] = vector.create(1, 0.5)

      local second = sdk.curve(1, chain)

      expect(math.abs(first:at(0.5) - 0.5) < 1e-6).toBe(true)
      expect(math.abs(second:at(0.5) - 0.25) < 1e-6).toBe(true)
    end)

    test("hands a function its time clamped to 0 to 1, as every other shape is", function()
      local seen = {}
      local c = sdk.curve(1, function(t: number)
        table.insert(seen, t)
        return t
      end)

      c:at(-1)
      c:at(2)

      expect(seen).toEqual({ 0, 1 })
      expect(c:at(0 / 0) ~= c:at(0 / 0)).toBe(true)
    end)

    test("refuses a duration that is no number, and any option", function()
      expect(pcall(sdk.curve, "1" :: any, "linear")).toBe(false)
      expect(pcall(sdk.curve, 1, "linear", { loop = true } :: any)).toBe(false)
      expect((pcall(sdk.curve, 1, "linear", {}))).toBe(true)
    end)
  end)

  harness.describe("the facade inside an emit", function()
    test("tween plays on effect time, the effect waits for it, and a false answer cannot stop it", function()
      fresh()

      local seen = {}

      custom("fade", function(sdk: any, ctx: any)
        sdk.tween(ctx, sdk.curve(1, "linear"), function(alpha: number)
          table.insert(seen, alpha)
          return false :: any
        end)
      end)

      local env = play()

      scheduler.frame(0.5)

      expect(ended(env)).toBe(false)

      scheduler.frame(0.5)

      expect(seen).toEqual({ 0, 0.5, 1 })
      expect(ended(env)).toBe(true)
    end)

    test("step hands the frame and the time since it began, stops when asked, and keeps nothing alive", function()
      fresh()

      local seen = {}
      local stop

      custom("stepper", function(sdk: any, ctx: any)
        stop = sdk.step(ctx, function(dt: number, elapsed: number)
          table.insert(seen, { dt, elapsed })
        end)

        sdk.wait(ctx, 1)
      end)

      local env = play()

      scheduler.frame(0.25)
      scheduler.frame(0.25)
      stop()
      scheduler.frame(0.25)

      expect(seen).toEqual({ { 0.25, 0.25 }, { 0.25, 0.5 } })

      scheduler.frame(0.25)

      expect(ended(env)).toBe(true)
    end)

    test("wait answers the time waited, and refuses to run inside a step", function()
      fresh()

      local waited
      local refused

      custom("waits", function(sdk: any, ctx: any)
        sdk.step(ctx, function()
          if refused == nil then
            local ok, err = pcall(sdk.wait, ctx, 1)

            refused = if ok then "" else tostring(err)
          end
        end)

        waited = sdk.wait(ctx, 0.5)
      end)

      play()
      scheduler.frame(0.3)
      scheduler.frame(0.3)

      expect(waited).toBe(0.6)
      expect(string.find(refused, "sdk.wait yields", 1, true) ~= nil).toBe(true)
    end)

    test("hold cleans up when the effect ends, and refuses what it cannot clean up", function()
      fresh()

      local cleaned = false
      local refused = false

      custom("holds", function(sdk: any, ctx: any)
        sdk.hold(ctx, function()
          cleaned = true
        end)

        refused = not pcall(sdk.hold, ctx, {})
        sdk.wait(ctx, 0.5)
      end)

      play()

      expect(cleaned).toBe(false)

      scheduler.frame(0.5)

      expect(cleaned).toBe(true)
      expect(refused).toBe(true)
    end)

    test("an effect waits for its pieces, awaited or not", function()
      fresh()

      local order = {}

      custom("pieces", function(sdk: any, ctx: any)
        local join = sdk.join(ctx)

        sdk.spawn(join, function(seconds: number)
          sdk.wait(ctx, seconds)
          table.insert(order, "piece")
        end, 1)

        table.insert(order, "body")
      end)

      local env = play()

      scheduler.frame(0.5)

      expect(ended(env)).toBe(false)

      scheduler.frame(0.5)

      expect(order).toEqual({ "body", "piece" })
      expect(ended(env)).toBe(true)
    end)

    test("await parks the body until the join is through", function()
      fresh()

      local order = {}

      custom("awaits", function(sdk: any, ctx: any)
        local join = sdk.join(ctx)

        sdk.spawn(join, function()
          sdk.wait(ctx, 0.5)
          table.insert(order, "piece")
        end)

        sdk.await(join)
        table.insert(order, "after")
      end)

      play()
      scheduler.frame(0.5)

      expect(order).toEqual({ "piece", "after" })
    end)

    test("emit plays a nested effect the effect waits for, and a clear ends both", function()
      fresh()

      local inner = harness.make("Configuration")

      registry.register({
        id = "inner",
        display = { name = "inner" },
        classifier = "Configuration",
        attributes = {},
        properties = {},
        emit = function(ctx: any)
          lifetime.wait(ctx.scope, 1)
        end,
      })

      custom("outer", function(sdk: any, ctx: any)
        sdk.emit(ctx, inner)
      end)

      local env = play()

      scheduler.frame(0.5)

      expect(ended(env)).toBe(false)

      scheduler.frame(0.5)

      expect(ended(env)).toBe(true)

      local again = play()

      again:Clear()

      expect(ended(again)).toBe(true)
    end)

    test("a writer writes now and puts the authored value back at the end", function()
      fresh()

      local part = harness.make("Part") :: Part

      part.Transparency = 0.25
      part:SetAttribute("Glow", 1)

      custom("writes", function(sdk: any, ctx: any)
        sdk.getWriter(ctx, part, "Transparency"):set(0.75)
        sdk.getAttributeWriter(ctx, part, "Glow"):set(2)
        sdk.wait(ctx, 0.5)
      end)

      play()

      expect(part.Transparency).toBe(0.75)
      expect(part:GetAttribute("Glow")).toBe(2)

      scheduler.frame(0.5)

      expect(part.Transparency).toBe(0.25)
      expect(part:GetAttribute("Glow")).toBe(1)
    end)

    test("a write the target refuses is warned once per writer", function()
      fresh()

      local part = harness.make("Part")

      custom("refused", function(sdk: any, ctx: any)
        local writer = sdk.getWriter(ctx, part, "Transparency")

        writer:set("clear")
        writer:set("clear")
      end)

      local warnings = harness.captureWarnings(function()
        play()
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "a string could not be written to Transparency", 1, true) ~= nil).toBe(true)
    end)

    test("speed runs the effect's time at the track's value", function()
      fresh()

      local seen = {}

      custom("fast", function(sdk: any, ctx: any)
        sdk.speed(ctx, row(2))
        sdk.step(ctx, function(dt: number)
          table.insert(seen, dt)
        end)
        sdk.wait(ctx, 1)
      end)

      play()
      scheduler.frame(0.25)

      expect(seen).toEqual({ 0.5 })
    end)
  end)

  harness.describe("a failing custom effect", function()
    test("an emit that throws is warned once per instance, ends, and lets go of what it held", function()
      fresh()

      local released = 0

      custom("broken", function(sdk: any, ctx: any)
        sdk.hold(ctx, function()
          released += 1
        end)

        error("boom")
      end)

      local folder = harness.make("Folder")
      local warnings = harness.captureWarnings(function()
        expect(ended(effects.emit(0, folder))).toBe(true)
        expect(ended(effects.emit(0, folder))).toBe(true)
      end)

      expect(released).toBe(2)
      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "custom effect broken failed on", 1, true) ~= nil).toBe(true)
      expect(string.find(warnings[1], "boom", 1, true) ~= nil).toBe(true)
    end)

    test("a step that throws ends the effect at that frame, warned once", function()
      fresh()

      local after = false

      custom("bad_step", function(sdk: any, ctx: any)
        sdk.step(ctx, function()
          error("step boom")
        end)

        sdk.wait(ctx, 10)
        after = true
      end)

      local env
      local warnings = harness.captureWarnings(function()
        env = play()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      expect(ended(env)).toBe(true)
      expect(after).toBe(false)
      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "step boom", 1, true) ~= nil).toBe(true)
    end)

    test("a tween callback that throws on its first value stops the body there", function()
      fresh()

      local after = false

      custom("bad_tween", function(sdk: any, ctx: any)
        sdk.tween(ctx, sdk.curve(1, "linear"), function()
          error("tween boom")
        end)

        after = true
      end)

      local env
      local warnings = harness.captureWarnings(function()
        env = play()
      end)

      expect(ended(env)).toBe(true)
      expect(after).toBe(false)
      expect(#warnings).toBe(1)
    end)

    test("a piece that throws ends its effect, warned once", function()
      fresh()

      custom("bad_piece", function(sdk: any, ctx: any)
        local join = sdk.join(ctx)

        sdk.spawn(join, function()
          sdk.wait(ctx, 0.1)
          error("piece boom")
        end)

        sdk.wait(ctx, 10)
      end)

      local env
      local warnings = harness.captureWarnings(function()
        env = play()
        scheduler.frame(0.1)
      end)

      expect(ended(env)).toBe(true)
      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "piece boom", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("the facade's math", function()
    test("lerp blends any supported value", function()
      expect(sdk.lerp(0, 10, 0.25)).toBe(2.5)
      expect(sdk.lerp(Vector3.zero, Vector3.one, 0.5)).toBe(Vector3.one * 0.5)
    end)

    test("color blends in Oklab and converts both ways", function()
      local red = Color3.new(1, 0, 0)
      local back = sdk.color.fromOklab(sdk.color.toOklab(red))

      expect(math.abs(back.R - 1) < 1e-4).toBe(true)
      expect(sdk.color.blend(red, red, 0.5)).toBe(sdk.color.fromOklab(sdk.color.toOklab(red)))
    end)

    test("every shape answers a point inside it, the same one for the same seed", function()
      local cframe = CFrame.new(10, 0, 0)
      local size = Vector3.new(2, 2, 2)

      for _, name in { "box", "cylinder", "sphere", "disc" } do
        local point = sdk.shape[name](cframe, size, { seed = 3 })

        expect(typeof(point)).toBe("Vector3")
        expect((point - cframe.Position).Magnitude <= math.sqrt(3) + 1e-6).toBe(true)
        expect(sdk.shape[name](cframe, size, { seed = 3 })).toBe(point)
      end
    end)

    test("a bezier answers its points, length and direction, and NaN reads NaN everywhere", function()
      local path = sdk.bezier.new({ vector.create(0, 0, 0), vector.create(10, 0, 0) })
      local nan = path:at(0 / 0)

      expect(path:at(0.5)).toBe(vector.create(5, 0, 0))
      expect(math.abs(path:length() - 10) < 1e-6).toBe(true)
      expect(path:tangent(0.5)).toBe(vector.create(1, 0, 0))
      expect(nan.x ~= nan.x).toBe(true)
      expect(path:atUniform(0 / 0).x ~= path:atUniform(0 / 0).x).toBe(true)
      expect(path:tangent(0 / 0).x ~= path:tangent(0 / 0).x).toBe(true)

      path:set({ vector.create(0, 0, 0), vector.create(0, 20, 0) })

      expect(math.abs(path:length() - 20) < 1e-6).toBe(true)
      expect(table.isfrozen(path)).toBe(true)
      expect(table.isfrozen(getmetatable(path))).toBe(true)
    end)

    test("a bezier refuses a point that is no vector and a count that is no chain", function()
      local ok, err = pcall(sdk.bezier.new, { vector.zero, CFrame.new() :: any })

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "point 2 is a CFrame, not a vector", 1, true) ~= nil).toBe(true)

      ok, err = pcall(sdk.bezier.new, { vector.zero, vector.one, vector.zero })

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "2 or 3n + 1 points, got 3", 1, true) ~= nil).toBe(true)
    end)
  end)
end)
