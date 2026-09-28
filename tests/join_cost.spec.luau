local harness = require("@tests/harness")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local test, expect = harness.test, harness.expect

local Promise = require("@pkg/Promise")

local ROUNDS = 7

-- the evaera machinery alone, per emit, as the 2026-09-28 survey measured it on
-- dev 85d68d6 under lune 0.10.4: printed next to this run's own numbers, not
-- gated
local SURVEY_RING = 240e-6
local SURVEY_BEZIER = 198e-6

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

local function noop() end

-- a child emit of the effect's own, one effect that ends inside the call, the
-- records the effects service builds for a nested emit of a plain part
local function nested(scope: lifetime.effect): lifetime.emit
  local child = lifetime.emit(scope.emit)

  lifetime.run(lifetime.effect(child, scope.depth + 1, nil), noop)
  lifetime.seal(child)

  return child
end

-- one emit of one effect running body, then every piece finished from outside
-- the way a later frame would finish it
local function emitOf(body: (scope: lifetime.effect) -> (), finishers: { () -> () })
  return function()
    local root = lifetime.emit(nil)

    lifetime.run(lifetime.effect(root, 0, nil), body)
    lifetime.seal(root)

    for _, finish in table.clone(finishers) do
      finish()
    end

    table.clear(finishers)
  end
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

    test("an emit shaped like a ring of 16 or a bezier of 8 costs a fraction of the promises it replaces", function()
      local SEGMENTS = 16
      local PIECES = 8
      local CALLS = 100

      local finishers: { () -> () } = {}
      local ended = 0

      -- the ring as it waits now: a nested emit per segment counted in, a dwell
      -- counted until its exit is counted in, the exit counted until it lands
      local ring = emitOf(function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)

        for i = 1, SEGMENTS do
          lifetime.include(outstanding, nested(scope))

          local landed = lifetime.add(outstanding)

          finishers[i] = function()
            local exited = lifetime.add(outstanding)
            landed()
            exited()
          end
        end

        lifetime.awaitJoin(outstanding)
        ended += 1
      end, finishers)

      -- the ring as dev 85d68d6 waited: a Finished per nested emit, a promise
      -- per exit, the drained wait and a Promise.all over the lot
      local oldRing = emitOf(function(scope: lifetime.effect)
        local promises = {}
        local exits = {}

        for i = 1, SEGMENTS do
          nested(scope)
          table.insert(promises, Promise.resolve())

          table.insert(
            promises,
            Promise.new(function(resolve)
              exits[i] = resolve
            end)
          )
        end

        Promise.new(function(resolve)
          finishers[1] = function()
            resolve()

            for _, exit in exits do
              exit()
            end
          end
        end):await()

        Promise.all(promises):await()
        ended += 1
      end, finishers)

      -- the bezier as it waits now: each piece counted until it finishes, set up
      -- under a try so a throw counts it out
      local bezier = emitOf(function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)

        for i = 1, PIECES do
          local landed = lifetime.add(outstanding)

          local ok = utility.try(`failed to emit a piece with error: %s`, function()
            lifetime.include(outstanding, nested(scope))
            finishers[i] = landed
          end)

          if not ok then
            landed()
          end
        end

        lifetime.awaitJoin(outstanding)
        ended += 1
      end, finishers)

      -- the bezier as dev 85d68d6 waited: a promise per piece, a Finished per
      -- nested emit, the on-finish Finished's finally, and a Promise.all
      local EMPTY = Promise.resolve()

      local oldBezier = emitOf(function(scope: lifetime.effect)
        local promises = {}

        for i = 1, PIECES do
          table.insert(
            promises,
            Promise.new(function(resolve)
              nested(scope)
              table.insert(promises, Promise.resolve())

              finishers[i] = function()
                EMPTY:finally(function()
                  resolve()
                end)
              end
            end)
          )
        end

        Promise.all(promises):await()
        ended += 1
      end, finishers)

      ring()
      bezier()

      local ringCost = best(CALLS, ring)
      local oldRingCost = best(CALLS, oldRing)
      local bezierCost = best(CALLS, bezier)
      local oldBezierCost = best(CALLS, oldBezier)

      local ringSays = `{us(ringCost)} per emit, {us(oldRingCost)} with the promises it replaces`
      local bezierSays = `{us(bezierCost)} per emit, {us(oldBezierCost)} with the promises it replaces`

      print(`ring of {SEGMENTS}: {ringSays} (survey: {us(SURVEY_RING)} of promises alone)`)
      print(`bezier of {PIECES}: {bezierSays} (survey: {us(SURVEY_BEZIER)} of promises alone)`)

      expect(ended).toBe(2 + 4 * ROUNDS * CALLS)
      expect(ringCost < oldRingCost / 5).toBe(true)
      expect(bezierCost < oldBezierCost / 5).toBe(true)
    end)
  end)
end)
