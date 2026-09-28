local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local test, expect = harness.test, harness.expect

local Promise = require("@pkg/Promise")

local ROUNDS = 7

-- the fastest of a few rounds, in seconds per call, so a busy machine can only
-- make a gate pass later, never fail it early
local function best(calls: number, fn: () -> ())
  local fastest = math.huge

  for _ = 1, ROUNDS do
    local started = os.clock()

    for _ = 1, calls do
      fn()
    end

    fastest = math.min(fastest, (os.clock() - started) / calls)
  end

  return fastest
end

local function us(seconds: number)
  return string.format("%.1f us", seconds * 1e6)
end

harness.suite(function()
  harness.describe("the join's cost", function()
    test("a join of 64 with its body parked costs a twentieth of Promise.all over 64", function()
      local SIZE = 64

      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local dones = table.create(SIZE)
      local resolvers = table.create(SIZE)
      local promises = table.create(SIZE)

      local cost = best(2000, function()
        local outstanding = lifetime.join(fx)

        for i = 1, SIZE do
          dones[i] = lifetime.add(outstanding)
        end

        local body = coroutine.create(lifetime.awaitJoin)
        coroutine.resume(body, outstanding)

        for _, done in dones do
          done()
        end
      end)

      local old = best(100, function()
        for i = 1, SIZE do
          promises[i] = Promise.new(function(resolve)
            resolvers[i] = resolve
          end)
        end

        local all = Promise.all(promises)
        local body = coroutine.create(all.await)
        coroutine.resume(body, all)

        for _, resolve in resolvers do
          resolve()
        end
      end)

      lifetime.release(fx)

      print(`join of {SIZE}: {us(cost)}, Promise.all over {SIZE}: {us(old)}, parked body and wake included`)

      expect(cost < old / 20).toBe(true)
    end)
  end)
end)
