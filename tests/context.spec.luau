local harness = require("@tests/harness")
local context_common = require("@mod/common/context")

local test, expect = harness.test, harness.expect

harness.suite(function()
  harness.describe("context", function()
    test("a live server owns its attribute writes", function()
      expect(context_common.serverContext(true, false)).toBe(true)
    end)

    -- the server resolves the defaults and they replicate down, so a client
    -- writing its own would only fight them
    test("a live client does not", function()
      expect(context_common.serverContext(false, false)).toBe(false)
    end)

    -- the team create regression: an edit session is a collaboration client, so
    -- RunService:IsServer() reads false there, and gating the write on that
    -- alone left an emitted effect with no attributes at all
    test("a plugin owns its attribute writes even where IsServer reads false", function()
      expect(context_common.serverContext(false, true)).toBe(true)
    end)

    test("a plugin ancestor is a plugin context in any session", function()
      expect(context_common.pluginContext(true, true, false)).toBe(true)
    end)

    test("an idle studio session is a plugin context without one", function()
      expect(context_common.pluginContext(false, true, false)).toBe(true)
    end)

    test("a studio session that is running is not", function()
      expect(context_common.pluginContext(false, true, true)).toBe(false)
    end)

    test("a live game is not", function()
      expect(context_common.pluginContext(false, false, true)).toBe(false)
    end)
  end)
end)
