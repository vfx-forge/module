const harness = require("@tests/harness")
const effects = require("@srv/effects")
const lifetime = require("@mod/lifetime")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const failures = require("@mod/lightning/failures")
const test, expect = harness.test, harness.expect

const function failing()
  error("the bolt broke")
end

-- a stub on the effects service, its emit handed what plays a bolt; put back once `body` ends
const function staged(emit: (ctx: any) -> (), body: (root: Instance) -> ())
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register({
    id = "failing_bolt",
    display = { name = "Failing" },
    classifier = "Folder.FailingBolt",
    attributes = {},
    properties = {},
    emit = emit,
  })

  const root = harness.make("Folder", harness.make("Folder"))

  root.Name = "Storm"
  root:AddTag("FailingBolt")

  const ok, err = pcall(body, root)

  registry.clear()

  if not ok then
    error(err, 0)
  end
end

const function failed(warnings: { string }): { string }
  const out = {}

  for _, text in warnings do
    if string.find(text, "a bolt failed", 1, true) then
      table.insert(out, text)
    end
  end

  return out
end

harness.suite(function()
  harness.describe("a failing lightning bolt", function()
    test("warns once for its instance however often it fails, and its sibling bolts play on", function()
      local played = 0

      staged(function(ctx: any)
        const bolts = lifetime.join(ctx.scope)

        lifetime.spawn(bolts, failures.body, ctx.ref, failing)
        lifetime.spawn(bolts, failures.body, ctx.ref, function()
          played += 1
        end)
        lifetime.awaitJoin(bolts)
      end, function(root: Instance)
        const warned = failed(harness.captureWarnings(function()
          for _ = 1, 7 do
            effects.emit(0, root)
          end
        end))

        expect(#warned).toBe(1)
        expect(string.find(warned[1], root:GetFullName(), 1, true) ~= nil).toBe(true)
        expect(played).toBe(7)
      end)
    end)

    test("a failing frame warns once for its instance and ends its effect", function()
      staged(function(ctx: any)
        lifetime.step(ctx.scope, failures.step(ctx.ref, ctx.scope, failing), "screen")
        lifetime.wait(ctx.scope, 10)
      end, function(root: Instance)
        const envs = {}
        const warned = failed(harness.captureWarnings(function()
          for i = 1, 7 do
            envs[i] = effects.emit(0, root)
            scheduler.frame(1 / 60)
          end
        end))

        expect(#warned).toBe(1)
        expect(string.find(warned[1], root:GetFullName(), 1, true) ~= nil).toBe(true)

        for _, env in envs do
          expect(env.Finished:getStatus() ~= "Started").toBe(true)
        end
      end)
    end)
  end)
end)
