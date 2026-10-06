local fs = require("@lune/fs")
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local curve = require("@mod/curve")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local adapters = require("@mod/adapters")
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
local function custom(
  id: string,
  emit: (sdk: any, ctx: any, attrs: any, props: any) -> (),
  attributes: { [string]: any }?,
  properties: { [string]: any }?
)
  registry.register({
    id = id,
    display = { name = id },
    classifier = "Folder",
    attributes = attributes or {},
    properties = properties or {},
    emit = function(ctx: any, attrs: any, props: any)
      facade.run(emit, ctx, attrs, props)
    end,
  })
end

-- what a value an author is handed is, a Track's view told apart from the
-- reader's own Track and from any other table
local function kindOf(value: any)
  local viewed = type(value) == "table" and value.reach == nil and getmetatable(value) ~= nil and table.isfrozen(value)

  return if viewed then "view" else typeof(value)
end

local function walked(read: any)
  local kinds = {}

  for name, value in read do
    kinds[name] = kindOf(value)
  end

  return kinds
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

    test("the classes behind a knob, a mod spec and a curve are frozen, as every effect's share them", function()
      expect(table.isfrozen(getmetatable(sdk.knob(1)))).toBe(true)
      expect(table.isfrozen(getmetatable(sdk.mod.to(1)))).toBe(true)
      expect(table.isfrozen(getmetatable(sdk.curve(1, "linear")))).toBe(true)
    end)

    test("a call without the ctx the emit was handed is refused with the reason", function()
      local ok, err = pcall(sdk.wait, 5 :: any, 1)

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "sdk.wait takes the ctx your emit was handed", 1, true) ~= nil).toBe(true)
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

    test(
      "a preset's shape cannot be rewritten through an author's curve, and every built-in eases as before",
      function()
        local c = sdk.curve(1, "easeOut")
        local shape = c.shape :: any

        expect((pcall(function()
          shape.xs[2] = 1
        end))).toBe(false)

        expect((pcall(function()
          shape.steps = {}
        end))).toBe(false)

        expect(curve.new(1, "easeOut"):at(0.5)).toBe(0.87509411341477272)
      end
    )

    test("a chain or path curve holds a frozen copy of the shape the built-ins share", function()
      local chain = { vector.create(0, 0), vector.create(0.3, 0.05), vector.create(0.65, 0.95), vector.create(1, 1) }
      local shared = curve.new(1, chain)
      local c = sdk.curve(1, chain)
      local shape = c.shape :: any

      expect(shape ~= shared.shape).toBe(true)
      expect(table.isfrozen(shape) and table.isfrozen(shape.xs) and table.isfrozen(shape.ys)).toBe(true)
      expect(shape.steps ~= nil and table.isfrozen(shape.steps)).toBe(true)

      expect((pcall(function()
        shape.ys[2] = 1
      end))).toBe(false)

      for _, t in { 0.1, 0.3, 0.5, 0.9 } do
        expect(c:at(t)).toBe(shared:at(t))
      end
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

    test("refuses any text that is no preset, and still reads a serialized value", function()
      for _, text in { "ease-out", "easeOut ", "ease out" } do
        local ok, err = pcall(sdk.curve, 1, text)

        expect(ok).toBe(false)
        expect(string.find(tostring(err), `{text} is no curve preset, use linear`, 1, true) ~= nil).toBe(true)
      end

      local serialized = curves.PRESETS.easeIn

      expect(math.abs(sdk.curve(1, serialized):at(0.3) - sdk.curve(1, "easeIn"):at(0.3)) < 1e-9).toBe(true)
    end)

    test("copies a buffer shape, so a buffer changed later changes nothing", function()
      local source = buffer.fromstring(curves.PRESETS.linear)
      local first = sdk.curve(1, source)
      local before = first:at(0.5)

      buffer.writestring(source, 0, curves.PRESETS.easeIn)

      local second = sdk.curve(1, source)

      expect(first:at(0.5)).toBe(before)
      expect(math.abs(second:at(0.5) - sdk.curve(1, "easeIn"):at(0.5)) < 1e-9).toBe(true)
      expect(math.abs(second:at(0.5) - before) > 1e-3).toBe(true)
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

    test("a late step runs after every early step of the frame, and a bad pass is refused", function()
      fresh()

      local order = {}
      local err

      custom("passes", function(sdk: any, ctx: any)
        sdk.step(ctx, function()
          table.insert(order, "late")
        end, "late")
        sdk.step(ctx, function()
          table.insert(order, "early")
        end)

        local ok, problem = pcall(sdk.step, ctx, function() end, "middle")

        err = if ok then "" else tostring(problem)
        sdk.wait(ctx, 0.5)
      end)

      play()
      scheduler.frame(0.25)

      expect(order).toEqual({ "early", "late" })
      expect(string.find(err, 'sdk.step\'s pass is "early" or "late", got middle', 1, true) ~= nil).toBe(true)
    end)

    test("a step is still called while its effect is paused, with no time passing", function()
      fresh()

      local seen = {}

      custom("paused_step", function(sdk: any, ctx: any)
        sdk.step(ctx, function(dt: number)
          table.insert(seen, dt)
        end)
        sdk.wait(ctx, 1)
      end)

      local env = play()

      env:Pause()
      scheduler.frame(0.25)
      env:Resume()
      scheduler.frame(0.25)

      expect(seen).toEqual({ 0, 0.25 })
    end)

    test("context answers edit outside a running game", function()
      expect(sdk.context()).toBe("edit")
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

    test("a writer handle holds nothing an author can reach", function()
      fresh()

      local reached = nil

      custom("sealed", function(sdk: any, ctx: any)
        reached = next(sdk.getWriter(ctx, harness.make("Part"), "Transparency"))
      end)

      play()

      expect(reached).toBe(nil)
    end)

    test("speed runs the effect's time at a param's value", function()
      fresh()

      local seen = {}

      custom("fast", function(sdk: any, ctx: any, attrs: any)
        sdk.speed(ctx, attrs.Speed)
        sdk.step(ctx, function(dt: number)
          table.insert(seen, dt)
        end)
        sdk.wait(ctx, 1)
      end, { Speed = knob(2):mod() })

      play()
      scheduler.frame(0.25)

      expect(seen).toEqual({ 0.5 })
    end)
  end)

  harness.describe("a param's Track", function()
    test("reaches emit as a frozen view of value, animated and duration, read with :at", function()
      fresh()

      local seen

      custom("viewed", function(_, _, attrs: any)
        local track = attrs.Growth

        seen = {
          frozen = table.isfrozen(track),
          value = track.value,
          animated = track.animated,
          duration = track.duration,
          at = track:at(0.5),
          same = rawequal(track, attrs.Growth),
          fields = {},
        }

        for key in track do
          table.insert(seen.fields, key)
        end

        table.sort(seen.fields)
      end, { Growth = knob(2):mod(mod.from(0):duration(1):curve("linear")) })

      play()

      expect(seen.frozen).toBe(true)
      expect(seen.value).toBe(2)
      expect(seen.animated).toBe(true)
      expect(seen.duration).toBe(1)
      expect(math.abs(seen.at - 1) < 0.2).toBe(true)
      expect(seen.same).toBe(true)
      expect(seen.fields).toEqual({ "animated", "duration", "value" })
    end)

    test("refuses a dot call, naming the colon call", function()
      fresh()

      local err

      custom("dotted", function(_, _, attrs: any)
        local ok, problem = pcall(attrs.Growth.at, 0.5)

        err = if ok then "" else tostring(problem)
      end, { Growth = knob(2):mod() })

      play()

      expect(string.find(err, "call track:at(t), not track.at(t)", 1, true) ~= nil).toBe(true)
    end)

    test("attrs and props are read only, and iterate as views", function()
      fresh()

      local wrote, attrKinds, propKinds

      custom("readonly", function(_, _, attrs: any, props: any)
        wrote = pcall(function()
          attrs.Growth = 5
        end)

        attrKinds = walked(attrs)
        propKinds = walked(props)
      end, { Growth = knob(2):mod(), Count = knob(3) }, { Size = knob(1):mod() })

      play()

      expect(wrote).toBe(false)
      expect(attrKinds).toEqual({ Growth = "view", Count = "number" })
      expect(propKinds).toEqual({ Size = "view" })
    end)

    test("a copy of attrs is refused by name", function()
      fresh()

      local err

      custom("copied", function(_, _, attrs: any)
        local copy = table.clone(attrs)
        local ok, problem = pcall(function()
          return copy.Growth
        end)

        err = if ok then "" else tostring(problem)
      end, { Growth = knob(2):mod() })

      play()

      expect(string.find(err, "attrs and props are read only windows", 1, true) ~= nil).toBe(true)
    end)

    test("a rule and duration see views too, never the reader's Track", function()
      fresh()

      local inRule, inDuration, ruleKinds, durationKinds
      local source = {
        sdk_version = 1,
        id = "ruled",
        display = { name = "Ruled" },
        classifier = "BasePart.Ruled",
        params = function(sdk: any)
          return {
            attributes = {
              Growth = sdk.knob(2):mod(),
              Shown = sdk.knob(true):readonly(function(_, attrs: any, props: any)
                inRule = attrs.Growth.reach == nil and attrs.Growth:at(0) == 2
                ruleKinds = { touched = kindOf(props.Transparency), attrs = walked(attrs), props = walked(props) }

                return false
              end),
            },
            properties = {
              Transparency = sdk.knob(0):mod(),
            },
          }
        end,
        duration = function(_, attrs: any, props: any)
          inDuration = attrs.Growth.reach == nil and attrs.Growth.value == 2
          durationKinds = {
            Growth = kindOf(attrs.Growth),
            Transparency = kindOf(props.Transparency),
            attrs = walked(attrs),
            props = walked(props),
          }

          return 1
        end,
        emit = function() end,
      }

      local sdk_custom = require("@root/sdk/custom")
      local added = sdk_custom.add("ruled", source, "tests.ruled")
      local part = harness.make("Part", harness.make("Folder"))

      part:AddTag("Ruled")
      effects.emit(0, part)
      sdk_custom.clear()

      expect(added).toBe(true)
      expect(inRule).toBe(true)
      expect(inDuration).toBe(true)
      expect(ruleKinds).toEqual({
        touched = "view",
        attrs = { Growth = "view" },
        props = { Transparency = "view" },
      })

      -- the mod rows a duration pulls are provisional and never kept, so its
      -- walk finds none
      expect(durationKinds).toEqual({
        Growth = "view",
        Transparency = "view",
        attrs = {},
        props = {},
      })
    end)

    test("speed refuses anything that is not a param's Track", function()
      fresh()

      local err

      custom("raw", function(sdk: any, ctx: any)
        local ok, problem = pcall(sdk.speed, ctx, row(2))

        err = if ok then "" else tostring(problem)
      end)

      play()

      expect(string.find(err, "sdk.speed takes a param declared with :mod()", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("sdk.apply", function()
    test("writes a plain value once", function()
      fresh()

      local seen = {}

      custom("plain", function(sdk: any, ctx: any, attrs: any)
        sdk.apply(ctx, attrs.Count, function(value: number)
          table.insert(seen, value)
        end)
        sdk.wait(ctx, 0.5)
      end, { Count = knob(3) })

      play()
      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(seen).toEqual({ 3 })
    end)

    test("writes an animated row at once and every frame it runs, and a static one once", function()
      fresh()

      local moving, still = {}, {}

      custom("animated", function(sdk: any, ctx: any, attrs: any)
        sdk.apply(ctx, attrs.Growth, function(value: number)
          table.insert(moving, value)
        end)
        sdk.apply(ctx, attrs.Flat, function(value: number)
          table.insert(still, value)
        end)
        sdk.wait(ctx, 1)
      end, { Growth = knob(2):mod(mod.from(0):duration(0.5)), Flat = knob(4):mod() })

      play()
      scheduler.frame(0.25)
      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(moving[1]).toBe(0)
      expect(#moving >= 3).toBe(true)
      expect(moving[#moving]).toBe(2)
      expect(still).toEqual({ 4 })
    end)

    test("apply then return: the write reaches the row's end and the effect ends only after its span", function()
      fresh()

      local seen = {}

      custom("applied", function(sdk: any, ctx: any, attrs: any)
        sdk.apply(ctx, attrs.Growth, function(value: number)
          table.insert(seen, value)
        end)
      end, { Growth = knob(2):mod(mod.from(0):duration(0.5)) })

      local env = play()

      expect(ended(env)).toBe(false)

      scheduler.frame(0.25)

      expect(ended(env)).toBe(false)

      scheduler.frame(0.25)

      expect(seen[1]).toBe(0)
      expect(#seen >= 3).toBe(true)
      expect(seen[#seen]).toBe(2)
      expect(ended(env)).toBe(true)
    end)

    test("a static row applied then returned ends the effect at once", function()
      fresh()

      local seen = {}

      custom("applied_flat", function(sdk: any, ctx: any, attrs: any)
        sdk.apply(ctx, attrs.Flat, function(value: number)
          table.insert(seen, value)
        end)
      end, { Flat = knob(4):mod() })

      local env = play()

      expect(seen).toEqual({ 4 })
      expect(ended(env)).toBe(true)
    end)

    test("refuses a table that is not a param's value", function()
      fresh()

      local err

      custom("apply_raw", function(sdk: any, ctx: any)
        local ok, problem = pcall(sdk.apply, ctx, row(2), function() end)

        err = if ok then "" else tostring(problem)
      end)

      play()

      expect(string.find(err, "sdk.apply takes a param's value", 1, true) ~= nil).toBe(true)
    end)

    test("a write that throws is warned once and ends the effect", function()
      fresh()

      custom("throws", function(sdk: any, ctx: any, attrs: any)
        sdk.apply(ctx, attrs.Growth, function()
          error("bad write")
        end)
        sdk.wait(ctx, 1)
      end, { Growth = knob(2):mod(mod.from(0):duration(0.5)) })

      local env
      local warnings = harness.captureWarnings(function()
        env = play()
        scheduler.frame(0.25)
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "bad write", 1, true) ~= nil).toBe(true)
      expect(ended(env)).toBe(true)
    end)
  end)

  harness.describe("sdk.warn", function()
    test("warns once per text and instance, and the effect plays on", function()
      fresh()

      local after = false

      custom("noted", function(sdk: any, ctx: any)
        sdk.warn(ctx, "no target found")
        sdk.warn(ctx, "no target found")
        sdk.warn(ctx, "too far")
        after = true
      end)

      local folder = harness.make("Folder")
      local warnings = harness.captureWarnings(function()
        effects.emit(0, folder)
        effects.emit(0, folder)
      end)

      expect(after).toBe(true)
      expect(#warnings).toBe(2)
      expect(string.find(warnings[1], "custom effect noted on", 1, true) ~= nil).toBe(true)
      expect(string.find(warnings[1], ": no target found", 1, true) ~= nil).toBe(true)
      expect(string.find(warnings[2], ": too far", 1, true) ~= nil).toBe(true)
    end)

    test("never silences a later failure on the same instance", function()
      fresh()

      custom("then_fails", function(sdk: any, ctx: any)
        sdk.warn(ctx, "careful")
        error("broke")
      end)

      local warnings = harness.captureWarnings(function()
        effects.emit(0, harness.make("Folder"))
      end)

      expect(#warnings).toBe(2)
      expect(string.find(warnings[2], "broke", 1, true) ~= nil).toBe(true)
    end)

    test("refuses a text that is not a string", function()
      fresh()

      local err

      custom("bad_text", function(sdk: any, ctx: any)
        local ok, problem = pcall(sdk.warn, ctx, 5)

        err = if ok then "" else tostring(problem)
      end)

      play()

      expect(string.find(err, "sdk.warn takes a string, got number", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("sdk.lock", function()
    test("a second emit on the instance ends silently and the first plays on", function()
      fresh()

      local played = 0

      custom("locked", function(sdk: any, ctx: any)
        sdk.lock(ctx)
        played += 1
        sdk.wait(ctx, 1)
      end)

      local folder = harness.make("Folder")
      local first, second
      local warnings = harness.captureWarnings(function()
        first = effects.emit(0, folder)
        second = effects.emit(0, folder)
      end)

      expect(played).toBe(1)
      expect(#warnings).toBe(0)
      expect(ended(second)).toBe(true)
      expect(ended(first)).toBe(false)

      scheduler.frame(0.6)
      scheduler.frame(0.6)

      expect(ended(first)).toBe(true)

      effects.emit(0, folder)

      expect(played).toBe(2)
    end)

    test("a second lock from the emit that holds it plays on", function()
      fresh()

      local played = 0

      custom("locked_twice", function(sdk: any, ctx: any)
        sdk.lock(ctx)
        sdk.lock(ctx)
        played += 1
        sdk.wait(ctx, 1)
      end)

      local env
      local warnings = harness.captureWarnings(function()
        env = play()
      end)

      expect(played).toBe(1)
      expect(#warnings).toBe(0)
      expect(ended(env)).toBe(false)

      scheduler.frame(0.6)
      scheduler.frame(0.6)

      expect(ended(env)).toBe(true)
    end)

    test("refuses a call from a step", function()
      fresh()

      local err

      custom("lock_step", function(sdk: any, ctx: any)
        sdk.step(ctx, function()
          if err == nil then
            local ok, problem = pcall(sdk.lock, ctx)

            err = if ok then "" else tostring(problem)
          end
        end)
        sdk.wait(ctx, 0.5)
      end)

      play()
      scheduler.frame(0.25)

      expect(string.find(err, "sdk.lock runs in emit only", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("sdk.guiRoot", function()
    -- lune has no Instance global, so the folder is made through the seam a
    -- spec stands a real one in for
    local function withInstances(body: () -> ())
      local create = adapters.create

      adapters.create = function(class: string)
        return harness.datatypes.Instance.new(class)
      end

      local ok, err = pcall(body)

      adapters.create = create

      assert(ok, err)
    end

    test("answers one non-archivable folder under StarterGui in the editor, made again once destroyed", function()
      withInstances(function()
        fresh()

        local first, second

        custom("gui_root", function(sdk: any, ctx: any)
          first = sdk.guiRoot(ctx)
          second = sdk.guiRoot(ctx)
        end)

        play()

        local starter = game:GetService("StarterGui")

        expect(first).toBe(second)
        expect(first.Name).toBe("VFXForgeGui")
        expect(first.ClassName).toBe("Folder")
        expect(first.Archivable).toBe(false)
        expect(first.Parent).toBe(starter)

        first:Destroy()

        local third

        fresh()
        custom("gui_root_again", function(sdk: any, ctx: any)
          third = sdk.guiRoot(ctx)
        end)

        play()

        expect(third ~= first).toBe(true)
        expect(third.Parent).toBe(starter)

        third:Destroy()
      end)
    end)

    test("never takes a user's archivable folder of the same name", function()
      withInstances(function()
        fresh()

        local starter = game:GetService("StarterGui")
        local theirs = harness.make("Folder", starter)

        theirs.Name = "VFXForgeGui"

        local root

        custom("gui_root_theirs", function(sdk: any, ctx: any)
          root = sdk.guiRoot(ctx)
        end)

        play()

        expect(root ~= theirs).toBe(true)
        expect(root.Archivable).toBe(false)

        theirs:Destroy()
        root:Destroy()
      end)
    end)

    test("takes a non-archivable folder of the name already under StarterGui", function()
      withInstances(function()
        fresh()

        local earlier

        custom("gui_root_earlier", function(sdk: any, ctx: any)
          earlier = sdk.guiRoot(ctx)
        end)

        play()
        earlier:Destroy()

        local starter = game:GetService("StarterGui")
        local ours = harness.make("Folder", starter)

        ours.Name = "VFXForgeGui"
        ours.Archivable = false

        local root

        fresh()
        custom("gui_root_ours", function(sdk: any, ctx: any)
          root = sdk.guiRoot(ctx)
        end)

        play()

        expect(root).toBe(ours)

        ours:Destroy()
      end)
    end)

    test("lets go of its root once something makes it archivable", function()
      withInstances(function()
        fresh()

        local earlier

        custom("gui_root_kept", function(sdk: any, ctx: any)
          earlier = sdk.guiRoot(ctx)
        end)

        play()

        earlier.Archivable = true

        local root

        fresh()
        custom("gui_root_after", function(sdk: any, ctx: any)
          root = sdk.guiRoot(ctx)
        end)

        play()

        expect(root ~= earlier).toBe(true)
        expect(root.Archivable).toBe(false)

        earlier:Destroy()
        root:Destroy()
      end)
    end)
  end)

  harness.describe("awaiting a join", function()
    test("a piece awaits another join after the body returned, and the effect ends", function()
      fresh()

      local order = {}

      custom("cross_await", function(sdk: any, ctx: any)
        local a = sdk.join(ctx)
        local b = sdk.join(ctx)

        sdk.spawn(a, function()
          sdk.wait(ctx, 1)
          table.insert(order, "a")
        end)

        sdk.spawn(b, function()
          sdk.wait(ctx, 0.5)
          sdk.await(a)
          table.insert(order, "b")
        end)
      end)

      local env = play()

      scheduler.frame(0.5)
      scheduler.frame(0.5)

      expect(order).toEqual({ "a", "b" })
      expect(ended(env)).toBe(true)
    end)

    test("two pieces awaiting one join both resume", function()
      fresh()

      local resumed = 0

      custom("double_await", function(sdk: any, ctx: any)
        local a = sdk.join(ctx)
        local b = sdk.join(ctx)

        sdk.spawn(a, function()
          sdk.wait(ctx, 1)
        end)

        for _ = 1, 2 do
          sdk.spawn(b, function()
            sdk.await(a)
            resumed += 1
          end)
        end
      end)

      local env = play()

      scheduler.frame(1)

      expect(resumed).toBe(2)
      expect(ended(env)).toBe(true)
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

  harness.describe("the ctx an author is handed", function()
    -- registers an effect whose author emit is also handed the runtime's own
    -- ctx, which no author ever sees, to try it on the facade
    local function handed(emit: (sdk: any, view: any, ctx: any) -> ())
      registry.register({
        id = "viewed",
        display = { name = "viewed" },
        classifier = "Folder",
        attributes = {},
        properties = {},
        emit = function(ctx: any, attrs: any, props: any)
          facade.run(function(sdk: any, view: any)
            emit(sdk, view, ctx)
          end, ctx, attrs, props)
        end,
      })
    end

    test("is a frozen table of ref, duration and constant, and holds nothing of the runtime's", function()
      fresh()

      local seen

      handed(function(_, view: any)
        seen = view
      end)

      local _, folder = play()
      local keys = {}

      for key in seen do
        table.insert(keys, key)
      end

      table.sort(keys)

      expect(keys).toEqual({ "duration", "ref" })
      expect(seen.ref).toBe(folder)
      expect(seen.duration).toBe(1)
      expect(seen.scope).toBe(nil)
      expect(seen.effect).toBe(nil)
      expect(seen.shared).toBe(nil)
      expect(seen.obj).toBe(nil)
      expect(getmetatable(seen)).toBe(nil)
      expect(table.isfrozen(seen)).toBe(true)
      expect((pcall(function()
        seen.scope = {}
      end))).toBe(false)
    end)

    test("carries constant when an Enabled loop emitted it", function()
      local seen

      facade.run(
        function(_, view: any)
          seen = view
        end,
        { ref = harness.make("Folder"), scope = { state = lifetime.RELEASED }, duration = 2, constant = true },
        {},
        {}
      )

      expect(seen.constant).toBe(true)
      expect(seen.duration).toBe(2)
    end)

    test("every entry that takes a ctx refuses the runtime's own and a table like the view, naming the call", function()
      fresh()

      local refusals = {}
      local expected = {}

      handed(function(sdk: any, view: any, ctx: any)
        local calls = {
          wait = { sdk.wait, 0 },
          step = { sdk.step, function() end },
          tween = { sdk.tween, sdk.curve(1, "linear"), function() end },
          hold = { sdk.hold, function() end },
          join = { sdk.join },
          emit = { sdk.emit, harness.make("Configuration") },
          getWriter = { sdk.getWriter, view.ref, "Name" },
          getAttributeWriter = { sdk.getAttributeWriter, view.ref, "A" },
          speed = {
            sdk.speed,
            {
              at = function()
                return 1
              end,
            },
          },
        }

        for name, call in calls do
          for kind, given in { runtime = ctx, copy = { ref = view.ref, duration = view.duration } } do
            local ok, err = pcall(call[1], given, table.unpack(call, 2))
            local wording = string.find(tostring(err), `sdk.{name} takes the ctx your emit was handed`, 1, true)

            refusals[`{name} {kind}`] = not ok and wording ~= nil
            expected[`{name} {kind}`] = true
          end
        end
      end)

      play()

      expect(next(expected) ~= nil).toBe(true)
      expect(refusals).toEqual(expected)
    end)
  end)

  harness.describe("engine functions as callbacks", function()
    -- an engine function runs with the rights of whoever calls it, so the
    -- runtime calling one for an author would run it with the host's
    local REFUSED = "takes a function of your own, not an engine function; wrap the call in one"

    test("every entry that takes a callback refuses an engine function, naming the call", function()
      fresh()

      local refusals = {}

      local function refused(name: string, fn: (...any) -> any, ...: any)
        local ok, err = pcall(fn, ...)

        refusals[name] = not ok and string.find(tostring(err), `sdk.{name} {REFUSED}`, 1, true) ~= nil
      end

      custom("engine", function(sdk: any, ctx: any)
        local join = sdk.join(ctx)

        refused("step", sdk.step, ctx, print)
        refused("tween", sdk.tween, ctx, sdk.curve(1, "linear"), math.floor)
        refused("hold", sdk.hold, ctx, print)
        refused("spawn", sdk.spawn, join, print, "http://127.0.0.1:1/")
        refused("apply", sdk.apply, ctx, 1, print)
      end)

      play()
      refused("curve", sdk.curve, 1, math.floor)

      expect(refusals).toEqual({ step = true, tween = true, hold = true, spawn = true, apply = true, curve = true })
    end)

    test("a function of the author's own is still taken, and spawn hands it its arguments", function()
      fresh()

      local got
      local held = false

      custom("own", function(sdk: any, ctx: any)
        local join = sdk.join(ctx)

        sdk.hold(ctx, function()
          held = true
        end)

        sdk.spawn(join, function(a: number, b: string)
          got = { a, b }
        end, 1, "two")
      end)

      local env = play()

      expect(got).toEqual({ 1, "two" })
      expect(ended(env)).toBe(true)
      expect(held).toBe(true)
      expect(sdk
        .curve(1, function(t: number)
          return t
        end)
        :at(0.25)).toBe(0.25)
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
