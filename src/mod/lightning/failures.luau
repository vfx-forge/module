const logger = require("@mod/logger")
const lifetime = require("@mod/lifetime")

const failures = {}

-- the warnings already given for each ref, by key, so a loop warns once
const Warned: { [Instance]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- what a failed bolt is warned under, whatever its error says, so a bolt failing on every tick warns once
const FAILED = "failed"

-- a halt or a refused load is a table, and passes through untouched for lifetime to handle
const function traced(err: any)
  if type(err) == "table" then
    return err
  end

  return debug.traceback(tostring(err), 2)
end

-- `text` warned once for `ref` under `key`, the text itself when no key is given
function failures.once(ref: Instance, text: string, key: string?)
  local seen = Warned[ref]

  if seen == nil then
    seen = {}
    Warned[ref] = seen
  end

  const by = key or text

  if seen[by] then
    return
  end

  seen[by] = true
  logger.warn(`lightning on {ref:GetFullName()}: {text}`)
end

-- a bolt's body: a throw is warned once per ref and ends this bolt alone, its pieces let go with the effect as before
function failures.body(ref: Instance, body: (...any) -> (), ...: any)
  const ok, err = xpcall(body, traced, ...)

  if ok then
    return
  end

  if type(err) == "table" then
    error(err, 0)
  end

  failures.once(ref, `a bolt failed: {err}`, FAILED)
end

-- a bolt's frame step: a throw is warned once per ref and ends the effect, as a failing step's owner is ended
function failures.step(ref: Instance, scope: lifetime.effect, fn: (deltaTime: number) -> ()): (deltaTime: number) -> ()
  return function(deltaTime: number)
    const ok, err = xpcall(fn, traced, deltaTime)

    if ok then
      return
    end

    if type(err) == "table" then
      error(err, 0)
    end

    failures.once(ref, `a bolt failed: {err}`, FAILED)
    lifetime.kill(scope)
  end
end

return failures
