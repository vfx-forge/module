const BOLT = {
  Highlight = "highlight",
  PointLight = "light",
  SpotLight = "light",
  Beam = "beam",
  ParticleEmitter = "emitter",
  Trail = "trail",
}

export type Sorted = {
  highlight: any?,
  beam: { any },
  emitter: { any },
  light: { any },
  trail: { any },
  found: number,
  refused: boolean,
  locked: boolean,
  extra: boolean,
}
export type Along = { emitter: { any }, strike: { any }, locked: boolean }

const kinds = {}

function kinds.bolt(className: string): string
  return BOLT[className] or "refused"
end

-- what Bolt holds, sorted once: the first Highlight, what rides by kind, and whether anything was refused, left
-- out for not being Archivable, or a second Highlight
function kinds.sort(children: { any }): Sorted
  const sorted: Sorted = {
    highlight = nil,
    beam = {},
    emitter = {},
    light = {},
    trail = {},
    found = 0,
    refused = false,
    locked = false,
    extra = false,
  }

  for _, child in children do
    const kind = kinds.bolt(child.ClassName)

    if kind == "refused" then
      sorted.refused = true
    -- an instance that is not Archivable clones to nil (measured 2026-10-24 on a Highlight and a
    -- ParticleEmitter), so it cannot ride
    elseif not child.Archivable then
      sorted.locked = true
    elseif kind == "highlight" and sorted.highlight then
      sorted.extra = true
    elseif kind == "highlight" then
      sorted.highlight = child
    else
      table.insert(sorted[kind], child)
      sorted.found += 1
    end
  end

  return sorted
end

function kinds.along(className: string): string
  return if className == "ParticleEmitter" then "emitter" else "strike"
end

-- what EmitAlong holds: particles re-emitted along the bolt, the rest once a strike, and nothing that is not
-- Archivable, since its clone is nil
function kinds.sortAlong(children: { any }): Along
  const sorted: Along = { emitter = {}, strike = {}, locked = false }

  for _, child in children do
    if child.Archivable then
      table.insert(sorted[kinds.along(child.ClassName)], child)
    else
      sorted.locked = true
    end
  end

  return sorted
end

return kinds
