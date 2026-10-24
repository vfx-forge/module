local harness = require("@tests/harness")
local instance_value = require("@mod/instance_value")
local test, expect = harness.test, harness.expect

-- a stand-in for the engine's handle and the instance behind it, which lune
-- cannot make: a handle is a table naming its target, a target a table naming
-- its classes and whether it is still in the place
local function target(classes: { string }, alive: boolean?)
  return { classes = classes, alive = alive ~= false }
end

local function handle(inst: any)
  return { handle = true, inst = inst }
end

local probe = {
  kind = function(v: any)
    if type(v) == "table" and v.handle then
      return "InstanceHandle"
    end

    return typeof(v)
  end,
  get = function(v: any)
    return v.inst
  end,
  alive = function(inst: any)
    return inst.alive
  end,
  isA = function(inst: any, class: string)
    return table.find(inst.classes, class) ~= nil
  end,
}

harness.suite(function()
  harness.describe("instance_value.accept", function()
    test("a handle to a live instance of an allowed class is answered", function()
      local part = target({ "Part", "BasePart" })
      local inst, reason = instance_value.accept(handle(part), { "Attachment", "BasePart" }, probe)

      expect(inst).toBe(part)
      expect(reason).toBe(nil)
    end)

    test("no classes takes any class", function()
      local model = target({ "Model" })

      expect(instance_value.accept(handle(model), nil, probe)).toBe(model)
    end)

    test("a target no longer in the place reads nil without a reason", function()
      local inst, reason = instance_value.accept(handle(target({ "Part" }, false)), nil, probe)

      expect(inst).toBe(nil)
      expect(reason).toBe(nil)
    end)

    test("a handle with no target reads nil without a reason", function()
      local inst, reason = instance_value.accept(handle(nil), nil, probe)

      expect(inst).toBe(nil)
      expect(reason).toBe(nil)
    end)

    test("a target of a class the row does not take reads nil without a reason", function()
      local inst, reason = instance_value.accept(handle(target({ "Model" })), { "BasePart" }, probe)

      expect(inst).toBe(nil)
      expect(reason).toBe(nil)
    end)

    test("nothing stored reads nil without a reason", function()
      local inst, reason = instance_value.accept(nil, nil, probe)

      expect(inst).toBe(nil)
      expect(reason).toBe(nil)
    end)

    test("a value of another kind reads nil and names its kind", function()
      local inst, reason = instance_value.accept("Part", { "BasePart" }, probe)

      expect(inst).toBe(nil)
      expect(reason).toBe("string")
    end)
  end)
end)
