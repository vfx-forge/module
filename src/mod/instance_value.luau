local instance_value = {}

-- how a stored value is looked at, handed in so the rules below run without
-- the engine: what kind a value is, the instance a handle points at, whether
-- that instance is still in the place, and whether it is of a class
export type Probe = {
  kind: (v: any) -> string,
  get: (v: any) -> Instance?,
  alive: (inst: Instance) -> boolean,
  isA: (inst: Instance, class: string) -> boolean,
}

-- the instance an Instance row's stored value points at, or nil. the second
-- return is the kind of a value that is no handle at all, for the reader's
-- warning; a gone target or a class the row does not take is no mistake in
-- what was stored, so it reads nil quietly
function instance_value.accept(v: any, classes: { string }?, probe: Probe): (Instance?, string?)
  if v == nil then
    return nil
  end

  local kind = probe.kind(v)

  if kind ~= "InstanceHandle" then
    return nil, kind
  end

  -- a destroyed target is still handed back, so being in the place is what
  -- tells a live one
  local inst = probe.get(v)

  if inst == nil or not probe.alive(inst) then
    return nil
  end

  if classes == nil then
    return inst
  end

  for _, class in classes do
    if probe.isA(inst, class) then
      return inst
    end
  end

  return nil
end

return instance_value
