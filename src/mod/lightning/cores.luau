const cores = {}

-- a Model the cores go in, held and destroyed with the drawing; a Highlight adorning it covers the cores and leaves
-- the glow shells, which sit beside it in the effect's container
function cores.model(sdk: any, ctx: any): Model
  const model = sdk.hold(ctx, Instance.new("Model"))

  model.Name = "LightningCores"
  model.Archivable = false
  model.Parent = sdk.container(ctx)

  return model
end

return cores
