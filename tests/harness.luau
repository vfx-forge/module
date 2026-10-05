local roblox = require("@lune/roblox") :: any

-- assigned bare rather than into a table, because lune propagates bare globals
-- into plainly required chunks. that is what lets modules under test and the
-- vendored Z see Color3 with no environment plumbing
-- this project's roblox.yml std (the stock generated Roblox library) is
-- roblox-based, so selene treats these names as read-only standard library
-- globals; both lints are the cost of that choice
-- selene: allow(unscoped_variables, incorrect_standard_library_use)
do
  CFrame = roblox.CFrame
  Color3 = roblox.Color3
  Rect = roblox.Rect
  UDim = roblox.UDim
  UDim2 = roblox.UDim2
  Vector2 = roblox.Vector2
  Vector3 = roblox.Vector3
  NumberRange = roblox.NumberRange
  ColorSequence = roblox.ColorSequence
  NumberSequence = roblox.NumberSequence
  ColorSequenceKeypoint = roblox.ColorSequenceKeypoint
  NumberSequenceKeypoint = roblox.NumberSequenceKeypoint

  -- not a datatype: @mod/lifetime spawns through task, which Studio has as a
  -- global and lune has only as a library
  task = require("@lune/task")
end

-- specs destructure from here rather than relying on the globals, which keeps
-- their dependencies visible at the top of the file. Instance is included; it is
-- a side-effecting constructor and deliberately not a bare global
local datatypes: { [string]: any } = {
  CFrame = roblox.CFrame,
  Color3 = roblox.Color3,
  Rect = roblox.Rect,
  UDim = roblox.UDim,
  UDim2 = roblox.UDim2,
  Vector2 = roblox.Vector2,
  Vector3 = roblox.Vector3,
  Instance = roblox.Instance,
  NumberRange = roblox.NumberRange,
  ColorSequence = roblox.ColorSequence,
  NumberSequence = roblox.NumberSequence,
  ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
  NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
}

-- lune's roblox library has no Path2DControlPoint constructor at all;
-- path.serializePath only ever reads these three fields, each UDim2-shaped
-- selene: allow(unscoped_variables, incorrect_standard_library_use)
do
  Path2DControlPoint = {
    new = function(position: UDim2, leftTangent: UDim2?, rightTangent: UDim2?)
      return {
        Position = position,
        LeftTangent = leftTangent or UDim2.new(),
        RightTangent = rightTangent or UDim2.new(),
      }
    end,
  }
end

-- the render step under lune. nothing advances a frame here, so a spec that
-- drives a target advances it itself through harness.render: the bound
-- steppers in priority order, then the plain connections, which is the order
-- the engine runs them in
type Binding = { id: string?, priority: number, step: (deltaTime: number) -> (), live: boolean }

local bindings: { Binding } = {}

local function bind(binding: Binding)
  table.insert(bindings, binding)

  table.sort(bindings, function(a, b)
    return a.priority < b.priority
  end)
end

local function unbind(binding: Binding)
  binding.live = false

  local index = table.find(bindings, binding)

  if index then
    table.remove(bindings, index)
  end
end

-- a frame. the list is copied first, because a stepper that ends unbinds
-- itself from inside its own call
local function renderFrame(deltaTime: number)
  for _, binding in table.clone(bindings) do
    if binding.live then
      binding.step(deltaTime)
    end
  end
end

-- @mod/attributes asks RunService and the script's ancestry for its context
-- once at load; under lune the answer is "a plain client", which is also the
-- context where a write-back must never happen
-- selene: allow(unscoped_variables, incorrect_standard_library_use)
do
  local runService = {
    IsServer = function()
      return false
    end,
    IsStudio = function()
      return false
    end,
    IsRunning = function()
      return false
    end,

    BindToRenderStep = function(_, id: string, priority: number, step: (deltaTime: number) -> ())
      bind({ id = id, priority = priority, step = step, live = true })
    end,

    UnbindFromRenderStep = function(_, id: string)
      for _, binding in table.clone(bindings) do
        if binding.id == id then
          unbind(binding)
        end
      end
    end,

    RenderStepped = {
      Connect = function(_, step: (deltaTime: number) -> ())
        local binding: Binding = { id = nil, priority = math.huge, step = step, live = true }
        bind(binding)

        return {
          Connected = true,

          Disconnect = function()
            unbind(binding)
          end,
        }
      end,
    },
  }

  -- every other service is inert: a method answers an empty list and a signal
  -- connects to nothing, which is all a module touches at load. a module that
  -- reaches for more inside a function is a Studio concern
  local function inertService(name: string)
    local service = {}

    return setmetatable(service, {
      __index = function(_, key)
        if key == "Name" then
          return name
        end

        return function()
          return {}
        end
      end,
    })
  end

  -- the tag service the passive loops start from: nothing is tagged, and its
  -- signals connect to nothing
  local signal = {
    Connect = function()
      return {
        Connected = true,
        Disconnect = function() end,
      }
    end,
  }

  local tags: any = inertService("CollectionService")

  tags.GetTagged = function()
    return {}
  end

  tags.GetInstanceAddedSignal = function()
    return signal
  end

  tags.GetInstanceRemovedSignal = function()
    return signal
  end

  -- a real instance, so what a spec parents under StarterGui stays there
  local starterGui = roblox.Instance.new("Folder")

  starterGui.Name = "StarterGui"

  local services: { [string]: any } = {
    CollectionService = tags,
    StarterGui = starterGui,
  }

  game = {
    GetService = function(_, name: string)
      if name == "RunService" then
        return runService
      end

      local service = services[name]

      if service == nil then
        service = inertService(name)
        services[name] = service
      end

      return service
    end,
  }

  -- the roblox library's own enums, which an effect's constants read at load
  Enum = roblox.Enum

  script = {
    FindFirstAncestorOfClass = function()
      return nil
    end,
  }

  -- the camera the shake reads and writes, a plain table a spec can move, with
  -- the attributes the copies of the shake leave on it
  local cameraAttributes: { [string]: any } = {}

  workspace = {
    CurrentCamera = {
      CFrame = roblox.CFrame.identity,

      GetAttribute = function(_, name: string)
        return cameraAttributes[name]
      end,

      SetAttribute = function(_, name: string, value: any)
        cameraAttributes[name] = value
      end,

      GetAttributes = function()
        return table.clone(cameraAttributes)
      end,
    },
  }
end

-- Random is absent under lune outright: @lune/roblox exposes none and there is
-- no bare global either. mods.roll builds its own rather than taking a seam, so
-- everything downstream of it, which is mods.track and every effect, is
-- unreachable headlessly without a stand-in. a fixed LCG, so a spec that reaches
-- it is never flaky; the spread of the real thing is pinned in the plugin's
-- Studio lane, where a real Random exists
-- selene: allow(unscoped_variables, incorrect_standard_library_use)
do
  local function lcg(seed: number): () -> number
    local state = seed % 2147483647

    if state <= 0 then
      state += 2147483646
    end

    return function(): number
      state = (state * 48271) % 2147483647

      return (state - 1) / 2147483646
    end
  end

  Random = {
    -- NextNumber alone, because it is all mods.roll calls. a method this does
    -- not have errors where a stubbed one would answer something plausible
    new = function(seed: number?)
      local draw = lcg(if seed then seed else 20260802)
      local rng = {}

      function rng.NextNumber(_: any, min: number?, max: number?): number
        local n = draw()

        if min == nil or max == nil then
          return n
        end

        return min + (max - min) * n
      end

      return rng
    end,
  }
end

-- logger.warn resolves the bare warn global when it is called, and lune hands a
-- chunk the globals as they stood when that chunk was first required, so the
-- hook has to be in place here, before any spec pulls in a module that warns.
-- the swap is a stable function and the capture list behind it is what moves
local warnings: { string }? = nil

do
  local passThrough = warn

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  warn = function(...)
    local list = warnings
    local text = (...)

    if list then
      -- logger.warn's second call is its own traceback, not a second
      -- warning, so a spec counting warnings never sees it
      if not string.find(text, "stack trace:", 1, true) then
        table.insert(list, text)
      end

      return
    end

    passThrough(...)
  end
end

--------------------------------------------------------------------------------
-- tiniest pin
--------------------------------------------------------------------------------

local tiniest = require("@tiniest/src/tiniest_for_lune").configure({
  pretty = {},
})

local collected: { () -> () } = {}

local function deepEqual(a: any, b: any): boolean
  if a == b then
    return true
  end

  if typeof(a) ~= "table" or typeof(b) ~= "table" then
    -- buffers: compare byte content
    if typeof(a) == "buffer" and typeof(b) == "buffer" then
      return buffer.tostring(a) == buffer.tostring(b)
    end

    return false
  end

  for k, v in a do
    if not deepEqual(v, (b :: any)[k]) then
      return false
    end
  end

  for k in b do
    if (a :: any)[k] == nil then
      return false
    end
  end

  return true
end

local harness = {}

-- one frame of the render step, for a spec that drives a target through an
-- effect. nothing advances a frame under lune, so a spec advances its own
harness.render = renderFrame

-- roblox datatype constructors (Vector2, Vector3, CFrame, NumberSequence, ...)
-- for specs to destructure explicitly, e.g.
-- `local NumberSequence = harness.datatypes.NumberSequence`
--
-- Instance is here but deliberately not a bare global: Instance.new is a
-- side-effecting constructor, and vendored code under test has dead
-- Instance.new branches that must not become reachable
harness.datatypes = datatypes

-- a Speed row as the reader hands it over: a ramp from `from` to `to` over
-- `duration`, or a constant when there is no duration
function harness.row(from: number, to: number?, duration: number?)
  return {
    animated = duration ~= nil,
    duration = duration or 0,
    at = function(elapsed: number)
      if duration == nil or to == nil then
        return from
      end

      return from + (to - from) * math.clamp(elapsed / duration, 0, 1)
    end,
  }
end

-- stand-in for EncodingService's base64. hex is enough to prove the framing
-- round-trips without reimplementing base64 in a test, and it lives here rather
-- than in the one spec that first needed it because modifier_frame.configure is
-- module state: a second spec configuring a codec of its own would decide the
-- first one's expectations by load order
harness.fakeEncoding = {
  encode = function(buf: buffer): buffer
    local out = {}

    for i = 0, buffer.len(buf) - 1 do
      table.insert(out, string.format("%02x", buffer.readu8(buf, i)))
    end

    return buffer.fromstring(table.concat(out))
  end,

  decode = function(buf: buffer): buffer
    local s = buffer.tostring(buf)
    local out = buffer.create(#s // 2)

    for i = 1, #s, 2 do
      buffer.writeu8(out, (i - 1) // 2, tonumber(string.sub(s, i, i + 1), 16) :: number)
    end

    return out
  end,
}

-- stand-in for EncodingService's zstd, for specs that exercise modifier_frame's
-- compressed encoding. a toy run-length coder: like zstd it shrinks repetitive
-- input (a real modifier queue is largely zero runs) and grows short
-- unrepetitive input, so both branches of frame's pick-the-smaller are
-- reachable headlessly. not a compressor anyone should reuse
harness.fakeCompression = {
  compress = function(buf: buffer): buffer
    local runs = {}
    local len = buffer.len(buf)
    local i = 0

    while i < len do
      local byte = buffer.readu8(buf, i)
      local run = 1

      while run < 255 and i + run < len and buffer.readu8(buf, i + run) == byte do
        run += 1
      end

      table.insert(runs, string.char(run, byte))
      i += run
    end

    return buffer.fromstring(table.concat(runs))
  end,

  -- an odd length cannot be a run/byte pair sequence, which stands in for the
  -- real codec's corrupt-input detection
  decompress = function(buf: buffer): buffer?
    local len = buffer.len(buf)

    if len % 2 ~= 0 then
      return nil
    end

    local out = {}

    for i = 0, len - 1, 2 do
      table.insert(out, string.rep(string.char(buffer.readu8(buf, i + 1)), buffer.readu8(buf, i)))
    end

    return buffer.fromstring(table.concat(out))
  end,
}

function harness.describe(name: string, body: () -> ())
  tiniest.describe(name, body)
end

function harness.test(name: string, body: () -> ())
  tiniest.test(name, body)
end

function harness.expect(actual: any)
  return {
    toBe = function(expected: any)
      assert(actual == expected, `expected {tostring(actual)} to be {tostring(expected)}`)
    end,
    toEqual = function(expected: any)
      assert(deepEqual(actual, expected), `values not deeply equal`)
    end,
    toThrow = function()
      assert(not pcall(actual), "expected function to throw")
    end,
    ok = function()
      assert(actual, `expected truthy, got {tostring(actual)}`)
    end,
  }
end

-- runs fn with everything logger.warn writes collected instead of printed, so a
-- spec can pin a path that must not warn
function harness.captureWarnings(fn: () -> ()): { string }
  local captured = {}
  warnings = captured

  local ok, err = pcall(fn)
  warnings = nil

  assert(ok, tostring(err))

  return captured
end

function harness.suite(fn: () -> ())
  table.insert(collected, fn)
end

function harness.run(): number
  local tests = tiniest.collect_tests(function()
    for _, fn in collected do
      fn()
    end
  end)
  local result = tiniest.run_tests(tests, {})
  return if result.status_tally.fail > 0 then 1 else 0
end

--------------------------------------------------------------------------------
-- selector engine
--------------------------------------------------------------------------------

-- lune has no QueryDescendants. this engine understands the grammar the
-- classifiers use and nothing more: a compound is an optional class, then any
-- of #Name, .Tag, [$Attr] or [$Attr=value], :not(selector) and :has(relative);
-- compounds chain with > and >>; alternatives split on a comma. it draws from a
-- pool of the wrappers specs made rather than walking GetDescendants live: the
-- test host hands out a fresh wrapper per walk, and a registry keyed by
-- instance has to be served the wrappers the spec itself holds. like the
-- engine, it never matches a chain's leftmost compound against the root
local pool: { Instance } = {}

function harness.reset()
  table.clear(pool)
end

function harness.make(class: string, parent: Instance?): Instance
  local inst = datatypes.Instance.new(class)

  if parent then
    inst.Parent = parent
  end

  table.insert(pool, inst)

  return inst
end

-- a clone that queries reach, as harness.make's instances are
function harness.clone(inst: Instance): Instance
  local copy = inst:Clone()

  table.insert(pool, copy)

  for _, desc in copy:GetDescendants() do
    table.insert(pool, desc)
  end

  return copy
end

type Compound = {
  class: string?,
  name: string?,
  tags: { string },
  attrs: { { name: string, value: any, any: boolean } },
  nots: { Selector },
  has: { Chain },
}

type Chain = { { combinator: string, compound: Compound } }

type Selector = { Chain }

local parseSelector

-- the body of a balanced parenthesis starting at `from`, and the index after it
local function balanced(s: string, from: number): (string, number)
  local depth = 0

  for i = from, #s do
    local c = string.sub(s, i, i)

    if c == "(" then
      depth += 1
    elseif c == ")" then
      depth -= 1

      if depth == 0 then
        return string.sub(s, from + 1, i - 1), i + 1
      end
    end
  end

  error(`unbalanced selector {s}`)
end

local function literal(text: string): any
  if text == "true" then
    return true
  end

  if text == "false" then
    return false
  end

  local n = tonumber(text)

  if n ~= nil then
    return n
  end

  return (string.gsub(text, "^[\"']?(.-)[\"']?$", "%1"))
end

local function parseCompound(s: string): Compound
  local out: Compound = { class = nil, name = nil, tags = {}, attrs = {}, nots = {}, has = {} }
  local i = 1

  local class = string.match(s, "^[%a_][%w_]*")

  if class then
    out.class = class
    i += #class
  end

  while i <= #s do
    local c = string.sub(s, i, i)

    if c == "#" then
      local name = string.match(s, "^[%w_]+", i + 1) or ""
      out.name = name
      i += 1 + #name
    elseif c == "." then
      local tag = string.match(s, "^[%w_]+", i + 1) or ""
      table.insert(out.tags, tag)
      i += 1 + #tag
    elseif c == "[" then
      local close = string.find(s, "]", i, true) or #s
      local body = string.sub(s, i + 1, close - 1)
      local name, valueText = string.match(body, "^%$([%w_]+)=(.*)$")

      if name then
        table.insert(out.attrs, { name = name, value = literal(valueText), any = false })
      else
        table.insert(out.attrs, { name = string.match(body, "^%$([%w_]+)$") or body, value = nil, any = true })
      end

      i = close + 1
    elseif string.sub(s, i, i + 4) == ":not(" then
      local body, after = balanced(s, i + 4)
      table.insert(out.nots, parseSelector(body))
      i = after
    elseif string.sub(s, i, i + 4) == ":has(" then
      local body, after = balanced(s, i + 4)
      local relative = parseSelector(body)

      if #relative > 1 then
        error(`a selector list inside :has is not supported at {i} in {s}`)
      end

      for _, chain in relative do
        table.insert(out.has, chain)
      end

      i = after
    else
      error(`unsupported selector syntax at {i} in {s}`)
    end
  end

  return out
end

-- one alternative split into compounds and the combinator ahead of each; the
-- first combinator is "" for an absolute chain and > or >> for a relative one
local function parseChain(s: string): Chain
  local chain: Chain = {}
  local i = 1
  local n = #s

  while i <= n do
    while i <= n and string.sub(s, i, i) == " " do
      i += 1
    end

    local combinator = ""

    if string.sub(s, i, i + 1) == ">>" then
      combinator = ">>"
      i += 2
    elseif string.sub(s, i, i) == ">" then
      combinator = ">"
      i += 1
    end

    while i <= n and string.sub(s, i, i) == " " do
      i += 1
    end

    local start = i
    local depth = 0

    while i <= n do
      local c = string.sub(s, i, i)

      if c == "(" then
        depth += 1
      elseif c == ")" then
        depth -= 1
      elseif depth == 0 and (c == ">" or c == " ") then
        break
      end

      i += 1
    end

    local text = string.sub(s, start, i - 1)

    if text ~= "" then
      table.insert(chain, { combinator = combinator, compound = parseCompound(text) })
    end
  end

  return chain
end

function parseSelector(s: string): Selector
  local out: Selector = {}
  local depth = 0
  local start = 1

  for i = 1, #s + 1 do
    local c = string.sub(s, i, i)

    if c == "(" then
      depth += 1
    elseif c == ")" then
      depth -= 1
    elseif (c == "," and depth == 0) or i == #s + 1 then
      table.insert(out, parseChain(string.sub(s, start, i - 1)))
      start = i + 1
    end
  end

  return out
end

local matchChainAt

local function matchCompound(inst: Instance, compound: Compound): boolean
  if compound.class ~= nil and not inst:IsA(compound.class) then
    return false
  end

  if compound.name ~= nil and inst.Name ~= compound.name then
    return false
  end

  for _, tag in compound.tags do
    if not inst:HasTag(tag) then
      return false
    end
  end

  for _, filter in compound.attrs do
    local v = inst:GetAttribute(filter.name)

    if filter.any then
      if v == nil then
        return false
      end
    elseif v ~= filter.value then
      return false
    end
  end

  for _, selector in compound.nots do
    for _, chain in selector do
      if matchChainAt(inst, chain, #chain, nil) then
        return false
      end
    end
  end

  for _, chain in compound.has do
    local found = false
    local candidates = if chain[1].combinator == ">" then inst:GetChildren() else inst:GetDescendants()

    for _, candidate in candidates do
      if matchChainAt(candidate, chain, #chain, inst) then
        found = true
        break
      end
    end

    if not found then
      return false
    end
  end

  return true
end

-- whether inst is the chain's compound at `index` with the compounds ahead of
-- it satisfied by its ancestors, every matched instance strictly below root
-- when a root is given. a chain that starts with a combinator is relative to
-- the root, so its first compound sits directly under (>) or somewhere below
-- (>>) the root
function matchChainAt(inst: Instance, chain: Chain, index: number, root: Instance?): boolean
  local link = chain[index]

  if not matchCompound(inst, link.compound) then
    return false
  end

  if root ~= nil and (inst == root or not inst:IsDescendantOf(root)) then
    return false
  end

  if index == 1 then
    if link.combinator == ">" then
      return root ~= nil and inst.Parent == root
    end

    return true
  end

  local parent = inst.Parent

  if link.combinator == ">" then
    return parent ~= nil and matchChainAt(parent, chain, index - 1, root)
  end

  while parent ~= nil do
    if matchChainAt(parent, chain, index - 1, root) then
      return true
    end

    parent = parent.Parent
  end

  return false
end

function harness.query(root: Instance, selector: string): { Instance }
  local parsed = parseSelector(selector)
  local out = {}

  for _, inst in pool do
    if inst == root or not inst:IsDescendantOf(root) then
      continue
    end

    for _, chain in parsed do
      if #chain > 0 and matchChainAt(inst, chain, #chain, root) then
        table.insert(out, inst)
        break
      end
    end
  end

  return out
end

return harness
