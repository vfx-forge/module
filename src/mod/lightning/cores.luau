const lifetime = require("@mod/lifetime")

const containers = require("@srv/containers")

const cores = {}

-- the part under the runtime's root everything a lightning makes is parented under
function cores.container(): BasePart
  return containers.of("forge_lightning")
end

-- a Model the cores go in, held and destroyed with the drawing; a Highlight adorning it covers the cores and leaves
-- the glow shells, which sit beside it in the effect's container
function cores.model(scope: lifetime.effect): Model
  const model = lifetime.hold(scope, Instance.new("Model"))

  model.Name = "LightningCores"
  model.Archivable = false
  model.Parent = cores.container()

  return model
end

return cores
