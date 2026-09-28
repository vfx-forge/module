local fs = require("@lune/fs")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

local CALLS = {
  "prepareEmitOnFinish%(%s*([%w_]+)",
  "emitNested%(%s*([%w_]+)",
  "emitOnFinish%(%s*[%w_]+%s*,%s*([%w_]+)",
}

-- what a part cache hands out is a proxy that forwards methods to the part but
-- is no Instance, so parenting an on-finish child to it throws
local function misuses(source: string)
  local proxies = {}

  for name in string.gmatch(source, "local%s+([%w_]+)%s*=%s*[%w_]*cache:get%(") do
    proxies[name] = true
  end

  local found = {}

  for _, pattern in CALLS do
    for name in string.gmatch(source, pattern) do
      if proxies[name] then
        table.insert(found, `{string.match(pattern, "^%a+")}({name})`)
      end
    end
  end

  return found
end

harness.suite(function()
  test("an effect hands the service the real part, never the cache's proxy of it", function()
    local found = {}

    for _, file in fs.readDir("src/effects") do
      for _, misuse in misuses(fs.readFile(`src/effects/{file}`)) do
        table.insert(found, `{file}: {misuse}`)
      end
    end

    expect(table.concat(found, ", ")).toBe("")
  end)
end)
