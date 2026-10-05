local fs = require("@lune/fs")
local harness = require("@tests/harness")

local test, expect = harness.test, harness.expect

local LEFTOVERS = { "_getReal", "ObjectCache", "part_cache", "shared_part", "COPY_PART_PROPERTIES" }

local function walk(dir: string, found: { string })
  for _, name in fs.readDir(dir) do
    local path = `{dir}/{name}`

    if fs.isDir(path) then
      walk(path, found)
    elseif string.match(name, "%.luau$") then
      local source = fs.readFile(path)

      for _, leftover in LEFTOVERS do
        if string.find(source, leftover, 1, true) then
          table.insert(found, `{path}: {leftover}`)
        end
      end
    end
  end
end

harness.suite(function()
  test("nothing in src reaches the old part cache", function()
    local found = {}

    walk("src", found)

    expect(table.concat(found, ", ")).toBe("")
  end)
end)
