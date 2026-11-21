local fs = require("@lune/fs")
local serde = require("@lune/serde")
local harness = require("@tests/harness")

local describe, test, expect = harness.describe, harness.test, harness.expect

-- the plugin reads what a place's module plays off its attributes, never by
-- running it. every build of the module (the release rbxm, a Wally or npm
-- install, the Insert Emit Module button's download) comes from this project,
-- so the project stamps them: the version Wally publishes under, which the
-- release workflow refuses a tag that disagrees with, and what it plays that
-- older modules do not. without them only the button's own stamp was read,
-- and a Wally install of a module that plays it read as one that does not
harness.suite(function()
  describe("the build's stamp", function()
    test("carries wally.toml's version and the outlast capability", function()
      local project = serde.decode("json", fs.readFile("default.project.json"))
      local wally = serde.decode("toml", fs.readFile("wally.toml"))
      local npm = serde.decode("json", fs.readFile("package.json"))
      local stamp = project.tree["$attributes"] or {}

      expect(stamp.Version).toBe(wally.package.version)
      expect(npm.version).toBe(wally.package.version)
      expect(string.find(stamp.Capabilities or "", "outlast", 1, true) ~= nil).toBe(true)
    end)
  end)
end)
