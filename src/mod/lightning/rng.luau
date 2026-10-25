const rng = {}

-- xorshift32 so one seed gives one bolt under lune and in the engine alike
function rng.generator(seed: number): () -> number
  local state = math.floor(math.abs(seed)) % 4294967296

  if state == 0 then
    state = 0x9E3779B9
  end

  return function(): number
    state = bit32.bxor(state, bit32.lshift(state, 13))
    state = bit32.bxor(state, bit32.rshift(state, 17))
    state = bit32.bxor(state, bit32.lshift(state, 5))

    return state / 4294967296
  end
end

return rng
